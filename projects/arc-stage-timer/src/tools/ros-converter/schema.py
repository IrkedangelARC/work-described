#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""ROS JSON schema dataclasses matching the ARC Stage Timer import format."""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from typing import Optional


@dataclass
class ROSSession:
    session_title: str
    time_range: Optional[str] = None
    subtitle: Optional[str] = None
    speakers: Optional[str] = None
    format: Optional[str] = None
    duration_minutes: Optional[int] = None
    mic_count: Optional[int] = None
    notes: Optional[str] = None
    is_break: Optional[bool] = None
    is_transition: Optional[bool] = None


@dataclass
class ROSDocument:
    event_name: Optional[str] = None
    arc_number: Optional[str] = None
    event_date: Optional[str] = None
    venue: Optional[str] = None
    sessions: list[ROSSession] = field(default_factory=list)
    notes: Optional[str] = None

    def to_json(self, indent: int = 2) -> str:
        """Serialize to JSON, stripping None values for clean output."""
        return json.dumps(_strip_none(asdict(self)), indent=indent, ensure_ascii=False)


def _strip_none(d):
    """Recursively remove keys with None values from dicts."""
    if isinstance(d, dict):
        return {k: _strip_none(v) for k, v in d.items() if v is not None}
    if isinstance(d, list):
        return [_strip_none(i) for i in d]
    return d
