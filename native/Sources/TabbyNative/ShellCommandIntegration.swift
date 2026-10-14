import Foundation
import UserNotifications

/// Hooks live only in this shell; no profile files or server packages are changed.
enum ShellCommandIntegration {
    static func script(token: String) -> String {
        #"""
        _axon_history_b64() { printf '%s' "$1" | base64 | tr -d '\r\n'; }
        _axon_history_report() { printf '\033]7;axon-command;__AXON_TOKEN__;%s\007' "$1"; }
        _axon_history_running=0; _axon_history_sequence=0; _axon_history_counter=0
        _axon_history_emit() { if [ -n "${BASH_VERSION-}" ]
        then _axon_history_counter=$(( _axon_history_counter + 1 ))
        _axon_history_sequence=$(( ${_axon_id:-0} * 1000000000 + _axon_history_counter ))
        else _axon_history_sequence=$(( _axon_history_sequence + 1 ))
        fi
        _axon_history_running=1
        _axon_history_started=$SECONDS
        _axon_history_report "begin;$_axon_history_sequence;$(_axon_history_b64 "$1")"
        _axon_history_report "meta;$(_axon_history_b64 "$PWD")"
        }
        _axon_history_finish() { local _axon_code=$? _axon_finish=0
        if [ -n "${BASH_VERSION-}" ]
        then local _axon_latest
        _axon_latest=$(HISTTIMEFORMAT= builtin history 1)
        if [[ "$_axon_latest" =~ ^[[:space:]]*([0-9]+) ]]
        then _axon_history_last=${BASH_REMATCH[1]}
        if [ "$_axon_history_running" = 0 ] && [ "${_axon_history_finished-}" != "$_axon_history_last" ]
        then _axon_history_counter=$(( _axon_history_counter + 1 ))
        _axon_history_sequence=$(( _axon_history_last * 1000000000 + _axon_history_counter ))
        fi
        if [ "${_axon_history_finished-}" != "$_axon_history_last" ]
        then _axon_finish=1
        fi
        _axon_history_finished=$_axon_history_last
        fi
        else _axon_finish=$_axon_history_running
        fi
        if [ "$_axon_finish" = 1 ]
        then _axon_history_report "end;$_axon_history_sequence;$_axon_code;$(( $_axon_history_running == 1 ? SECONDS-_axon_history_started : 0 ))"
        fi
        _axon_history_running=0
        _axon_history_report "meta;$(_axon_history_b64 "$PWD")"
        _axon_history_report prompt
        return "$_axon_code"
        }
        if [ -n "${ZSH_VERSION-}" ]; then
        autoload -Uz add-zsh-hook
        add-zsh-hook -d preexec _axon_history_emit 2>/dev/null
        add-zsh-hook -d precmd _axon_history_finish 2>/dev/null
        add-zsh-hook preexec _axon_history_emit
        add-zsh-hook precmd _axon_history_finish
        _axon_history_report ready
        elif [ -n "${BASH_VERSION-}" ]; then
        _axon_history_last=
        # Readline completion inherits DEBUG with the previous BASH_COMMAND.
        # It must not consume the next execution or attribute it to that command.
        _axon_history_begin() { [ "${COMP_LINE+x}" != x ] || return; [ "${FUNCNAME[1]-}" != _axon_history_prompt ] || return; case "$1" in _axon_*|trap\ *|exit|return\ *) return;; esac; [ "${_axon_history_in_prompt-0}" = 0 ] || return; [ "$_axon_history_running" = 0 ] || return; local _axon_line _axon_id _axon_cmd; _axon_line=$(HISTTIMEFORMAT= builtin history 1); if [[ "$_axon_line" =~ ^[[:space:]]*([0-9]+) ]]; then _axon_id=${BASH_REMATCH[1]}; if [ "$_axon_history_last" = "$_axon_id" ]; then [ "$BASH_SUBSHELL" = 0 ] || return; _axon_cmd=$1; else _axon_cmd=$(printf '%s' "$_axon_line" | sed '1s/^[[:space:]]*[0-9]*[*[:space:]]*//'); fi; _axon_history_last=$_axon_id; _axon_history_finished=; _axon_history_emit "$_axon_cmd"; fi; }
        if ! [[ "${PROMPT_COMMAND[*]-}" == *'_axon_history_prompt'* ]]; then
        if declare -p PROMPT_COMMAND 2>/dev/null | grep -q 'declare -a'; then _axon_history_saved_prompt=("${PROMPT_COMMAND[@]}"); else _axon_history_saved_prompt=("${PROMPT_COMMAND-}"); fi
        _axon_history_finish_status() { return "$1"; }
        # Preserve the user command status when the completion hook is called.
        _axon_history_prompt() { local _axon_code=$? _axon_prompt_command; _axon_history_in_prompt=1; _axon_history_finish_status "$_axon_code"; _axon_history_finish; for _axon_prompt_command in "${_axon_history_saved_prompt[@]}"; do _axon_history_finish_status "$_axon_code"; eval -- "$_axon_prompt_command"; _axon_code=$?; done; _axon_history_in_prompt=0; }
        PROMPT_COMMAND=_axon_history_prompt
        fi
        if [ -z "$(trap -p DEBUG)" ]; then set -o functrace; trap '_axon_history_begin "$BASH_COMMAND"' DEBUG; _axon_history_report ready; else printf '%s\n' 'Axon history: existing DEBUG trap retained; command timing unavailable.'; _axon_history_report unsupported; fi
        else
        _axon_history_report unsupported
        fi
        """#.replacingOccurrences(of: "__AXON_TOKEN__", with: token)
    }
}

@MainActor enum CommandCompletionNotification {
    static func requestPermission() {
        guard Bundle.main.bundleIdentifier == "org.tabby.native" else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func send(_ entry: ExecutedCommand) {
        guard Bundle.main.bundleIdentifier == "org.tabby.native" else { return }
        let content = UNMutableNotificationContent()
        content.title = entry.hostName
        content.body = "Command finished / 命令已完成 · exit \(entry.exitCode ?? 0) · \(Int(entry.duration ?? 0))s"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: entry.id.uuidString, content: content, trigger: nil)) { _ in }
    }
}
