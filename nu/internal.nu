# Internal helpers for nu-program-status. Not part of the public API.

const _program_status_dir = (path self | path dirname)
const _program_status_registry_path = ($_program_status_dir | path join "data" "exclusions.nuon")

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

export def _program-status-as-list [value] {
    if ($value == null) {
        return []
    }
    if (($value | describe) | str starts-with "list") {
        return $value
    }
    $value | into string | split row --regex '\s+'
}

export def _program-status-env-list-any [names: list<string>] {
    for $name in $names {
        let raw = (try { $env | get $name } catch { null })
        if ($raw != null) {
            return (_program-status-as-list $raw)
        }
    }
    []
}

export def _program-status-env-bool-any [names: list<string>, default: bool] {
    for $name in $names {
        let raw = (try { $env | get $name } catch { null })
        if ($raw != null) {
            if (($raw | describe) == "bool") {
                return $raw
            }
            let s = ($raw | into string | str trim | str lowercase)
            if ($s in ["1" "true" "yes" "on"]) {
                return true
            }
            if ($s in ["0" "false" "no" "off" ""]) {
                return false
            }
            return $default
        }
    }
    $default
}

export def _program-status-load-native-reporters [] {
    if not ($_program_status_registry_path | path exists) {
        return []
    }
    try {
        open $_program_status_registry_path
    } catch {
        []
    }
}

export def _program-status-normalize-prefix [value] {
    # Accept a string or a list of strings.  Each string is split on
    # whitespace and every resulting token is trimmed, so padded entries such
    # as ["docker", " agent "] normalize to ["docker" "agent"].
    let raw = if (($value | describe) | str starts-with "list") {
        $value
    } else {
        [$value]
    }

    mut collected = []
    for $item in $raw {
        if (($item | describe) | str starts-with "list") {
            for $sub in $item {
                $collected = ($collected | append $sub)
            }
        } else {
            $collected = ($collected | append $item)
        }
    }

    mut tokens = []
    for $item in $collected {
        let split = ($item | into string | split row --regex '\s+')
        for $part in $split {
            let trimmed = ($part | str trim)
            if ($trimmed | is-not-empty) {
                $tokens = ($tokens | append $trimmed)
            }
        }
    }

    if ($tokens | is-empty) {
        return []
    }
    let first_raw = ($tokens | get 0)
    let has_caret = ($first_raw | str starts-with "^")
    mut first = if $has_caret {
        $first_raw | str substring 1..
    } else {
        $first_raw
    }
    if ($first | str contains "/") {
        $first = ($first | path basename)
    }
    ([$first] | append ($tokens | skip 1))
}

export def _program-status-native-rules [] {
    _program-status-load-native-reporters | each {|entry|
        let prefix = (_program-status-normalize-prefix ($entry.prefix? | default []))
        if ($prefix | is-empty) {
            null
        } else {
            {
                origin: "builtin"
                prefix: $prefix
                reason: ($entry.reason? | default "native-status")
            }
        }
    } | where {|r| $r != null }
}

export def _program-status-user-rules [values, origin: string] {
    let values = (_program-status-as-list $values)
    $values | each {|v|
        let prefix = (_program-status-normalize-prefix $v)
        if ($prefix | is-empty) {
            null
        } else {
            {
                origin: $origin
                prefix: $prefix
                reason: "user-config"
            }
        }
    } | where {|r| $r != null }
}

export def _program-status-effective-rules [] {
    let defaults_enabled = (_program-status-env-bool-any ["PROGRAM_STATUS_DEFAULT_EXCLUSIONS" "PROGRAM_STATUS_USE_DEFAULT_EXCLUSIONS"] true)
    mut rules = []
    if $defaults_enabled {
        $rules = (_program-status-native-rules)
    }

    let user_excludes = (_program-status-env-list-any ["PROGRAM_STATUS_EXCLUDED_COMMANDS"])
    $rules = ($rules | append (_program-status-user-rules $user_excludes "user"))

    let user_includes = (_program-status-env-list-any ["PROGRAM_STATUS_INCLUDED_COMMANDS" "PROGRAM_STATUS_INCLUDE_COMMANDS"])
    let include_prefixes = ($user_includes | each {|v| _program-status-normalize-prefix $v })

    $rules = ($rules | where {|r|
        let key = ($r.prefix | str join "\u{001f}")
        let included = ($include_prefixes | any {|p| (($p | str join "\u{001f}") == $key) })
        not $included
    })

    mut seen = []
    mut result = []
    for $r in $rules {
        let key = ($r.prefix | str join "\u{001f}")
        if not ($key in $seen) {
            $seen = ($seen | append $key)
            $result = ($result | append $r)
        }
    }
    $result
}

export def _program-status-is-excluded [command: string] : nothing -> bool {
    let trimmed = ($command | str trim)
    if ($trimmed | is-empty) {
        return false
    }
    if (($trimmed | str contains "|") or ($trimmed | str contains ";") or ($trimmed | str contains "&") or ($trimmed | str contains "$") or ($trimmed | str contains "`") or ($trimmed | str contains (char newline))) {
        return false
    }

    let rules = (_program-status-effective-rules)
    if ($rules | is-empty) {
        return false
    }

    let tokens = ($trimmed | split row --regex '\s+')
    let max_len = ($rules | get prefix | each {|p| ($p | length) } | math max)
    let take = if (($tokens | length) < $max_len) { ($tokens | length) } else { $max_len }
    let sliced = ($tokens | first $take)

    let first_raw = ($sliced | get 0)
    let has_caret = ($first_raw | str starts-with "^")
    mut first = if $has_caret {
        $first_raw | str substring 1..
    } else {
        $first_raw
    }
    if ($first | str contains "/") {
        $first = ($first | path basename)
    }
    let norm_cmd = ([$first] | append ($sliced | skip 1))

    for $r in $rules {
        let rlen = ($r.prefix | length)
        if (($norm_cmd | length) >= $rlen) {
            let slice = ($norm_cmd | first $rlen)
            if (($slice | to nuon) == ($r.prefix | to nuon)) {
                return true
            }
        }
    }
    false
}

export def _program-status-is-agent-direct [command: string] : nothing -> bool {
    _program-status-is-excluded $command
}

export def _program-status-command-excluded [command: string] : nothing -> bool {
    _program-status-is-excluded $command
}