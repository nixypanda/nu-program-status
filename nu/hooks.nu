# Optional automatic completion reporting for Nushell (OSC 7501).
#
# Import this module and call `program-status install-hooks` to enable hooks:
#
#   use /path/to/nu-program-status/nu/hooks.nu *
#   program-status install-hooks --min-duration 10sec
#
# `program-status encode` and `program-status emit` remain available from
# nu/mod.nu.

use ./internal.nu [
    _program-status-truncate
    _program-status-sanitize
    _program-status-is-excluded
]
use ./mod.nu *

export def --env "program-status install-hooks" [
    --min-duration: duration
    --exclude: list<string>
    --excluded: list<string>
    --include: list<string>
    --no-default-exclusions
    --default-exclusions
] {
    if ($no_default_exclusions and $default_exclusions) {
        error make { msg: "use either --no-default-exclusions or --default-exclusions, not both" }
    }

    # Establish defaults without overwriting explicit prior configuration.
    if ($env.PROGRAM_STATUS_ENABLED? == null) {
        $env.PROGRAM_STATUS_ENABLED = true
    }

    let threshold_ms = if ($min_duration != null) {
        ($min_duration / 1ms | into int)
    } else {
        let existing = ($env.PROGRAM_STATUS_MIN_DURATION_MS? | default null)
        if ($existing != null) {
            try { $existing | into int } catch { 10000 }
        } else {
            10000
        }
    }
    $env.PROGRAM_STATUS_MIN_DURATION_MS = ($threshold_ms | into string)

    let excluded_value = if ($exclude != null) {
        $exclude
    } else if ($excluded != null) {
        $excluded
    } else {
        (try { $env.PROGRAM_STATUS_EXCLUDED_COMMANDS } catch { [] })
    }
    let included_value = if ($include != null) {
        $include
    } else {
        (try { $env.PROGRAM_STATUS_INCLUDED_COMMANDS } catch { [] })
    }

    let existing_default = (try { $env.PROGRAM_STATUS_DEFAULT_EXCLUSIONS } catch { true })
    let default_value = if $no_default_exclusions {
        false
    } else if $default_exclusions {
        true
    } else {
        if (($existing_default | describe) == "bool") {
            $existing_default
        } else {
            (($existing_default | into string | str lowercase) == "true")
        }
    }

    $env.PROGRAM_STATUS_EXCLUDED_COMMANDS = $excluded_value
    $env.PROGRAM_STATUS_INCLUDED_COMMANDS = $included_value
    $env.PROGRAM_STATUS_DEFAULT_EXCLUSIONS = $default_value

    $env.PROGRAM_STATUS_PENDING = false
    $env.PROGRAM_STATUS_PENDING_LABEL = ""
    $env.PROGRAM_STATUS_PENDING_EXCLUDED = false

    if ($env.config? | is-empty) {
        return
    }

    let existing_pre_prompt = (try { $env.config.hooks.pre_prompt } catch { [] })
    let existing_pre_execution = (try { $env.config.hooks.pre_execution } catch { [] })
    let old_refs = ($env.PROGRAM_STATUS_HOOK_REFS? | default { pre_prompt: [], pre_execution: [] })

    let filtered_pre_prompt = ($existing_pre_prompt | where { |h|
        not ($old_refs.pre_prompt | any { |r| $r == $h })
    })
    let filtered_pre_execution = ($existing_pre_execution | where { |h|
        not ($old_refs.pre_execution | any { |r| $r == $h })
    })

    let new_pre_prompt = {||
        let had_last = ($env.LAST_EXIT_CODE? != null)
        let had_dur = ($env.CMD_DURATION_MS? != null)
        let saved_last = ($env.LAST_EXIT_CODE? | default null)
        let saved_dur = ($env.CMD_DURATION_MS? | default null)
        let captured_exit = (try { $ans.exit_code } catch { null })

        let enabled_raw = ($env.PROGRAM_STATUS_ENABLED? | default true)
        let enabled = if (($enabled_raw | describe) == "bool") {
            $enabled_raw
        } else {
            (($enabled_raw | into string | str lowercase) == "true")
        }
        let pending_raw = ($env.PROGRAM_STATUS_PENDING? | default false)
        let pending = if (($pending_raw | describe) == "bool") {
            $pending_raw
        } else {
            (($pending_raw | into string | str lowercase) == "true")
        }
        let label = ($env.PROGRAM_STATUS_PENDING_LABEL? | default "")
        let excluded_raw = ($env.PROGRAM_STATUS_PENDING_EXCLUDED? | default false)
        let excluded = if (($excluded_raw | describe) == "bool") {
            $excluded_raw
        } else {
            (($excluded_raw | into string | str lowercase) == "true")
        }

        $env.PROGRAM_STATUS_PENDING = false
        $env.PROGRAM_STATUS_PENDING_LABEL = ""
        $env.PROGRAM_STATUS_PENDING_EXCLUDED = false

        let duration_ms = (try { ($env.CMD_DURATION_MS? | default "0") | into int } catch { 0 })
        let threshold = (try { ($env.PROGRAM_STATUS_MIN_DURATION_MS? | default "10000") | into int } catch { 10000 })

        if ($enabled and $pending and (not $excluded) and ($label | str trim | is-not-empty) and ($duration_ms >= $threshold)) {
            let exit_code = if ($captured_exit != null) {
                $captured_exit
            } else {
                try { ($env.LAST_EXIT_CODE? | default "0") | into int } catch { 0 }
            }
            let state = if ($exit_code == 0) {
                "done"
            } else if ($exit_code == -2) {
                "idle"
            } else {
                "error"
            }
            let message = if ($exit_code == 0) {
                $"completed in ($duration_ms) ms"
            } else if ($exit_code == -2) {
                "interrupted"
            } else {
                $"failed with exit code ($exit_code) after ($duration_ms) ms"
            }
            if (is-terminal) {
                try {
                    print --no-newline (program-status encode $state --app "nu" --title $label --message $message)
                } catch { }
            }
        }

        if $had_last {
            $env.LAST_EXIT_CODE = $saved_last
        } else {
            hide-env -i LAST_EXIT_CODE
        }
        if $had_dur {
            $env.CMD_DURATION_MS = $saved_dur
        } else {
            hide-env -i CMD_DURATION_MS
        }
        null
    }

    let new_pre_execution = {||
        let cmd = (try { commandline } catch { "" })
        let label = if ($cmd | str trim | is-empty) {
            ""
        } else {
            let first = ($cmd | str trim | split row --regex "\\s+" | get 0)
            _program-status-truncate (_program-status-sanitize $first) 192
        }
        $env.PROGRAM_STATUS_PENDING = true
        $env.PROGRAM_STATUS_PENDING_LABEL = $label
        $env.PROGRAM_STATUS_PENDING_EXCLUDED = (_program-status-is-excluded $cmd)
        null
    }

    $env.config = ($env.config | upsert hooks.pre_prompt ([$new_pre_prompt] | append $filtered_pre_prompt))
    $env.config = ($env.config | upsert hooks.pre_execution ([$new_pre_execution] | append $filtered_pre_execution))

    $env.PROGRAM_STATUS_HOOK_REFS = { pre_prompt: [$new_pre_prompt], pre_execution: [$new_pre_execution] }
}
