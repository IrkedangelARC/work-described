#!/bin/zsh
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

# Copy the yt-dlp onedir from engine/ into an app bundle at Contents/Resources/yt-dlp
# and restore the Python.framework symlink layout (the release zip flattens
# Versions/Current and the top-level Python/Resources into copies, which
# codesign rejects as "bundle format is ambiguous").
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:?path to .app}"
[[ -x engine/yt-dlp/yt-dlp_macos ]] || { echo "engine/yt-dlp missing: run tools/build_engine.sh" >&2; exit 1; }
DST="$APP/Contents/Resources/yt-dlp"
rm -rf "$DST"
mkdir -p "$APP/Contents/Resources"
ditto engine/yt-dlp "$DST"
find "$DST" -type d -name "*.framework" | while read -r fw; do
  ver=$(ls "$fw/Versions" | grep -v Current | head -1)
  [[ -n "$ver" ]] || continue
  rm -rf "$fw/Versions/Current" "$fw/Python" "$fw/Resources" "$fw/$(basename "$fw" .framework)"
  ln -s "$ver" "$fw/Versions/Current"
  ln -s "Versions/Current/$(basename "$fw" .framework)" "$fw/$(basename "$fw" .framework)"
  [[ -d "$fw/Versions/$ver/Resources" ]] && ln -s "Versions/Current/Resources" "$fw/Resources"
done
