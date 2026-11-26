#!/bin/zsh
# Read the running app: tools/state.sh [path, default /state]   e.g. tools/state.sh "/set?weighting=C"
curl -s --max-time 3 "http://127.0.0.1:8767${1:-/state}" || echo "ARC Audio Scope is not answering on 127.0.0.1:8767 (is it running?)"
