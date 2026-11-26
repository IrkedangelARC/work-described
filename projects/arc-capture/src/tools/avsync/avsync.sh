#!/bin/zsh
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

# A/V sync check for ARC Capture's recorder, with nobody at the keyboard.
# Makes a clapper movie (white flash + 1 kHz click every 5 s), plays it in QuickTime on the second
# display, records the window through ScreenCaptureKit with Capture's exact stream configuration and its
# UNMODIFIED VideoRecorder.swift, then measures flash-vs-click in the delivered clip.
#
#   tools/avsync/avsync.sh [seconds]      default 26; use 130 to bound slow drift
#
# Written 2026-09-17 when a 280 s embedded movie captured on laptop-06 came out with its sound 0.7 s
# short of its picture. Positive offsets = audio LATE; a growing offset = a buffer is being lost.
set -e
cd "$(dirname "$0")/../.."
SECS="${1:-26}"; LEN=$((SECS + 20))
W=/private/tmp/arc-avsync; rm -rf "$W"; mkdir -p "$W"
FF=$(ls /opt/homebrew/bin/ffmpeg "/Applications/ARC Grab.app/Contents/MacOS/ffmpeg" 2>/dev/null | head -1)
"$FF" -v error -y -f lavfi -i "color=c=black:s=1920x1080:r=30:d=$LEN" -f lavfi -i "aevalsrc='if(lt(mod(t\,5)\,0.1)\,0.9*sin(2*PI*1000*t)\,0)':s=48000:c=stereo:d=$LEN" -filter_complex "[0:v]format=yuv420p,geq=lum='if(lt(mod(T\,5)\,0.1)\,235\,16)':cb=128:cr=128[v]" -map "[v]" -map 1:a -c:v libx264 -pix_fmt yuv420p -g 30 -preset ultrafast -c:a aac -b:a 192k -ar 48000 "$W/clapper.mp4"
cp ArcCapture/Engine/VideoRecorder.swift "$W/"; cp tools/avsync/harness.swift "$W/main.swift"
(cd "$W" && swiftc -O main.swift VideoRecorder.swift -framework AppKit -framework ScreenCaptureKit -framework AVFoundation -o avharness 2>&1 | grep -E "error:" || true)
osascript -e 'tell application "QuickTime Player" to quit' 2>/dev/null || true; sleep 1
open -a "QuickTime Player" "$W/clapper.mp4"; sleep 4
X=$(swift -e 'import AppKit; let s = NSScreen.screens; print(s.count > 1 ? Int(s[1].frame.origin.x) + 32 : 100)' 2>/dev/null || echo 100)
osascript -e "tell application \"QuickTime Player\"
  set bounds of front window to {$X, 120, $X + 960, 120 + 540}
  set audio volume of document 1 to 0.5
  play document 1
end tell" >/dev/null 2>&1; sleep 2
"$W/avharness" "$W/capture.mov" "$SECS" clapper 2>&1 | grep -E "AUDIO|VIDEO|recorder:|error"
osascript -e 'tell application "QuickTime Player" to quit' 2>/dev/null || true
python3 tools/avsync/measure.py "$W/capture.mov" "crop=iw*0.6:ih*0.6:iw*0.2:ih*0.3"
