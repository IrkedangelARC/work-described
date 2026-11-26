#!/bin/bash
# Git status script for tmux - shows detailed git information with labels
# Usage: git-status.sh [path]

cd "${1:-.}" 2>/dev/null || exit 1

# Check if we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "─"
    exit 0
fi

# Get branch name
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -z "$branch" ]; then
    echo "─"
    exit 0
fi

# Get ahead/behind count (unpushed/unpulled commits)
upstream=$(git rev-parse --abbrev-ref @{upstream} 2>/dev/null)
if [ -n "$upstream" ]; then
    ahead_behind=$(git rev-list --left-right --count HEAD...$upstream 2>/dev/null)
    ahead=$(echo "$ahead_behind" | awk '{print $1}')
    behind=$(echo "$ahead_behind" | awk '{print $2}')
else
    ahead=0
    behind=0
fi

# Count uncommitted changes (staged + unstaged)
dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
staged=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
unstaged=$((dirty - staged))

# Count stashes
stashes=$(git stash list 2>/dev/null | wc -l | tr -d ' ')

# Get last push time (time since last commit was pushed to remote)
if [ -n "$upstream" ]; then
    last_push=$(git log -1 --format=%ct "$upstream" 2>/dev/null)
    if [ -n "$last_push" ]; then
        now=$(date +%s)
        diff=$((now - last_push))

        if [ $diff -lt 3600 ]; then
            time_ago="$((diff / 60))m"
        elif [ $diff -lt 86400 ]; then
            time_ago="$((diff / 3600))h"
        else
            time_ago="$((diff / 86400))d"
        fi
    else
        time_ago="?"
    fi
else
    time_ago="no remote"
fi

# Build status string with labels
status=""

# Branch name (always first)
status+="$branch"

# Unpushed commits
if [ "$ahead" -gt 0 ]; then
    status+=" ↑$ahead"
fi

# Unpulled commits
if [ "$behind" -gt 0 ]; then
    status+=" ↓$behind"
fi

# Uncommitted changes (show breakdown if both exist)
if [ "$dirty" -gt 0 ]; then
    if [ "$staged" -gt 0 ] && [ "$unstaged" -gt 0 ]; then
        status+=" ~$dirty(±$staged)"
    else
        status+=" ~$dirty"
    fi
fi

# Stashes
if [ "$stashes" -gt 0 ]; then
    status+=" ✦$stashes"
fi

# Last backup indicator (time since last push)
status+=" | push: $time_ago"

echo "$status"
