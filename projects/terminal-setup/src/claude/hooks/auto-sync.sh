#!/bin/bash
# Auto-sync hook for Claude Code
# Triggers Scribe agent in auto-sync mode after file writes/edits

set -euo pipefail

# Get the current working directory (projects directory)
CWD="$(pwd)"

# Only run if we're in a git repository
if ! git -C "$CWD" rev-parse --git-dir > /dev/null 2>&1; then
    exit 0
fi

# Skip if in .claude directory (avoid recursion)
if [[ "$CWD" == *"/.claude"* ]]; then
    exit 0
fi

# Debounce: Check if last auto-commit was within 30 seconds
LAST_COMMIT_TIME=$(git -C "$CWD" log -1 --format=%ct 2>/dev/null || echo 0)
CURRENT_TIME=$(date +%s)
TIME_DIFF=$((CURRENT_TIME - LAST_COMMIT_TIME))

if [ $TIME_DIFF -lt 30 ]; then
    # Too soon, skip this sync
    exit 0
fi

# Check if there are actually changes to commit
if git -C "$CWD" diff --quiet && git -C "$CWD" diff --cached --quiet; then
    exit 0
fi

# Trigger the Scribe agent in background (non-blocking)
# This will be picked up by Claude Code in the next interaction
echo "[Auto-sync triggered for $(basename "$CWD")]" >&2

exit 0
