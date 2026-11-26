#!/bin/bash
# Build ARC Dictate and install it to /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

xcodegen generate
xcodebuild -project ArcDictate.xcodeproj \
           -scheme ArcDictate \
           -configuration Release \
           -derivedDataPath build \
           build

APP="$ROOT/build/Build/Products/Release/ARC Dictate.app"

if pgrep -f "ARC Dictate.app/Contents/MacOS" >/dev/null; then
    echo "Quitting the running copy..."
    osascript -e 'tell application "ARC Dictate" to quit' 2>/dev/null || pkill -f "ARC Dictate.app/Contents/MacOS" || true
    sleep 1
fi

rm -rf "/Applications/ARC Dictate.app"
cp -R "$APP" /Applications/
echo "Installed: /Applications/ARC Dictate.app"
echo "Launch it yourself when you are ready — it opens a live microphone."
