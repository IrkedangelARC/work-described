#!/bin/bash
# Claude Code Notification hook -> macOS notification.
# Works regardless of tmux (osascript talks to Notification Center directly).
input=$(cat)
msg=$(printf '%s' "$input" | /usr/bin/jq -r '.message // "Claude Code needs attention"')
dir=$(printf '%s' "$input" | /usr/bin/jq -r '.cwd // empty' | xargs -0 basename 2>/dev/null)
sess=""
[ -n "$TMUX" ] && sess=$(/opt/homebrew/bin/tmux display-message -p 'tmux #S' 2>/dev/null)
sub="${dir:-claude}${sess:+ · $sess}"
msg=${msg//\"/\'}; sub=${sub//\"/\'}
/usr/bin/osascript -e "display notification \"$msg\" with title \"Claude Code\" subtitle \"$sub\" sound name \"Glass\""
