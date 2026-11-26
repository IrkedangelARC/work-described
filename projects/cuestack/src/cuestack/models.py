#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Data models for CueStack shows."""
from __future__ import annotations

import json
import uuid
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Optional


SUPPORTED_FORMATS = {".pptx", ".ppt", ".pdf", ".key", ".odp"}


@dataclass
class Slide:
    """A single rendered slide image."""
    index: int
    image_path: str  # path to rendered PNG
    width: int = 1920
    height: int = 1080


@dataclass
class Cue:
    """A single presentation in the show playlist."""
    id: str = field(default_factory=lambda: uuid.uuid4().hex[:8])
    name: str = ""
    source_path: str = ""
    format: str = ""
    session: str = ""
    order: int = 0
    slides: list[Slide] = field(default_factory=list)
    render_dir: str = ""
    rendered: bool = False
    # Metadata
    presenter: str = ""
    notes: str = ""

    @property
    def slide_count(self) -> int:
        return len(self.slides)


@dataclass
class Show:
    """A complete show — an ordered list of cues."""
    name: str = "Untitled Show"
    created: str = ""
    source_dir: str = ""
    render_base: str = ""
    resolution: tuple[int, int] = (1920, 1080)
    cues: list[Cue] = field(default_factory=list)

    def save(self, path: str | Path):
        """Save show to JSON file."""
        path = Path(path)
        data = asdict(self)
        # Convert resolution tuple to list for JSON
        data["resolution"] = list(self.resolution)
        path.write_text(json.dumps(data, indent=2))

    @classmethod
    def load(cls, path: str | Path) -> "Show":
        """Load show from JSON file."""
        path = Path(path)
        data = json.loads(path.read_text())
        data["resolution"] = tuple(data["resolution"])
        # Reconstruct nested dataclasses
        cues = []
        for cue_data in data.get("cues", []):
            slides = [Slide(**s) for s in cue_data.pop("slides", [])]
            cue = Cue(**cue_data, slides=slides)
            cues.append(cue)
        data["cues"] = cues
        return cls(**data)

    def get_cue(self, cue_id: str) -> Optional[Cue]:
        """Find a cue by ID."""
        for cue in self.cues:
            if cue.id == cue_id:
                return cue
        return None

    @property
    def total_slides(self) -> int:
        return sum(c.slide_count for c in self.cues)

    @property
    def all_rendered(self) -> bool:
        return all(c.rendered for c in self.cues)
