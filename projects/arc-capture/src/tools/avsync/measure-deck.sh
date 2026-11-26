#!/bin/zsh
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

# Measure a CAPTURED deck of the A/V reference movie: flash-vs-click per event, mean, spread and drift.
# The reference deck is tools/avsync/reference/ARC AV Reference.pptx (white flash + 1 kHz click every 5 s,
# burned-in counter, plays automatically on entry). Capture it, then:
#
#   tools/avsync/measure-deck.sh "/path/to/Something.arcdeck"
#
# Positive = audio LATE. A growing offset = a lost buffer. A steady slope = a clock-rate mismatch.
set -e
setopt nullglob 2>/dev/null || true
cd "$(dirname "$0")/../.."
DECK="${1:?path to the captured .arcdeck}"
CLIP=$(ls -S "$DECK"/media/*.mov "$DECK"/media/*.mp4 2>/dev/null | head -1)
setopt -o nullglob 2>/dev/null || true
[ -n "$CLIP" ] || { echo "no clip in $DECK/media"; exit 1; }
echo "deck: $DECK"
echo "clip: $(basename "$CLIP")"
python3 tools/avsync/measure.py "$CLIP" "crop=iw:ih:0:0"
