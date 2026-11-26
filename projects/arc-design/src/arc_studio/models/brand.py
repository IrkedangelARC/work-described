#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Brand profile — colors, fonts, logos, design rules."""

from __future__ import annotations

import json
from dataclasses import dataclass, field, asdict
from pathlib import Path


@dataclass
class ColorPalette:
    primary: str = "#C1272D"       # ARC Red
    secondary: str = "#000000"     # Black
    accent: str = "#FFFFFF"        # White
    background: str = "#000000"
    text_primary: str = "#FFFFFF"
    text_secondary: str = "#CCCCCC"
    extras: dict[str, str] = field(default_factory=dict)


@dataclass
class BrandProfile:
    name: str
    slug: str
    colors: ColorPalette = field(default_factory=ColorPalette)
    font_primary: str = "Helvetica Neue"
    font_secondary: str = "Helvetica Neue"
    font_accent: str = "Helvetica Neue"
    logo_paths: list[str] = field(default_factory=list)
    design_notes: str = ""
    watermark: str | None = None

    def to_dict(self) -> dict:
        return asdict(self)

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self.to_dict(), indent=2))

    @classmethod
    def load(cls, path: Path) -> BrandProfile:
        data = json.loads(path.read_text())
        colors_data = data.pop("colors", {})
        data["colors"] = ColorPalette(**colors_data)
        return cls(**data)

    @classmethod
    def arc_default(cls) -> BrandProfile:
        return cls(
            name="ARC Event Productions",
            slug="arc",
            colors=ColorPalette(),
            font_primary="Helvetica Neue",
            font_secondary="Helvetica Neue",
            font_accent="Helvetica Neue",
            logo_paths=["logo/vector-exports/arc_logo_complete.svg"],
            design_notes="Industrial minimalism. Dark backgrounds, clean type, red accent.",
        )
