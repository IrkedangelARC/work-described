#!/bin/zsh
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

# Live check of the MUSIC module (process tap) over the control API, per
# docs/HANDOFF_2026-09-12_music.md. Plays a file in QuickTime Player, taps it,
# and MEASURES: meter moves, fader changes the peaks, mute silences, release
# gives QuickTime its audio back. Run with ARC Presenter 2.7.0+ running from
# /Applications (tools/install_studio.sh --launch). First run asks once for
# System Audio Recording; click Allow, then run again.
#
#   tools/music_check.sh [/path/to/audio-or-video]
#
set -u
API=localhost:8760
FILE="${1:-}"
if [[ -z "$FILE" ]]; then
  FILE=$(ls ~/Music/*.{mp3,m4a,wav,aiff}(N) ~/Desktop/*.{mp3,m4a,mp4,mov}(N) 2>/dev/null | head -1)
fi
[[ -f "$FILE" ]] || { echo "need a media file: tools/music_check.sh /path/file.mp3"; exit 2 }

peaks() { curl -s "$API/music" | python3 -c 'import sys,json; d=json.load(sys.stdin); p=d["peaks"]; print(p[0], p[1], "running=%s level=%s muted=%s status=%s" % (d["running"], d["level"], d["muted"], d["status"]))'; }
maxpeak() {  # highest L peak (dB) over N samples, "null" if silent throughout
  local n=$1 best=null
  for i in $(seq 1 $n); do
    local p=$(curl -s "$API/music" | python3 -c 'import sys,json; p=json.load(sys.stdin)["peaks"][0]; print("null" if p is None else p)')
    if [[ "$p" != null ]]; then
      if [[ "$best" == null ]] || (( $(echo "$p > $best" | bc -l) )); then best=$p; fi
    fi
    sleep 0.2
  done
  echo $best
}

curl -sf "$API/state" >/dev/null || { echo "ARC Presenter control API not answering on $API"; exit 2 }
ver=$(defaults read "/Applications/ARC Presenter.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
echo "Presenter $ver at $API, file: $FILE"

echo "-- QuickTime Player: open + loop + play"
osascript >/dev/null <<EOF
tell application "QuickTime Player"
  activate
  set d to open POSIX file "$FILE"
  set looping of d to true
  set audio volume of d to 1
  play d
end tell
EOF
sleep 1.5

echo "-- sources seen by the module:"
curl -s "$API/music" | python3 -c 'import sys,json; [print("   ", ("▶ " if s["playing"] else "  ")+s["name"], s["bundle"]) for s in json.load(sys.stdin)["sources"]]'

echo "-- tap QuickTime Player, level 0 dB"
curl -s -XPOST "$API/music/source?name=QuickTime+Player" >/dev/null; sleep 0.8; curl -s "$API/music" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("    running=%s status=%s" % (d["running"], d["status"]))'
curl -s -XPOST "$API/music/mute?on=0" >/dev/null
curl -s -XPOST "$API/music/level?db=0" >/dev/null
sleep 1
full=$(maxpeak 10)
echo "   peak at 0 dB:   $full   (expect a number; null = no audio reaching the tap)"

echo "-- fader to -20 dB"
curl -s -XPOST "$API/music/level?db=-20" >/dev/null
sleep 0.5
low=$(maxpeak 10)
echo "   peak at -20 dB: $low   (expect ~20 dB below the first)"

echo "-- mute (meter release is ~52 dB/s, so sample after it has fallen)"
curl -s -XPOST "$API/music/mute?on=1" >/dev/null
sleep 2
mute=$(maxpeak 5)
echo "   peak muted:     $mute   (expect null or below -60)"

echo "-- walk in / walk out (fade $(curl -s $API/music | python3 -c 'import sys,json; print(json.load(sys.stdin)["fadeSeconds"])') s)"
curl -s -XPOST "$API/music/fadein" >/dev/null; sleep 1; echo "   mid walk-in:  $(peaks)"
curl -s -XPOST "$API/music/fadeout" >/dev/null; sleep 4; echo "   after walk-out: $(peaks)"

echo "-- release the tap (QuickTime should be audible again on its own)"
curl -s -XPOST "$API/music/source?name=none" >/dev/null
sleep 1; peaks

verdict=PASS
[[ "$full" == null ]] && verdict="FAIL: no signal through the tap"
[[ "$mute" != null ]] && (( $(echo "$mute > -60" | bc -l) )) && verdict="FAIL: mute leaked ($mute dB)"
if [[ "$full" != null && "$low" != null ]]; then
  drop=$(echo "$full - $low" | bc -l)
  (( $(echo "$drop < 15 || $drop > 25" | bc -l) )) && verdict="FAIL: -20 dB fader moved the peak by $drop dB"
fi
echo "== $verdict"
osascript -e 'tell application "QuickTime Player" to quit' >/dev/null 2>&1
