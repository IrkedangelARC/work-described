#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""CLI interface for CueStack."""

import argparse
import sys
from pathlib import Path

from .models import Show
from .ingest import scan_folder, print_show_summary
from .render import render_show, check_dependencies


def main():
    parser = argparse.ArgumentParser(
        prog="cuestack",
        description="CueStack — Presentation Playlist Engine for Live AV",
    )
    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # --- ingest ---
    p_ingest = subparsers.add_parser(
        "ingest",
        help="Scan a folder of presentations and build a show file",
    )
    p_ingest.add_argument("source", help="Path to folder containing presentations")
    p_ingest.add_argument(
        "-o", "--output",
        help="Output show file path (default: <source>/show.json)",
    )

    # --- render ---
    p_render = subparsers.add_parser(
        "render",
        help="Render all presentations in a show to slide images",
    )
    p_render.add_argument("showfile", help="Path to show.json file")
    p_render.add_argument(
        "--force", action="store_true",
        help="Re-render all cues even if already rendered",
    )
    p_render.add_argument(
        "--cue", type=str,
        help="Render only a specific cue by ID",
    )

    # --- play ---
    p_play = subparsers.add_parser(
        "play",
        help="Launch the fullscreen player",
    )
    p_play.add_argument("showfile", help="Path to show.json file")
    p_play.add_argument(
        "--windowed", action="store_true",
        help="Start in windowed mode instead of fullscreen",
    )

    # --- status ---
    p_status = subparsers.add_parser(
        "status",
        help="Show status of a show file",
    )
    p_status.add_argument("showfile", help="Path to show.json file")

    # --- deps ---
    subparsers.add_parser(
        "deps",
        help="Check external dependencies",
    )

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    if args.command == "ingest":
        cmd_ingest(args)
    elif args.command == "render":
        cmd_render(args)
    elif args.command == "play":
        cmd_play(args)
    elif args.command == "status":
        cmd_status(args)
    elif args.command == "deps":
        cmd_deps()


def cmd_ingest(args):
    """Scan folder and create show file."""
    source = Path(args.source).resolve()
    print(f"Scanning: {source}")

    show = scan_folder(source)
    print_show_summary(show)

    output = args.output or str(source / "show.json")
    show.save(output)
    print(f"Show file saved: {output}")
    print(f"\nNext step: python main.py render {output}")


def cmd_render(args):
    """Render all cues to images."""
    show = Show.load(args.showfile)
    print(f"Rendering show: {show.name} ({len(show.cues)} cues)")

    if args.cue:
        # Render single cue
        from .render import render_cue
        cue = show.get_cue(args.cue)
        if not cue:
            print(f"Cue not found: {args.cue}")
            sys.exit(1)
        render_base = Path(show.render_base)
        render_base.mkdir(parents=True, exist_ok=True)
        render_cue(cue, render_base)
        print(f"Rendered: {cue.name} -> {cue.slide_count} slides")
    else:
        render_show(show, force=args.force)

    # Save updated show with render info
    show.save(args.showfile)
    rendered = sum(1 for c in show.cues if c.rendered)
    print(f"\nRendered: {rendered}/{len(show.cues)} cues, {show.total_slides} total slides")
    print(f"\nNext step: python main.py play {args.showfile}")


def cmd_play(args):
    """Launch the player."""
    show = Show.load(args.showfile)

    if not show.all_rendered:
        unrendered = [c.name for c in show.cues if not c.rendered]
        print(f"Warning: {len(unrendered)} cues not yet rendered:")
        for name in unrendered[:5]:
            print(f"  - {name}")
        print("Run 'render' first, or only rendered cues will be playable.\n")

    from .player import Player
    player = Player(show)
    if args.windowed:
        player._fullscreen = False
    player.run()


def cmd_status(args):
    """Print show status."""
    show = Show.load(args.showfile)
    print_show_summary(show)

    rendered = sum(1 for c in show.cues if c.rendered)
    print(f"Rendered: {rendered}/{len(show.cues)} cues")
    print(f"Total slides: {show.total_slides}")


def cmd_deps():
    """Check external dependencies."""
    deps = check_dependencies()
    print("CueStack Dependency Check:")
    print("-" * 40)
    for name, available in deps.items():
        status = "OK" if available else "MISSING"
        icon = "+" if available else "X"
        print(f"  [{icon}] {name}: {status}")

    if not all(deps.values()):
        print("\nInstall missing dependencies:")
        if not deps.get("libreoffice"):
            print("  brew install --cask libreoffice")
        if not deps.get("poppler"):
            print("  brew install poppler")
        print("  pip install -r requirements.txt")
