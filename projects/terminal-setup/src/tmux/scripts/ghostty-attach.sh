#!/bin/bash
# Ghostty entry point (config: command = ~/.tmux/scripts/ghostty-attach.sh)
# Reattach the oldest DETACHED tmux session if one exists, otherwise start a new one.
# Stops orphaned sessions piling up when a Ghostty tab/window is closed.
TMUX_BIN=/opt/homebrew/bin/tmux
orphan=$("$TMUX_BIN" list-sessions -F '#{session_attached} #{session_created} #{session_name}' 2>/dev/null \
  | awk '$1==0 {print $2, $3}' | sort -n | head -1 | cut -d' ' -f2-)
if [ -n "$orphan" ]; then
  exec "$TMUX_BIN" attach-session -t "=$orphan"
fi
exec "$TMUX_BIN" new-session
