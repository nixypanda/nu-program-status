# Program status (OSC 7501) helpers for Nushell.
#
# Public API: `program-status encode` and `program-status emit`.
# Automatic completion reporting is separate and opt-in via hooks.nu.

use ./internal.nu [
    _program-status-truncate
    _program-status-sanitize
    _program-status-valid-id
]

export def "program-status encode" [
    state: string
    --app: string
    --id: string
    --title: string
    --message: string
    --progress: int
    --kind: string
] : nothing -> string {
    let valid_states = [idle working blocked done error clear]
    if not ($state in $valid_states) {
        error make { msg: $"invalid state: ($state)" }
    }

    if ($kind != null) {
        if not ($kind in [permission question auth]) {
            error make { msg: $"invalid kind: ($kind)" }
        }
    }

    if ($progress != null) {
        if $progress < 0 or $progress > 100 {
            error make { msg: $"invalid progress: ($progress)" }
        }
    }

    if ($app != null) {
        if not ($app =~ '^[A-Za-z0-9_.+-]{1,32}$') {
            error make { msg: $"invalid app: ($app)" }
        }
    }

    if ($id != null) {
        if not (_program-status-valid-id $id) {
            error make { msg: $"invalid id: ($id)" }
        }
    }

    mut pairs = [$"state=($state)"]

    if ($state == "blocked") and ($kind != null) {
        $pairs = ($pairs | append $"kind=($kind)")
    }

    if ($id != null) {
        $pairs = ($pairs | append $"id=($id)")
    }

    if ($app != null) {
        $pairs = ($pairs | append $"app=($app)")
    }

    if ($title != null) {
        let clean = (_program-status-truncate (_program-status-sanitize $title) 192)
        let b64 = ($clean | encode base64)
        $pairs = ($pairs | append $"title=($b64)")
    }

    if ($message != null) {
        let clean = (_program-status-truncate (_program-status-sanitize $message) 2048)
        let b64 = ($clean | encode base64)
        $pairs = ($pairs | append $"msg=($b64)")
    }

    if ($progress != null) and (($state == "working") or ($state == "blocked")) {
        $pairs = ($pairs | append $"progress=($progress)")
    }

    let body = ($pairs | str join ":")
    let seq = $"\u{001b}]7501;($body)\u{001b}\\"

    if (($seq | into binary | length) > 4096) {
        error make { msg: "program status sequence exceeds 4096 bytes" }
    }

    $seq
}

export def "program-status emit" [
    state: string
    --app: string
    --id: string
    --title: string
    --message: string
    --progress: int
    --kind: string
] {
    let seq = (program-status encode $state --app $app --id $id --title $title --message $message --progress $progress --kind $kind)
    if (is-terminal) {
        print --no-newline $seq
    }
}
