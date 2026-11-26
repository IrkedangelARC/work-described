"""Read-only snapshot of a Resolve timeline to JSON, and a structural diff of two snapshots.
Take one BEFORE and AFTER any scripted change; the diff is the proof of what changed. Never edits anything.

Usage:
  python3 tools/snapshot_timeline.py [--timeline NAME] [--out snapshots/FILE.json]
  python3 tools/snapshot_timeline.py --diff snapshots/a.json snapshots/b.json"""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

PROPS = ["Pan", "Tilt", "ZoomX", "ZoomY", "RotationAngle", "CropLeft", "CropRight", "CropTop", "CropBottom",
         "Opacity", "CompositeMode", "FlipX", "FlipY"]


def snapshot(tl) -> dict:
    T0 = tl.GetStartFrame()
    snap = {"timeline": tl.GetName(), "fps": tl.GetSetting("timelineFrameRate"), "start_tc": tl.GetStartTimecode(),
            "start_frame": T0, "end_frame": tl.GetEndFrame(), "tracks": {},
            "markers": {str(k): v for k, v in (tl.GetMarkers() or {}).items()}}
    for kind in ("video", "audio", "subtitle"):
        for t in range(1, tl.GetTrackCount(kind) + 1):
            items = []
            for it in tl.GetItemListInTrack(kind, t) or []:
                d = {"name": it.GetName(), "start": it.GetStart() - T0, "end": it.GetEnd() - T0, "dur": it.GetDuration()}
                if kind != "subtitle":
                    mpi = it.GetMediaPoolItem()
                    d.update({"left": it.GetLeftOffset(), "right": it.GetRightOffset(),
                              "path": mpi.GetClipProperty("File Path") if mpi else None,
                              "enabled": it.GetClipEnabled() if hasattr(it, "GetClipEnabled") else None})
                    if kind == "video":
                        d["props"] = {k: it.GetProperty(k) for k in PROPS}
                items.append(d)
            snap["tracks"][f"{kind[0].upper()}{t}"] = {"name": tl.GetTrackName(kind, t),
                                                       "enabled": tl.GetIsTrackEnabled(kind, t), "items": items}
    return snap


def compare(a, b, path=""):
    out = []
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b), key=str):
            if path == "" and k == "timeline":
                continue
            if k not in a or k not in b:
                out.append(f"{path}/{k}: only in {'second' if k not in a else 'first'}")
            else:
                out += compare(a[k], b[k], f"{path}/{k}")
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append(f"{path}: {len(a)} items vs {len(b)}")
        for i, (x, y) in enumerate(zip(a, b)):
            out += compare(x, y, f"{path}[{i}]")
    elif isinstance(a, float) or isinstance(b, float):
        try:
            if abs(float(a) - float(b)) > 1e-6:
                out.append(f"{path}: {a} -> {b}")
        except (TypeError, ValueError):
            out.append(f"{path}: {a} -> {b}")
    elif a != b and str(a) != str(b):
        out.append(f"{path}: {a} -> {b}")
    return out


ap = argparse.ArgumentParser()
ap.add_argument("--timeline")
ap.add_argument("--out")
ap.add_argument("--diff", nargs=2, metavar=("FIRST", "SECOND"))
a = ap.parse_args()

if a.diff:
    d = compare(*(json.loads(Path(f).read_text()) for f in a.diff))
    print("\n".join(d) if d else "NO DIFFERENCES")
    print(f"\n{len(d)} difference(s)")
    sys.exit(0)

from resolve_common import connect, find_timeline
_, p = connect()
tl = find_timeline(p, a.timeline)
s = snapshot(tl)
out = Path(a.out or f"snapshots/{time.strftime('%Y-%m-%d_%H%M%S')}_{tl.GetName().replace('/', '-')}.json")
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(s, indent=1))
n = sum(len(t["items"]) for t in s["tracks"].values())
print(f"{out}  ({len(s['tracks'])} tracks, {n} items, {len(s['markers'])} markers)")
