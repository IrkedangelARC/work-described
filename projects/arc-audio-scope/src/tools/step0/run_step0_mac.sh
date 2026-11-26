#!/bin/zsh
# ARC Audio Scope step 0, Mac items 2, 3 and 6. Plays silence only, sets the interface to 48 kHz.
# Usage: tools/step0/run_step0_mac.sh [device name fragment] [seconds]
set -e
here="${0:A:h}"
out="${TMPDIR:-/tmp}/arc_audio_scope_step0_mac"
swiftc -O -o "$out" "$here/step0_mac.swift"
"$out" "$@"
