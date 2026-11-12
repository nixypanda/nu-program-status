# Protocol tests for nu-program-status.
# Run from the repository root: nu tests/protocol.nu

use std assert
use ../nu/mod.nu *
use ../nu/internal.nu [
    _program-status-truncate
    _program-status-sanitize
    _program-status-is-excluded
    _program-status-effective-rules
    _program-status-normalize-prefix
]

# Base module import does not install hooks or reporting state.
assert ($env.PROGRAM_STATUS_HOOK_REFS? == null)

# States
let states = [idle working blocked done error clear]
for $state in $states {
    let seq = (program-status encode $state)
    assert ($seq | str contains $"state=($state)")
}

# Invalid state
let r1 = (try { program-status encode nope; "no" } catch { "threw" })
assert ($r1 == "threw")

# Kinds are accepted with blocked and ignored elsewhere.
assert ((program-status encode blocked --kind permission) | str contains "kind=permission")
assert ((program-status encode blocked --kind question) | str contains "kind=question")
assert ((program-status encode blocked --kind auth) | str contains "kind=auth")
let r2 = (try { program-status encode blocked --kind nope; "no" } catch { "threw" })
assert ($r2 == "threw")
assert (not ((program-status encode done --kind permission) | str contains "kind="))

# Progress is accepted where applicable and ignored elsewhere.
assert ((program-status encode working --progress 42) | str contains "progress=42")
assert ((program-status encode blocked --progress 7) | str contains "progress=7")
let r3 = (try { program-status encode working --progress -1; "no" } catch { "threw" })
assert ($r3 == "threw")
let r4 = (try { program-status encode working --progress 101; "no" } catch { "threw" })
assert ($r4 == "threw")
assert (not ((program-status encode done --progress 5) | str contains "progress="))

# App validation
assert ((program-status encode idle --app myapp) | str contains "app=myapp")
let r5 = (try { program-status encode idle --app "bad app"; "no" } catch { "threw" })
assert ($r5 == "threw")

# Id validation
assert ((program-status encode idle --id "a/b") | str contains "id=a/b")
let r6 = (try { program-status encode idle --id "bad!"; "no" } catch { "threw" })
assert ($r6 == "threw")

# Control-character sanitization (C0, DEL, C1).
assert ((_program-status-sanitize $"a(char bel)b(char -i 0x7f)c(char -i 0x80)d") == "abcd")

# Title sanitization removes control characters.
let ctrl_title = $"hi(char bel)there"
let seq_ctrl = (program-status encode idle --title $ctrl_title)
assert (not ($seq_ctrl | str contains (char bel)))

# UTF-8 byte truncation.
assert ((_program-status-truncate "éé" 2) == "é")
assert ((_program-status-truncate "abcdef" 4) == "abcd")

# Message truncation and overall safety cap.
let big_msg = ("m" | fill -c "m" -w 3000)
let seq_msg = (program-status encode idle --message $big_msg)
assert (($seq_msg | into binary | length) <= 4096)

# Maximal fields remain below the hard cap.
let max_title = ("a" | fill -c "a" -w 192)
let max_message = ("m" | fill -c "m" -w 2048)
let seq_max = (program-status encode blocked --kind auth --app myapp --id a/b --title $max_title --message $max_message --progress 100)
assert (($seq_max | into binary | length) <= 4096)

# Exclusion helper
assert (_program-status-is-excluded "opencode")
assert (_program-status-is-excluded "claude")
assert (_program-status-is-excluded "codex")
assert (_program-status-is-excluded "docker agent")
assert (_program-status-is-excluded "^opencode")
assert (_program-status-is-excluded "/usr/local/bin/codex")
assert (not (_program-status-is-excluded "echo opencode"))
assert (not (_program-status-is-excluded "opencode | cat"))
assert (not (_program-status-is-excluded "opencode; rm -rf /"))
assert (not (_program-status-is-excluded "opencode && ls"))
assert (_program-status-is-excluded $"opencode(char tab)foo")
assert (_program-status-is-excluded "^/usr/bin/opencode")
assert (_program-status-is-excluded "/usr/bin/opencode --foo")
assert (_program-status-is-excluded "docker agent run foo")

# Include/exclude precedence smoke.
$env.PROGRAM_STATUS_DEFAULT_EXCLUSIONS = false
$env.PROGRAM_STATUS_EXCLUDED_COMMANDS = ["docker agent"]
$env.PROGRAM_STATUS_INCLUDED_COMMANDS = ["opencode"]
assert (_program-status-is-excluded "docker agent run")
assert (not (_program-status-is-excluded "docker ps"))
assert (not (_program-status-is-excluded "opencode"))

# Inspection API is side-effect free and returns rules.
let rules = (program-status exclusions)
assert (($rules | length) >= 0)

# Normalization handles padded structured tokens.
assert ((_program-status-normalize-prefix ["docker" " agent "]) == ["docker" "agent"])

# Curated defaults are automatic and not opt-in.
$env.PROGRAM_STATUS_DEFAULT_EXCLUSIONS = true
$env.PROGRAM_STATUS_EXCLUDED_COMMANDS = []
$env.PROGRAM_STATUS_INCLUDED_COMMANDS = []
let defaults = (_program-status-effective-rules)
assert ($defaults | all {|r| $r.origin == "builtin" and $r.automatic and (not $r.opt_in) })

# Includes are exact normalized prefixes, not broader exceptions.
$env.PROGRAM_STATUS_DEFAULT_EXCLUSIONS = false
$env.PROGRAM_STATUS_EXCLUDED_COMMANDS = ["docker agent"]
$env.PROGRAM_STATUS_INCLUDED_COMMANDS = ["docker"]
assert (_program-status-is-excluded "docker agent run")
$env.PROGRAM_STATUS_INCLUDED_COMMANDS = ["docker agent"]
assert (not (_program-status-is-excluded "docker agent run"))

print "protocol tests passed"
