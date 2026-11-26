#!/bin/bash
# Live Claude activity feed (all sessions). Opened by tmux prefix + a.
printf '\e]2;claude activity\a'
touch ~/.claude/activity.log
exec tail -n 40 -F ~/.claude/activity.log 2>/dev/null
