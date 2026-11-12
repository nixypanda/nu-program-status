# Internal helpers for nu-program-status. Not part of the public API.

export def _program-status-truncate [text: string, limit: int] : nothing -> string {
    mut result = ""
    mut bytes = 0
    for c in ($text | split chars) {
        let cb = ($c | into binary | length)
        if ($bytes + $cb) <= $limit {
            $result = $result + $c
            $bytes = $bytes + $cb
        } else {
            break
        }
    }
    $result
}

export def _program-status-sanitize [text: string] : nothing -> string {
    $text | str replace --all --regex "\\p{Cc}" ""
}

export def _program-status-valid-id [value: string] : nothing -> bool {
    if ($value | str length) > 128 {
        return false
    }
    $value =~ '^[A-Za-z0-9_.+-]{1,32}(/[A-Za-z0-9_.+-]{1,32}){0,7}$'
}

export def _program-status-is-agent-direct [command: string] : nothing -> bool {
    let trimmed = ($command | str trim)
    if ($trimmed | is-empty) {
        return false
    }
    if (($trimmed | str contains "|") or ($trimmed | str contains ";") or ($trimmed | str contains "&") or ($trimmed | str contains "$") or ($trimmed | str contains "`") or ($trimmed | str contains (char newline))) {
        return false
    }
    let first = ($trimmed | split row --regex "\\s+" | get 0)
    let has_caret = ($first | str starts-with "^")
    let cmd = if $has_caret {
        $first | str substring 1..
    } else {
        $first
    }
    let base = if ($cmd | str contains "/") {
        $cmd | path basename
    } else {
        $cmd
    }
    let bare_agent = (($cmd | str contains "/") == false) and ($base in ["opencode" "claude" "codex"])
    let is_direct_syntax = $has_caret or ($cmd | str starts-with "/") or $bare_agent
    if not $is_direct_syntax {
        return false
    }
    $base in ["opencode" "claude" "codex"]
}
