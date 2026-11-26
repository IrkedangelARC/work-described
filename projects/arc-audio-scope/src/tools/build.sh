#!/bin/zsh
# Build ARC Audio Scope for this Mac. Prints the path of the built app. Does not launch it.
# Usage: tools/build.sh [ios]   (ios = compile check for iPad, unsigned)
set -e
cd "${0:A:h}/.."
xcodegen generate --quiet
if [[ "$1" == "ios" ]]; then
  xcodebuild -project ArcAudioScope.xcodeproj -scheme ArcAudioScope -destination 'generic/platform=iOS' \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO -quiet build
  echo "iPad compile check passed."
else
  xcodebuild -project ArcAudioScope.xcodeproj -scheme ArcAudioScope -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build -quiet build
  echo "$PWD/build/Build/Products/Debug/ARC Audio Scope.app"
fi
