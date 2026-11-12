# nu-program-status

Nushell implementation of the OSC 7501 Program Status Protocol.

## Layout

- `nu/mod.nu` - public `program-status encode` and `program-status emit` commands.
- `nu/hooks.nu` - optional automatic completion reporting via `program-status install-hooks`.
- `tests/protocol.nu` - protocol tests.
- `tests/hooks_pty.py` - end-to-end PTY tests.

## Usage

```nu
use /path/to/nu-program-status/nu/mod.nu *
program-status emit done --title "build" --message "completed"
```

Enable automatic completion reporting:

```nu
use /path/to/nu-program-status/nu/hooks.nu *
program-status install-hooks --min-duration 10sec
```

## Configuration

`program-status install-hooks` accepts:

- `--min-duration <duration>` - completion threshold (default `10sec`).
- `--excluded <list<string>>` - additional command names to skip.

Mutable environment configuration:

- `$env.PROGRAM_STATUS_ENABLED` - enable/disable automatic reporting (default `true`).
- `$env.PROGRAM_STATUS_MIN_DURATION_MS` - completion threshold in milliseconds.
- `$env.PROGRAM_STATUS_EXCLUDED_COMMANDS` - additional command names to skip.
- `$env.PROGRAM_STATUS_PENDING*` - internal pending-command state.

Explicit flags take precedence over existing environment values; omitted flags
preserve existing values or defaults. Re-running `install-hooks` updates the
threshold when `--min-duration` is passed and does not duplicate hooks.

## Testing

Run from the repository root:

```sh
nu tests/protocol.nu
python3 tests/hooks_pty.py
```

`tests/protocol.nu` covers encoding, validation, sanitization, truncation, and the
exclusion helper. `tests/hooks_pty.py` runs end-to-end PTY checks for hook
installation, idempotence, reporting, restoration, and excluded commands.

Tested with Nushell 0.116.1. The minimum supported Nushell version is not yet
pinned; older versions may differ in hook/config behavior.

## Notes

- Completion-only: no `working` state is emitted automatically.
- Only the first command token is retained as a sanitized, truncated label; arguments are never stored or emitted.
- `LAST_EXIT_CODE` and `CMD_DURATION_MS` are restored after reporting, including their previous absence.
- Compound commands, pipelines, and dynamic invocations are not parsed as a shell AST.
- Direct `opencode`, `claude`, and `codex` invocations are excluded to avoid duplicate native reports.
- Automatic reporting is limited to interactive foreground sessions; non-interactive or background contexts emit nothing.
- Ctrl+C detection relies on the observed `-2` external command exit code. An interrupted Nushell builtin that reports a generic failure is reported as `error`, not `idle`.

## License

MIT. See `LICENSE`.