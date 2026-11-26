#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Excel parser using openpyxl — row-based extraction."""

import re
from datetime import datetime, time
from typing import Optional

from schema import ROSDocument, ROSSession


def parse_excel(path: str, event_name: Optional[str] = None) -> Optional[ROSDocument]:
    """Extract agenda from Excel. Detects time/title columns automatically."""
    try:
        import openpyxl
    except ImportError:
        raise ImportError("openpyxl is required for Excel parsing: pip install openpyxl")

    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    ws = wb.active

    rows = list(ws.iter_rows(values_only=True))
    if not rows:
        return None

    # Detect column layout from header row or first data row
    time_col, title_col, duration_col, speaker_col = _detect_columns(rows)

    if title_col is None:
        return None

    sessions = []
    for row in rows[1:] if _is_header(rows[0]) else rows:
        if not row or all(cell is None for cell in row):
            continue

        title = _cell_str(row, title_col)
        if not title:
            continue

        time_range = None
        duration_minutes = None

        if time_col is not None:
            time_val = row[time_col] if time_col < len(row) else None
            time_range = _format_time(time_val)

        if duration_col is not None:
            dur_val = row[duration_col] if duration_col < len(row) else None
            duration_minutes = _parse_duration(dur_val)

        speakers = _cell_str(row, speaker_col) if speaker_col is not None else None

        sessions.append(ROSSession(
            session_title=title,
            time_range=time_range,
            duration_minutes=duration_minutes,
            speakers=speakers,
            format=_infer_format(title),
        ))

    wb.close()

    if not sessions:
        return None
    return ROSDocument(event_name=event_name, sessions=sessions)


def _detect_columns(rows: list) -> tuple:
    """Heuristic column detection. Returns (time_col, title_col, duration_col, speaker_col)."""
    header = rows[0] if rows else []
    time_col = title_col = duration_col = speaker_col = None

    for i, cell in enumerate(header):
        if cell is None:
            continue
        val = str(cell).lower().strip()
        if any(k in val for k in ("time", "start", "schedule")):
            time_col = i
        elif any(k in val for k in ("title", "session", "topic", "description", "agenda")):
            title_col = i
        elif any(k in val for k in ("duration", "length", "min")):
            duration_col = i
        elif any(k in val for k in ("speaker", "presenter", "facilitator")):
            speaker_col = i

    # If no header detected, guess from data: widest text column = title
    if title_col is None and len(rows) > 1:
        max_len = 0
        for i, cell in enumerate(rows[1]):
            if cell and len(str(cell)) > max_len:
                max_len = len(str(cell))
                title_col = i

    return time_col, title_col, duration_col, speaker_col


def _is_header(row) -> bool:
    """Check if row looks like a header (all strings, no times)."""
    if not row:
        return False
    for cell in row:
        if cell is None:
            continue
        if isinstance(cell, (datetime, time)):
            return False
        val = str(cell).lower()
        if any(k in val for k in ("time", "title", "session", "speaker", "duration")):
            return True
    return False


def _cell_str(row, col: Optional[int]) -> Optional[str]:
    if col is None or col >= len(row) or row[col] is None:
        return None
    return str(row[col]).strip() or None


def _format_time(val) -> Optional[str]:
    if val is None:
        return None
    if isinstance(val, time):
        return val.strftime("%-I:%M %p")
    if isinstance(val, datetime):
        return val.strftime("%-I:%M %p")
    s = str(val).strip()
    return s if s else None


def _parse_duration(val) -> Optional[int]:
    if val is None:
        return None
    if isinstance(val, (int, float)):
        return int(val)
    m = re.search(r"(\d+)", str(val))
    return int(m.group(1)) if m else None


_FORMAT_KEYWORDS = {
    "keynote": "keynote", "fireside": "fireside", "panel": "panel",
    "lightning": "lightning", "remarks": "remarks", "break": "break",
    "coffee": "break", "lunch": "break", "networking": "social",
    "reception": "social", "transition": "transition",
}


def _infer_format(title: str) -> Optional[str]:
    lower = title.lower()
    for kw, fmt in _FORMAT_KEYWORDS.items():
        if kw in lower:
            return fmt
    return None
