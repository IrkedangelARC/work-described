"""Place timeline markers from a CSV. Dry run by default; --go writes them.
Markers it creates carry customData "arc-kit"; re-running first removes ONLY those, so the editor's own markers
(QC notes, audio dropouts) are never touched.

CSV columns (header row required): at,color,name,note,duration
  at        elapsed seconds from the timeline start (e.g. 754.2) OR timecode HH:MM:SS:FF as shown in Resolve
  color     Blue Cyan Green Yellow Red Pink Purple Fuchsia Rose Lavender Sky Mint Lemon Sand Cocoa Cream
  duration  seconds (optional, default one frame). A duration marker named "Clip 01.mp4" doubles as a render range.

Usage: python3 tools/add_markers.py markers.csv [--timeline NAME] [--go]"""
import argparse
import csv
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from resolve_common import CLAUDE_TAG, connect, die, find_timeline, fps, seconds_to_frames, tc_to_frames

COLORS = {"Blue", "Cyan", "Green", "Yellow", "Red", "Pink", "Purple", "Fuchsia", "Rose", "Lavender", "Sky", "Mint",
          "Lemon", "Sand", "Cocoa", "Cream"}

ap = argparse.ArgumentParser()
ap.add_argument("csv")
ap.add_argument("--timeline")
ap.add_argument("--go", action="store_true")
a = ap.parse_args()

_, p = connect()
tl = find_timeline(p, a.timeline)
rate = fps(tl)
start_tc_frames = tc_to_frames(tl.GetStartTimecode(), rate)
rows = []
for n, r in enumerate(csv.DictReader(open(a.csv, newline="")), start=2):
    at = r["at"].strip()
    if ":" in at:  # Resolve's displayed TC; a TC below the timeline start (00:12:34:00 on a 01:00:00:00 timeline) is relative
        f = tc_to_frames(at, rate)
        f = f - start_tc_frames if f >= start_tc_frames else f
    else:
        f = seconds_to_frames(float(at), rate)
    color = (r.get("color") or "Blue").strip().capitalize()
    if color not in COLORS:
        die(f"line {n}: colour {color!r} not one of {sorted(COLORS)}")
    dur = max(1, seconds_to_frames(float(r["duration"]), rate)) if (r.get("duration") or "").strip() else 1
    if not 0 <= f < tl.GetEndFrame() - tl.GetStartFrame():
        die(f"line {n}: {at} is outside the timeline")
    rows.append((f, color, r.get("name", "").strip(), r.get("note", "").strip(), dur))

existing = {int(k): v for k, v in (tl.GetMarkers() or {}).items()}
ours = [k for k, v in existing.items() if v.get("customData") == CLAUDE_TAG]
clash = [f for f, *_ in rows if f in existing and f not in ours]
print(f"timeline {tl.GetName()!r} @ {rate} fps: {len(rows)} marker(s) to place, {len(ours)} earlier kit marker(s) to replace")
for f, c, nm, note, d in rows:
    print(f"  frame {f:>7}  {f / rate:9.2f} s  {c:<8} {d:>5} f  {nm}" + ("   (SKIP: editor's marker here)" if f in clash else ""))
if not a.go:
    print("\nDRY RUN. Add --go to write.")
    sys.exit(0)

tl.DeleteMarkerByCustomData(CLAUDE_TAG)
for k in ours:  # DeleteMarkerByCustomData removes one per call in some builds
    if k in (tl.GetMarkers() or {}):
        tl.DeleteMarkerAtFrame(k)
placed = sum(bool(tl.AddMarker(f, c, nm, note, d, CLAUDE_TAG)) for f, c, nm, note, d in rows if f not in clash)
print(f"placed {placed}/{len(rows) - len(clash)}")
