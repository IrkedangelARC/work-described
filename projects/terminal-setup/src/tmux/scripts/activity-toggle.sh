#!/bin/bash
# prefix + a: open/close the Claude activity feed as a bottom strip in the current window.
# The feed pane is tagged with the pane option @activity so it is found regardless of its title.
TMUX_BIN=/opt/homebrew/bin/tmux
win=$1; dir=${2:-$HOME}
feed=$("$TMUX_BIN" list-panes -t "$win" -F '#{pane_id} #{@activity}' | awk '$2=="1"{print $1; exit}')
if [ -n "$feed" ]; then
  "$TMUX_BIN" kill-pane -t "$feed"
else
  id=$("$TMUX_BIN" split-window -v -f -l 25% -d -P -F '#{pane_id}' -t "$win" -c "$dir" ~/.claude/hooks/activity-view.sh)
  "$TMUX_BIN" set -p -t "$id" @activity 1
fi
