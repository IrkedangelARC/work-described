#!/bin/zsh
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

# Build a test show, open it on the extended displays and photograph every window, with nobody at the
# keyboard (2026-09-17: "give yourself the ability to make a test show, open it on the extended
# monitors and review your work all by yourself").
#
#   tools/review.sh [name]        -> /private/tmp/arc-stage-review/*.png
#   EXTENDED=1 MODE=operate tools/review.sh   -> the OPERATE widget instead of the console
# The primary display is never used: the control window goes to display 2 and the stage output to display 3.
set -e
cd "$(dirname "$0")/.."
APP="${APP:-build/dd/Build/Products/Release/ARC Stage Timer.app}"
NAME="${1:-ARC Style Review}"
OUT=/private/tmp/arc-stage-review
rm -rf "$OUT"; mkdir -p "$OUT"
[ -d "$APP" ] || { echo "no build at $APP"; exit 1; }

pkill -f "ARC Stage Timer.app/Contents/MacOS" 2>/dev/null || true
sleep 2
# A copy outside the build folder, so a rebuild during a review does not swap the binary underfoot.
RUN="/private/tmp/arcinstall/ARC Stage Timer.app"
rm -rf "$RUN"; mkdir -p "$(dirname "$RUN")"; ditto "$APP" "$RUN"
open -n "$RUN" --args --off-primary --test-show "$NAME" ${EXTENDED:+--extended}
sleep 14
# A headless or freshly built show has no routes, so the stage output is opened on purpose.
curl -s -m 5 -X POST "http://localhost:8080/api/window/open?window=stage" >/dev/null 2>&1 || true
sleep 4
curl -s -m 5 -X POST "http://localhost:8080/api/place?window=stage&display=3" >/dev/null 2>&1 || true
sleep 3
# MODE=operate: the floating widget instead of the console window.
if [ "${MODE:-program}" = operate ]; then
  curl -s -m 5 -X POST "http://localhost:8080/api/console?mode=operate" >/dev/null 2>&1 || true
  sleep 3
fi

echo "== what the app says"
curl -s -m 5 "http://localhost:8080/api/shows" | python3 -m json.tool 2>/dev/null | head -12
curl -s -m 5 "http://localhost:8080/api/displays" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for r in d["displays"]: print("  display", r["index"], r["name"].ljust(10), "(PRIMARY)" if r["main"] else "         ", "->", r["windows"] or "nothing")' 2>/dev/null

echo "== windows"
python3 - "$OUT" <<'PY'
import subprocess, sys, json, re
out = sys.argv[1]
src = '''
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerName"] as? String)?.contains("Stage Timer") == true {
    let b = w["kCGWindowBounds"] as? [String: Any] ?? [:]
    print("\\(w["kCGWindowNumber"] ?? 0)\\t\\(w["kCGWindowName"] ?? "")\\t\\(Int((b["Width"] as? Double) ?? 0))\\t\\(Int((b["Height"] as? Double) ?? 0))\\t\\(Int((b["X"] as? Double) ?? 0))")
}
'''
open("/private/tmp/_w.swift","w").write(src)
rows = subprocess.run(["swift","/private/tmp/_w.swift"], capture_output=True, text=True).stdout.strip().splitlines()
for r in rows:
    wid, title, w, h, x = (r.split("\t") + ["","","",""])[:5]
    if int(w or 0) < 400: continue
    disp = "1-primary" if int(x) < 2048 else ("2-ALOLG" if int(x) >= 3968 else "3-NonPnP")
    name = (title or "control").replace(" ", "_").replace("/", "-")
    png = f"{out}/{disp}_{name}.png"
    subprocess.run(["screencapture","-x","-o","-l",wid,png])
    subprocess.run(["sips","-Z","1600",png,"--out",png.replace(".png","_s.png")], capture_output=True)
    print(f"  {title or 'control'}  {w}x{h}  on display {disp}  -> {png}")
PY
echo "== screenshots in $OUT"
