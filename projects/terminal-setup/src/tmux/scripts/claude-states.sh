#!/bin/bash
# Claude sessions for the tmux status bar: ● working  ◆ waiting on you  ○ idle.
# State files are written by ~/.claude/hooks/activity.sh (one per Claude session).
# A state is dropped when its tmux pane is gone or it is older than 12 h (crash without SessionEnd).
. ~/.tmux/arc-colors.sh 2>/dev/null
TMUX_BIN=/opt/homebrew/bin/tmux
now=$(date +%s); out=""
live_panes=" $("$TMUX_BIN" list-panes -a -F '#{pane_id}' 2>/dev/null | tr '\n' ' ')"
for f in ~/.claude/state/*; do
  [ -f "$f" ] || continue
  IFS=$'\t' read -r name st ts pane < "$f"
  if [ $((now - ${ts:-0})) -gt 43200 ] || { [ -n "$pane" ] && [[ "$live_panes" != *" $pane "* ]]; }; then
    rm -f "$f"; continue
  fi
  case "$st" in
    working) seg="#[fg=$LIVE]● #[fg=$TXT]$name" ;;
    waiting) seg="#[fg=$WARN]◆ #[fg=$TXT,bold]$name#[nobold]" ;;
    *)       seg="#[fg=$DIM]○ $name" ;;
  esac
  out+="$seg  "
done
printf '%s' "${out:+#[fg=$LINE]│  }$out"
