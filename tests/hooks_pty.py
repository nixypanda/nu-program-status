#!/usr/bin/env python3
"""End-to-end PTY tests for nu-program-status hooks.

Run from the repository root:
    python3 tests/hooks_pty.py
"""

import base64
import os
import re
import select
import signal
import subprocess
import sys
import tempfile
import time
import uuid

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
NU = "nu"
OSC_RE = re.compile(rb"\x1b\]7501;([^\x1b]*)\x1b\\")
DSR = b"\x1b[6n"
DSR_REPLY = b"\x1b[1;1R"
COMPLETE = b"\x1b]133;D"
APPROVED_TEMP = "/private/var/folders/ky/lktlhg4x5v11fg0jydm7fkrm0000gn/T/opencode"


def make_fake_bin():
    d = tempfile.mkdtemp(prefix="nups-fakebin-", dir=APPROVED_TEMP)
    for name in ("opencode", "claude", "codex"):
        path = os.path.join(d, name)
        with open(path, "w") as f:
            f.write("#!/bin/sh\nsleep 2\n")
        os.chmod(path, 0o755)
    return d


class NuSession:
    def __init__(self, fake_bin, min_duration=None, enabled=None, excluded=None, env_overrides=None):
        self.fake_bin = fake_bin
        self.cfgdir = tempfile.mkdtemp(prefix="nups-cfg-", dir=APPROVED_TEMP)
        self.env_overrides = env_overrides or {}
        self.prompt = "NUPT-{}>".format(uuid.uuid4().hex)
        self.complete_marker = COMPLETE

        env_lines = []
        if enabled is False:
            env_lines.append("$env.PROGRAM_STATUS_ENABLED = false")

        excluded_line = ""
        if excluded is not None:
            excluded_line = "$env.PROGRAM_STATUS_EXCLUDED_COMMANDS = [{}]".format(
                ", ".join('"{}"'.format(x) for x in excluded)
            )

        install = "program-status install-hooks"
        if min_duration is not None:
            install += " --min-duration {}".format(min_duration)
        if excluded is not None:
            install += " --excluded [{}]".format(
                ", ".join('"{}"'.format(x) for x in excluded)
            )

        config = """$env.config.show_banner = false
use "{hooks}" *
{env_lines}
{excluded_line}
{install}
$env.PROMPT_INDICATOR = ""
$env.PROMPT_COMMAND = {{|| "{prompt}" }}
$env.PROMPT_COMMAND_RIGHT = {{|| "" }}
""".format(
            hooks=os.path.join(REPO, "nu", "hooks.nu"),
            env_lines="\n".join(env_lines),
            excluded_line=excluded_line,
            install=install,
            prompt=self.prompt,
        )
        with open(os.path.join(self.cfgdir, "config.nu"), "w") as f:
            f.write(config)
        with open(os.path.join(self.cfgdir, "env.nu"), "w") as f:
            f.write("")

        self.master, self.slave = os.openpty() if False else (None, None)
        self.master, self.slave = __import__("pty").openpty()
        env = dict(os.environ)
        env["PATH"] = fake_bin + os.pathsep + env.get("PATH", "")
        env["TERM"] = "xterm-256color"
        env.update(self.env_overrides)
        setup = 'use "{}" *; {}'.format(os.path.join(REPO, "nu", "hooks.nu"), install)
        self.pid = os.fork()
        if self.pid == 0:
            os.close(self.master)
            os.setsid()
            try:
                import fcntl
                import termios

                fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)
            except Exception:
                pass
            os.dup2(self.slave, 0)
            os.dup2(self.slave, 1)
            os.dup2(self.slave, 2)
            if self.slave > 2:
                os.close(self.slave)
            os.execvpe(
                NU,
                [
                    NU,
                    "--config",
                    os.path.join(self.cfgdir, "config.nu"),
                    "--env-config",
                    os.path.join(self.cfgdir, "env.nu"),
                    "-e",
                    setup,
                ],
                env,
            )
            os._exit(127)
        os.close(self.slave)
        self.buf = bytearray()
        self._read_for(1.0)

    def _respond(self, data):
        if DSR in data:
            try:
                os.write(self.master, DSR_REPLY)
            except OSError:
                pass

    def _read_for(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            r, _, _ = select.select([self.master], [], [], min(0.1, remaining))
            if r:
                try:
                    data = os.read(self.master, 4096)
                except OSError:
                    break
                if not data:
                    break
                self._respond(data)
                self.buf.extend(data)
            else:
                break

    def run(self, command):
        before_complete = self.buf.count(self.complete_marker)
        before_marker = self.buf.count(self.prompt.encode())
        start = len(self.buf)
        os.write(self.master, (command + "\n").encode())
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline and self.buf.count(self.complete_marker) <= before_complete:
            r, _, _ = select.select([self.master], [], [], 0.1)
            if r:
                try:
                    data = os.read(self.master, 4096)
                except OSError:
                    break
                if not data:
                    break
                self._respond(data)
                self.buf.extend(data)
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline and self.buf.count(self.prompt.encode()) <= before_marker:
            r, _, _ = select.select([self.master], [], [], 0.1)
            if r:
                try:
                    data = os.read(self.master, 4096)
                except OSError:
                    break
                if not data:
                    break
                self._respond(data)
                self.buf.extend(data)
        self._read_for(0.3)
        return bytes(self.buf[start:])

    def close(self):
        try:
            os.write(self.master, b"exit\n")
        except OSError:
            pass
        self._read_for(0.5)
        try:
            os.kill(self.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass
        try:
            os.close(self.master)
        except OSError:
            pass


def osc_sequences(blob):
    return [m.group(1).decode("utf-8", "replace") for m in OSC_RE.finditer(blob)]


def title_of(seq):
    for part in seq.split(":"):
        if part.startswith("title="):
            return base64.b64decode(part[len("title=") :] + "==").decode(
                "utf-8", "replace"
            ).rstrip("\x00")
    return None


def main():
    fake_bin = make_fake_bin()
    failures = []

    def check(cond, msg):
        if not cond:
            failures.append(msg)
            print("FAIL:", msg)
        else:
            print("PASS:", msg)

    # Short command: no OSC.
    session = NuSession(fake_bin, min_duration="100ms")
    out = session.run("true")
    check(len(osc_sequences(out)) == 0, "short command emits no status")
    session.close()

    # Long command: done.
    session = NuSession(fake_bin, min_duration="100ms")
    out = session.run("/bin/sleep 2")
    seqs = osc_sequences(out)
    check(
        len(seqs) >= 1 and seqs[-1].startswith("state=done"),
        "long command emits done (got {})".format(seqs),
    )
    session.close()

    # Exclusions: bare, caret, and absolute path.
    for command in ("opencode", "^opencode", os.path.join(fake_bin, "opencode")):
        session = NuSession(fake_bin, min_duration="100ms")
        out = session.run(command)
        check(
            len(osc_sequences(out)) == 0,
            "excluded command {!r} emits no status (got {})".format(command, osc_sequences(out)),
        )
        session.close()

    # Privacy: only first token is retained.
    session = NuSession(fake_bin, min_duration="100ms")
    out = session.run("bash -c 'sleep 2' SUPERSECRET")
    seqs = osc_sequences(out)
    if seqs:
        check(
            title_of(seqs[-1]) == "bash",
            "privacy label is first token (got {})".format(title_of(seqs[-1])),
        )
        check("SUPERSECRET" not in seqs[-1], "privacy no raw args in OSC")
    else:
        check(False, "privacy case emitted no status")
    session.close()

    # Raw, uncaught external failure: error.
    session = NuSession(fake_bin, min_duration="100ms")
    out = session.run("bash -c 'sleep 2; exit 7'")
    seqs = osc_sequences(out)
    check(
        len(seqs) >= 1 and seqs[-1].startswith("state=error"),
        "raw external failure emits error (got {})".format(seqs),
    )
    session.close()

    # Handled failure: done.
    session = NuSession(fake_bin, min_duration="100ms")
    out = session.run("try { bash -c 'sleep 2; exit 7' }")
    seqs = osc_sequences(out)
    check(
        len(seqs) >= 1 and seqs[-1].startswith("state=done"),
        "handled failure emits done (got {})".format(seqs),
    )
    session.close()

    # Internal error followed by success in one session.
    session = NuSession(fake_bin, min_duration="100ms")
    out = session.run("bash -c 'sleep 2; exit 1'")
    seqs = osc_sequences(out)
    check(
        len(seqs) >= 1 and seqs[-1].startswith("state=error"),
        "internal error emits error (got {})".format(seqs),
    )
    out = session.run("/bin/sleep 2")
    seqs = osc_sequences(out)
    check(
        len(seqs) >= 1 and seqs[-1].startswith("state=done"),
        "success after error emits done (got {})".format(seqs),
    )
    session.close()

    # Status environment restoration, including previous absence.
    session = NuSession(fake_bin, min_duration="100ms")
    session.run("/bin/sleep 2; $env.LAST_EXIT_CODE = 9; $env.CMD_DURATION_MS = 321")
    out = session.run('print ($env.LAST_EXIT_CODE? | default "ABSENT")')
    check("ABSENT" in out.decode("utf-8", "replace"), "LAST_EXIT_CODE restored to absent")
    out = session.run('print ($env.CMD_DURATION_MS? | default "ABSENT")')
    check("ABSENT" in out.decode("utf-8", "replace"), "CMD_DURATION_MS restored to absent")
    session.close()

    # Default threshold (10000 ms): a 2 s command is suppressed.
    session = NuSession(fake_bin)
    out = session.run("/bin/sleep 2")
    check(len(osc_sequences(out)) == 0, "default threshold suppresses 2 s command")
    session.close()

    # Explicit reinstall lowers the configured threshold.
    session = NuSession(fake_bin, min_duration="10s")
    out = session.run("/bin/sleep 2")
    check(len(osc_sequences(out)) == 0, "high threshold suppresses 2 s command")
    session.run("program-status install-hooks --min-duration 100ms")
    session.close()

    # Idempotence: reinstall keeps one hook.
    session = NuSession(fake_bin, min_duration="100ms")
    session.run("program-status install-hooks --min-duration 100ms")
    out = session.run('print ($env.config.hooks.pre_prompt | length)')
    check(b"1" in out, "idempotence hook count is 1 (got {!r})".format(out))
    session.close()

    # Environment threshold override reports even a fast command.
    session = NuSession(fake_bin, env_overrides={"PROGRAM_STATUS_MIN_DURATION_MS": "0"})
    out = session.run("true")
    seqs = osc_sequences(out)
    check(
        len(seqs) >= 1 and seqs[-1].startswith("state=done"),
        "environment threshold override reports fast command (got {})".format(seqs),
    )
    session.close()

    # Disabled startup toggle suppresses status.
    session = NuSession(fake_bin, min_duration="100ms", enabled=False)
    out = session.run("/bin/sleep 2")
    check(len(osc_sequences(out)) == 0, "disabled startup toggle suppresses status")
    session.close()

    # Enabled startup toggle reports status.
    session = NuSession(fake_bin, min_duration="100ms", enabled=True)
    out = session.run("/bin/sleep 2")
    seqs = osc_sequences(out)
    check(
        len(seqs) >= 1 and seqs[-1].startswith("state=done"),
        "enabled startup toggle reports status (got {})".format(seqs),
    )
    session.close()

    # Non-TTY emit produces no OSC.
    env = dict(os.environ)
    env["PATH"] = fake_bin + os.pathsep + env.get("PATH", "")
    proc = subprocess.run(
        [
            NU,
            "-c",
            'use "{}" *; program-status emit done'.format(
                os.path.join(REPO, "nu", "mod.nu")
            ),
        ],
        capture_output=True,
        env=env,
    )
    check(proc.stdout == b"", "emit is silent on non-TTY (got {!r})".format(proc.stdout))

    if failures:
        print("\n{} failure(s)".format(len(failures)))
        raise SystemExit(1)
    print("\nall PTY tests passed")


if __name__ == "__main__":
    main()