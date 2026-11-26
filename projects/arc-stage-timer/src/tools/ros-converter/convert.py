#!/usr/bin/env python3
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""
ARC ROS Converter — Convert agenda documents to ROS JSON for ARC Stage Timer.

Usage:
    python convert.py agenda.pdf                          # → agenda_ros.json
    python convert.py schedule.xlsx -o ~/Desktop          # → ~/Desktop/schedule_ros.json
    python convert.py program.pdf --ai                    # Force AI parsing
    python convert.py agenda.txt --dry-run                # Preview to stdout
    python convert.py agenda.pdf --event-name "Summit"    # Set event name
    python convert.py *.pdf                               # Batch convert
"""

import argparse
import sys
from pathlib import Path

# Add parent to path so parsers can import schema
sys.path.insert(0, str(Path(__file__).parent))

from schema import ROSDocument


def main():
    parser = argparse.ArgumentParser(
        description="Convert agenda documents to ARC ROS JSON",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("files", nargs="+", help="Input file(s): .pdf, .xlsx, .xls, .txt, .md")
    parser.add_argument("-o", "--output", help="Output directory (default: same as input)")
    parser.add_argument("--ai", action="store_true", help="Force AI parsing via Claude API")
    parser.add_argument("--dry-run", action="store_true", help="Preview JSON to stdout without writing")
    parser.add_argument("--event-name", help="Override event name in output")
    parser.add_argument("--date", help="Event date (YYYY-MM-DD)")
    parser.add_argument("--model", default="claude-sonnet-4-20250514", help="Claude model for --ai mode")
    args = parser.parse_args()

    for file_arg in args.files:
        path = Path(file_arg)
        if not path.exists():
            print(f"ERROR: File not found: {path}", file=sys.stderr)
            continue

        print(f"Processing: {path.name}", file=sys.stderr)
        doc = convert_file(path, args)

        if doc is None:
            print(f"  No sessions found in {path.name}", file=sys.stderr)
            continue

        # Apply overrides
        if args.event_name:
            doc = ROSDocument(
                event_name=args.event_name,
                arc_number=doc.arc_number,
                event_date=args.date or doc.event_date,
                venue=doc.venue,
                sessions=doc.sessions,
                notes=doc.notes,
            )
        elif args.date:
            doc = ROSDocument(
                event_name=doc.event_name,
                arc_number=doc.arc_number,
                event_date=args.date,
                venue=doc.venue,
                sessions=doc.sessions,
                notes=doc.notes,
            )

        json_str = doc.to_json()
        session_count = len(doc.sessions)

        if args.dry_run:
            print(json_str)
            print(f"\n  ({session_count} sessions found)", file=sys.stderr)
        else:
            out_dir = Path(args.output) if args.output else path.parent
            out_dir.mkdir(parents=True, exist_ok=True)
            out_path = out_dir / f"{path.stem}_ros.json"
            out_path.write_text(json_str, encoding="utf-8")
            print(f"  Wrote {out_path} ({session_count} sessions)", file=sys.stderr)


def convert_file(path: Path, args) -> ROSDocument | None:
    """Select parser by extension and convert."""
    suffix = path.suffix.lower()

    # Force AI if requested
    if args.ai:
        from parsers.ai_parser import parse_with_ai
        return parse_with_ai(str(path), event_name=args.event_name, model=args.model)

    # Structured parsers first
    if suffix == ".pdf":
        from parsers.pdf_parser import parse_pdf
        doc = parse_pdf(str(path), event_name=args.event_name)
        if doc:
            return doc
        # Fall back to AI if structured parsing found nothing
        print("  Structured parsing found no sessions, trying AI...", file=sys.stderr)
        try:
            from parsers.ai_parser import parse_with_ai
            return parse_with_ai(str(path), event_name=args.event_name, model=args.model)
        except (ImportError, RuntimeError) as e:
            print(f"  AI fallback unavailable: {e}", file=sys.stderr)
            return None

    elif suffix in (".xlsx", ".xls"):
        from parsers.excel_parser import parse_excel
        return parse_excel(str(path), event_name=args.event_name)

    elif suffix in (".txt", ".md", ".csv", ".tsv"):
        from parsers.text_parser import parse_text
        text = path.read_text(encoding="utf-8", errors="replace")
        return parse_text(text, event_name=args.event_name)

    else:
        print(f"  Unsupported format: {suffix}. Trying as text...", file=sys.stderr)
        from parsers.text_parser import parse_text
        text = path.read_text(encoding="utf-8", errors="replace")
        return parse_text(text, event_name=args.event_name)


if __name__ == "__main__":
    main()
