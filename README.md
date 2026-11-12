# nu-program-status

Nushell implementation of the OSC 7501 Program Status Protocol.

## Layout

- `nu/mod.nu` - public `program-status encode`, `program-status emit`, and `program-status exclusions` commands.
- `nu/hooks.nu` - optional automatic completion reporting via `program-status install-hooks`.
- `nu/internal.nu` - internal helpers and exclusion logic.
- `nu/data/native-reporters.nuon` - curated registry of programs that already emit OSC 7501.
- `tests/protocol.nu` - protocol tests.
- `tests/hooks_pty.py` - end-to-end PTY tests.

## Usage

```nu
use /path/to/nu-program-status/nu/mod.nu *
program-status emit done --title "build" --message "completed"
```

Inspect effective exclusions:

```nu
use /path/to/nu-program-status/nu/mod.nu *
program-status exclusions
```

Enable automatic completion reporting:

```nu
use /path/to/nu-program-status/nu/hooks.nu *
program-status install-hooks --min-duration 10sec
```

## Configuration

`program-status install-hooks` accepts:

- `--min-duration <duration>` - completion threshold (default `10sec`).
- `--exclude <list<string>>` - replace the user exclusion list.
- `--excluded <list<string>>` - deprecated alias for `--exclude`.
- `--include <list<string>>` - replace the user include list. Included rules override exclusions.
- `--no-default-exclusions` - disable the curated default exclusions for this and later reinstallations.
- `--default-exclusions` - re-enable the curated default exclusions.

Rules may be single commands (`"claude"`) or explicit command prefixes
(`"docker agent"`). A prefix matches only when the entered command starts with
those tokens; it does not match substrings or unrelated arguments.

Mutable environment configuration:

- `$env.PROGRAM_STATUS_ENABLED` - enable/disable automatic reporting (default `true`).
- `$env.PROGRAM_STATUS_MIN_DURATION_MS` - completion threshold in milliseconds.
- `$env.PROGRAM_STATUS_EXCLUDED_COMMANDS` - user exclusion rules.
- `$env.PROGRAM_STATUS_INCLUDED_COMMANDS` - user inclusion rules that override exclusions.
- `$env.PROGRAM_STATUS_DEFAULT_EXCLUSIONS` - whether curated defaults are active (default `true`).
- `$env.PROGRAM_STATUS_PENDING*` - internal pending-command state.

Omitted flags preserve existing environment values or defaults. Explicit empty
lists clear the corresponding user list. Re-running `install-hooks` is idempotent
and does not duplicate hooks.

Precedence is: included rules remove matching excluded rules; then user
exclusions; then curated defaults (if enabled). An explicit include always wins,
including over a built-in default such as `claude`.

Includes remove only an exclusion whose normalized prefix is exactly equal to
the included prefix. Including `docker` does not remove the `docker agent`
exclusion; include `docker agent` to override that specific rule.

## Native reporter registry

`nu/data/native-reporters.nuon` is a small, checked-in registry of programs
that already send OSC 7501 reports. It is used only to avoid duplicate
completion reports. The registry records the executable command (not a project
slug), an optional subcommand prefix, the first supporting version, whether
reporting is automatic or opt-in, an evidence URL, and the date the entry was
checked.

Only confirmed, shipped, automatic program reporters are defaults. Working or
pending implementations, terminal consumers, libraries, and opt-in reporters are
not excluded by default. Users can still add or remove rules with
`--exclude`/`--include`.

The registry is not a runtime network source. Update it manually from
https://areweosc7501yet.com/data.json (schemaVersion 3) and upstream release
notes. No version detection is performed at runtime; the recorded versions are
documentation of the first supporting release. Older installations or disabled
plugins can be handled with `--exclude`/`--include`.

## Testing

Run from the repository root:

```sh
nu tests/protocol.nu
python3 tests/hooks_pty.py
```

`tests/protocol.nu` covers encoding, validation, sanitization, truncation, and
the exclusion helper. `tests/hooks_pty.py` runs end-to-end PTY checks for hook
installation, idempotence, reporting, restoration, and excluded commands.

Tested with Nushell 0.116.1. The minimum supported Nushell version is not yet
pinned; older versions may differ in hook/config behavior.

## Notes

- Lifecycle: `working` is emitted immediately before an eligible foreground command starts; the terminal `done`, `error`, or `idle` outcome is emitted on completion when it meets `--min-duration`. Short commands can therefore show `working` and then be cleared by the shell prompt before a terminal outcome is reported.
- Only the first command token is retained as a sanitized, truncated label; arguments are never stored or emitted.
- `LAST_EXIT_CODE` and `CMD_DURATION_MS` are restored after reporting, including their previous absence.
- Compound commands, pipelines, and dynamic invocations are not parsed as a shell AST and are not treated as excluded native reporters.
- Direct `opencode`, `claude`, and `codex` invocations (plus other curated reporters) are excluded by default to avoid duplicate native reports. Use `--include` to override a built-in default.
- Automatic reporting is limited to interactive foreground sessions; non-interactive or background contexts emit nothing.
- Ctrl+C detection relies on the observed `-2` external command exit code. An interrupted Nushell builtin that reports a generic failure is reported as `error`, not `idle`.

## License

MIT. See `LICENSE`.
