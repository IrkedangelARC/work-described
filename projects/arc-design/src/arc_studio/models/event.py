#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Event data model — parsed from arc-events registry."""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class Speaker:
    name: str
    title: str = ""
    organization: str = ""


@dataclass
class Session:
    name: str
    start_time: str = ""
    end_time: str = ""
    speakers: list[Speaker] = field(default_factory=list)


@dataclass
class EventData:
    arc_number: str                    # "JOB-0000"
    event_title: str
    event_date: str                    # "2026-01-24"
    client_name: str = ""
    organization: str = ""
    venue: str = ""
    event_type: str = ""               # corporate, conference, hybrid, etc.
    sessions: list[Session] = field(default_factory=list)
    speakers: list[Speaker] = field(default_factory=list)
    notes: str = ""
    event_end_date: str | None = None  # Multi-day events
    is_multi_day: bool = False

    @property
    def display_date(self) -> str:
        if self.is_multi_day and self.event_end_date:
            return f"{self.event_date} — {self.event_end_date}"
        return self.event_date

    @property
    def speaker_names(self) -> list[str]:
        seen = set()
        names = []
        for s in self.speakers:
            if s.name not in seen:
                seen.add(s.name)
                names.append(s.name)
        for session in self.sessions:
            for s in session.speakers:
                if s.name not in seen:
                    seen.add(s.name)
                    names.append(s.name)
        return names
