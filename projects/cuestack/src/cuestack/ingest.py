#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Scan a folder of presentations and build a show cue list."""
from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path

from .models import Cue, Show, SUPPORTED_FORMATS


def natural_sort_key(path: Path) -> tuple:
    """Sort files naturally: '1.2 Foo' before '1.10 Bar'."""
    name = path.stem
    parts = re.split(r"(\d+\.?\d*)", name)
    result = []
    for part in parts:
        try:
            result.append(float(part))
        except ValueError:
            result.append(part.lower())
    return tuple(result)


def scan_folder(source_dir: str | Path) -> Show:
    """
    Scan a folder tree for presentation files and build a Show.

    Expects a structure like:
        source_dir/
            HoldSlide.pptx
            Lightning Talks/
                1.1 Speaker.pptx
                1.2 Speaker.pptx
            Session 3/
                3.1 Speaker.pptx
            loose_file.pdf

    Files are ordered by:
    1. Top-level files first (hold slides, etc.)
    2. Subdirectories in sorted order
    3. Within each directory, files sorted naturally by filename
    """
    source_dir = Path(source_dir).resolve()
    if not source_dir.is_dir():
        raise FileNotFoundError(f"Source directory not found: {source_dir}")

    show = Show(
        name=source_dir.name,
        created=datetime.now().isoformat(),
        source_dir=str(source_dir),
        render_base=str(source_dir / ".rendered"),
    )

    # Collect files grouped by their parent directory
    top_level_files: list[Path] = []
    subdirs: dict[Path, list[Path]] = {}

    for item in sorted(source_dir.iterdir()):
        if item.name.startswith(".") or item.name.startswith("~$"):
            continue
        if "comb" in item.stem.lower():
            continue  # skip manually stitched combo decks

        if item.is_file() and item.suffix.lower() in SUPPORTED_FORMATS:
            top_level_files.append(item)
        elif item.is_dir():
            sub_files = []
            for f in item.rglob("*"):
                if (
                    f.is_file()
                    and f.suffix.lower() in SUPPORTED_FORMATS
                    and not f.name.startswith("~$")
                    and not f.name.startswith(".")
                ):
                    sub_files.append(f)
            if sub_files:
                subdirs[item] = sorted(sub_files, key=natural_sort_key)

    # Build cue list
    order = 0

    # Top-level files first
    for f in sorted(top_level_files, key=natural_sort_key):
        cue = _file_to_cue(f, session="Main", order=order)
        show.cues.append(cue)
        order += 1

    # Then subdirectories
    for subdir in sorted(subdirs.keys()):
        session_name = subdir.name
        for f in subdirs[subdir]:
            cue = _file_to_cue(f, session=session_name, order=order)
            show.cues.append(cue)
            order += 1

    return show


def _file_to_cue(filepath: Path, session: str, order: int) -> Cue:
    """Create a Cue from a presentation file."""
    name = filepath.stem
    # Try to extract presenter name from common patterns like "1.2 Name - Title"
    # or "Name_Title_Conference"
    clean_name = re.sub(r"^\d+\.?\d*\s*", "", name)  # strip leading numbers
    clean_name = clean_name.strip(" -_")

    return Cue(
        name=clean_name or name,
        source_path=str(filepath),
        format=filepath.suffix.lower(),
        session=session,
        order=order,
        render_dir="",  # set during render phase
    )


def print_show_summary(show: Show):
    """Print a formatted summary of the show."""
    print(f"\n{'='*60}")
    print(f"  SHOW: {show.name}")
    print(f"  Cues: {len(show.cues)}")
    print(f"  Source: {show.source_dir}")
    print(f"{'='*60}\n")

    current_session = None
    for cue in show.cues:
        if cue.session != current_session:
            current_session = cue.session
            print(f"  [{current_session}]")
        status = "rendered" if cue.rendered else "pending"
        slides = f"{cue.slide_count} slides" if cue.rendered else cue.format
        print(f"    {cue.order:3d}. {cue.name[:45]:<45} [{slides}] ({status})")

    print()
