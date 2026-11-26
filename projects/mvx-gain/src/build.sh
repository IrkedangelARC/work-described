#!/bin/bash
# MVX Gain build.
#   ./build.sh              compile + Developer ID sign (hardened runtime)
#   ./build.sh --notarize   also notarize + staple, and stage dist/MVX-Gain-<ver>.zip
# Falls back to ad-hoc signing when no Developer ID identity is present.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/MVXGain.app
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)

rm -rf build && mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 5 -parse-as-library -O main.swift \
  -o "$APP/Contents/MacOS/MVXGain" -target arm64-apple-macos13
cp Info.plist "$APP/Contents/"

if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --entitlements MVXGain.entitlements --sign "$IDENTITY" "$APP"
else
  echo "no Developer ID identity: ad-hoc signing (first launch needs right-click > Open)"
  codesign --force --entitlements MVXGain.entitlements --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($VER)"

if [[ "${1:-}" == "--notarize" ]]; then
  [[ -n "$IDENTITY" ]] || { echo "notarize needs a Developer ID identity" >&2; exit 1; }
  mkdir -p dist
  ditto -c -k --norsrc --keepParent "$APP" build/notarize.zip
  xcrun notarytool submit build/notarize.zip --keychain-profile ARC-Notarize --wait
  xcrun stapler staple "$APP"
  spctl -a -vv "$APP"
  ZIP="dist/MVX-Gain-$VER.zip"
  rm -f "$ZIP"
  ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
  echo "ZIP $ZIP"
fi
