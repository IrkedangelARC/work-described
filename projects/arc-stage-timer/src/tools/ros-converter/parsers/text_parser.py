#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Pure-stdlib text parser for agenda documents.

Same regex cascade as the Swift AgendaTextParser — most specific first.
"""

import re
from typing import Optional

from schema import ROSDocument, ROSSession

# Compiled patterns (most specific → least)
_FULL_RANGE = re.compile(
    r"^(\d{1,2}:\d{2}\s*[AaPp][Mm])\s*[-–—]\s*(\d{1,2}:\d{2}\s*[AaPp][Mm])\s+(.+)$"
)
_BARE_RANGE = re.compile(
    r"^(\d{1,2}:\d{2})\s*[-–—]\s*(\d{1,2}:\d{2})\s+(.+)$"
)
_SINGLE_TIME = re.compile(
    r"^(\d{1,2}:\d{2}\s*(?:[AaPp][Mm])?)\s*[|—–:]\s+(.+)$"
)
_BULLET_TIME = re.compile(
    r"^[*\-•]\s+(\d{1,2}:\d{2}\s*(?:[AaPp][Mm])?)\s+(.+)$"
)
_DURATION_HINT = re.compile(
    r"^(.+?)\s*[\(\[]\s*(\d+)\s*(?:min(?:utes?)?|m)\s*[\)\]]"
)


def parse_text(text: str, event_name: Optional[str] = None) -> Optional[ROSDocument]:
    """Parse raw agenda text into a ROSDocument. Returns None if no sessions found."""
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    sessions = []
    for line in lines:
        session = _parse_line(line)
        if session:
            sessions.append(session)
    if not sessions:
        return None
    return ROSDocument(event_name=event_name, sessions=sessions)


def _parse_line(line: str) -> Optional[ROSSession]:
    for parser in (_full_range, _bare_range, _single_time, _bullet_time, _duration_hint):
        result = parser(line)
        if result:
            return result
    return None


def _full_range(line: str) -> Optional[ROSSession]:
    m = _FULL_RANGE.match(line)
    if not m:
        return None
    start, end, title = m.group(1).strip(), m.group(2).strip(), m.group(3).strip()
    time_range = f"{_normalize_time(start)} - {_normalize_time(end)}"
    duration = _duration_from_range(start, end)
    return ROSSession(
        session_title=_clean_title(title),
        time_range=time_range,
        format=_infer_format(title),
        duration_minutes=duration // 60 if duration else None,
    )


def _bare_range(line: str) -> Optional[ROSSession]:
    m = _BARE_RANGE.match(line)
    if not m:
        return None
    start, end, title = m.group(1), m.group(2), m.group(3).strip()
    time_range = f"{start} - {end}"
    duration = _duration_from_range(start, end)
    return ROSSession(
        session_title=_clean_title(title),
        time_range=time_range,
        format=_infer_format(title),
        duration_minutes=duration // 60 if duration else None,
    )


def _single_time(line: str) -> Optional[ROSSession]:
    m = _SINGLE_TIME.match(line)
    if not m:
        return None
    time_str = _normalize_time(m.group(1).strip())
    title = m.group(2).strip()
    return ROSSession(
        session_title=_clean_title(title),
        time_range=time_str,
        format=_infer_format(title),
    )


def _bullet_time(line: str) -> Optional[ROSSession]:
    m = _BULLET_TIME.match(line)
    if not m:
        return None
    time_str = _normalize_time(m.group(1).strip())
    title = m.group(2).strip()
    return ROSSession(
        session_title=_clean_title(title),
        time_range=time_str,
        format=_infer_format(title),
    )


def _duration_hint(line: str) -> Optional[ROSSession]:
    m = _DURATION_HINT.match(line)
    if not m:
        return None
    title = m.group(1).strip()
    mins = int(m.group(2))
    return ROSSession(
        session_title=_clean_title(title),
        format=_infer_format(title),
        duration_minutes=mins,
    )


# --- Helpers ---

def _normalize_time(s: str) -> str:
    """Normalize '9:00am' → '9:00 AM'."""
    m = re.match(r"^(\d{1,2}:\d{2})\s*([AaPp][Mm])$", s)
    if m:
        return f"{m.group(1)} {m.group(2).upper()}"
    return s


def _duration_from_range(start: str, end: str) -> Optional[int]:
    """Compute duration in seconds between two time strings."""
    from datetime import datetime

    start_n = _normalize_time(start)
    end_n = _normalize_time(end)
    for fmt in ("%I:%M %p", "%H:%M"):
        try:
            s = datetime.strptime(start_n, fmt)
            e = datetime.strptime(end_n, fmt)
            diff = (e - s).total_seconds()
            if diff > 0:
                return int(diff)
        except ValueError:
            continue
    return None


_FORMAT_KEYWORDS = {
    "keynote": "keynote",
    "fireside": "fireside",
    "panel": "panel",
    "lightning": "lightning",
    "remarks": "remarks",
    "welcome": "remarks",
    "opening": "remarks",
    "closing": "remarks",
    "break": "break",
    "coffee": "break",
    "lunch": "break",
    "refreshment": "break",
    "networking": "social",
    "reception": "social",
    "social": "social",
    "happy hour": "social",
    "transition": "transition",
    "setup": "transition",
    "changeover": "transition",
    "green room": "greenRoom",
    "greenroom": "greenRoom",
}


def _infer_format(title: str) -> Optional[str]:
    lower = title.lower()
    for keyword, fmt in _FORMAT_KEYWORDS.items():
        if keyword in lower:
            return fmt
    return None


def _clean_title(title: str) -> str:
    title = re.sub(r"^\d+[.)]\s*", "", title)
    title = re.sub(r"^[*\-•]\s*", "", title)
    return title.strip()
