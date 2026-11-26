#!/bin/bash
# Build ARC QUAD Mic (the virtual microphone that goes with the ARC QUAD virtual camera),
# test it without installing it, and sign it. Installs NOTHING: tools/install.sh does that.
#
#   quadmic/tools/build.sh             build, self test, sign with the Developer ID
#   quadmic/tools/build.sh --no-sign   build and self test only
#
# Output: quadmic/build/ArcQuadMic.driver
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/build"
DRV="$OUT/ArcQuadMic.driver"
SIGN=1; [ "${1:-}" = "--no-sign" ] && SIGN=0

rm -rf "$OUT"
mkdir -p "$DRV/Contents/MacOS"
cp "$HERE/Info.plist" "$DRV/Contents/Info.plist"

WARN="-Wall -Wextra -Werror=incompatible-pointer-types -Werror=implicit-function-declaration"
clang -bundle -O2 $WARN -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
    -framework CoreAudio -framework CoreFoundation \
    -o "$DRV/Contents/MacOS/ArcQuadMic" "$HERE/ArcQuadMic.c"
clang -O1 $WARN -framework CoreAudio -framework CoreFoundation \
    -o "$OUT/selftest" "$HERE/tools/selftest.c"
# looptest: the proof after the install (plays into the installed device and records it back).
clang -O1 $WARN -framework CoreAudio -framework CoreFoundation \
    -o "$OUT/looptest" "$HERE/tools/looptest.c"

echo "built: $DRV ($(lipo -archs "$DRV/Contents/MacOS/ArcQuadMic"))"
"$OUT/selftest" "$DRV"

if [ "$SIGN" = 1 ]; then
    ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    if [ -z "$ID" ]; then echo "STOP: no Developer ID Application identity in the keychain"; exit 1; fi
    codesign --force --timestamp --options runtime -s "$ID" "$DRV"
    codesign --verify --strict "$DRV" && echo "signed: Developer ID, hardened runtime"
    # The self test once more, on the signed bundle: what would be installed is what was tested.
    "$OUT/selftest" "$DRV"
fi
