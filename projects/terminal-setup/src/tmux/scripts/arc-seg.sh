#!/bin/bash
# Status segments for the ARC bracket bar (~/.tmux/arc-theme.conf). Plain text, no emoji, no labels:
# the bracket supplies the label. Wraps the existing per-metric scripts.
# Usage: arc-seg.sh in|op|net|mon|outv|outcap [path]
S=~/.tmux/scripts
case "$1" in
  in)     "$S/git-status.sh" "$2" | sed 's/ | push:.*//; s/✦/+/g' ;;
  outcap) "$S/git-status.sh" "$2" | sed -n 's/.*push: //p' | grep . || echo "─" ;;
  outv)   "$S/git-backup-status.sh" "$2" | sed 's/^GIT: *//; s/⚡/DIRTY/; s/✓/CLEAN/' ;;
  op)     out=$("$S/active-processes.sh" | sed 's/^PROC: *//')
          [ "$out" = "─" ] && { echo "IDLE"; exit; }
          echo "$out" | sed 's/🎬/RESOLVE/; s/🐍/PY/; s/🎞️/FFMPEG/; s/🎞/FFMPEG/' ;;
  net)    "$S/network-type.sh" | sed 's/^NET: *//' | LC_ALL=C sed 's/[^ -~]//g; s/^ *//' ;;
  mon)    cpu=$("$S/cpu-status.sh" | sed 's/^CPU: *//'); ram=$("$S/memory-status.sh" | sed 's/^RAM: *//; s/ (.*//')
          echo "CPU $cpu  RAM $ram" ;;
esac
