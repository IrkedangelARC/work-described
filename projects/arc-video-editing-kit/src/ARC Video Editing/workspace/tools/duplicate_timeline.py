"""Duplicate a timeline so scripted work never lands on the editor's original. Adds; never deletes.

Usage: python3 tools/duplicate_timeline.py [--timeline NAME] [--name NEW_NAME]
Default new name: "<NAME> CLAUDE <YYYY-MM-DD HHMM>". The duplicate becomes the current timeline."""
import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from resolve_common import connect, die, find_timeline

ap = argparse.ArgumentParser()
ap.add_argument("--timeline")
ap.add_argument("--name")
a = ap.parse_args()

_, p = connect()
src = find_timeline(p, a.timeline)
name = a.name or f"{src.GetName()} CLAUDE {time.strftime('%Y-%m-%d %H%M')}"
p.SetCurrentTimeline(src)
dup = src.DuplicateTimeline(name)
if dup is None:
    die(f"Resolve refused to duplicate {src.GetName()!r} as {name!r} (name already used?)")
p.SetCurrentTimeline(dup)
print(f"duplicated {src.GetName()!r} -> {dup.GetName()!r} (now current)")
