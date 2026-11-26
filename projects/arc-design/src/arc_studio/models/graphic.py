#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""GraphicSpec and ShowManifest — mirrors arc-lower-thirds JSON schema exactly."""

from __future__ import annotations

import json
from dataclasses import dataclass, field, asdict
from pathlib import Path


@dataclass
class GraphicSpec:
    """Mirrors ImportedGraphic from arc-lower-thirds GraphicsImporter.swift.

    Every field name matches the JSON key consumed by the Swift app.
    Optional fields omitted from export will use Swift-side defaults.
    """

    # --- Core (v1) ---
    line1: str
    line2: str | None = None
    line3: str | None = None
    animation: str | None = None          # slideFromLeft, slideFromRight, fadeUp, wipeLeft, cut
    accentColor: str | None = None        # Hex string "#A61C1C"
    notes: str | None = None
    template: str | None = None           # fullWidth, roundedBar, stackedBar, boldName, etc.
    position: str | None = None           # bottom, middle, top, custom
    fontFamily: str | None = None

    # --- v2: Styling ---
    line1FontSize: float | None = None
    line2FontSize: float | None = None
    line3FontSize: float | None = None
    line1Weight: str | None = None        # ultraLight..black
    line2Weight: str | None = None
    line3Weight: str | None = None
    line1Color: str | None = None
    line2Color: str | None = None
    line3Color: str | None = None
    line1Opacity: float | None = None
    line2Opacity: float | None = None
    line3Opacity: float | None = None
    backgroundOpacity: float | None = None
    titleBgColor: str | None = None
    titleBgOpacity: float | None = None
    gradientEnabled: bool | None = None
    gradientEndColor: str | None = None
    accentBarSize: float | None = None
    namePaddingH: float | None = None
    namePaddingV: float | None = None
    titlePaddingH: float | None = None
    titlePaddingV: float | None = None
    elementGap: float | None = None
    lineSpacing: float | None = None
    cornerRadius: float | None = None
    bottomOffset: float | None = None
    horizontalMargin: float | None = None
    maxWidthFraction: float | None = None
    hardEdge: bool | None = None
    shadowEnabled: bool | None = None
    shadowRadius: float | None = None
    shadowOpacity: float | None = None
    animationInDuration: float | None = None
    animationOutDuration: float | None = None
    logoPosition: str | None = None       # none, left, right, above
    logoSize: float | None = None

    # --- v3: Graphic types ---
    graphicType: str | None = None        # lowerThird, fullTitle, ticker, clock, logoBug, custom
    layer: str | None = None              # foreground, background, overlay
    tickerSpeed: float | None = None
    tickerSeparator: str | None = None
    clockFormat: str | None = None
    clockShowSeconds: bool | None = None
    bugCorner: str | None = None
    bugMarginH: float | None = None
    bugMarginV: float | None = None

    # --- v4: Image layers ---
    logoOffsetX: float | None = None
    logoOffsetY: float | None = None
    backgroundScale: float | None = None
    backgroundImageOpacity: float | None = None
    backgroundFitMode: str | None = None  # fill, fit, stretch, tile
    overlayScale: float | None = None
    overlayOpacity: float | None = None
    overlayOffsetX: float | None = None
    overlayOffsetY: float | None = None
    customTextOffsetX: float | None = None
    customTextOffsetY: float | None = None
    customTextAlignment: str | None = None  # leading, center, trailing

    def to_dict(self) -> dict:
        """Export as dict, omitting None values (Swift uses defaults)."""
        return {k: v for k, v in asdict(self).items() if v is not None}


@dataclass
class ShowManifest:
    """Mirrors ImportedShow from arc-lower-thirds GraphicsImporter.swift."""

    name: str
    graphics: list[GraphicSpec] = field(default_factory=list)
    arcNumber: str | None = None
    venue: str | None = None
    defaultAnimation: str | None = None
    defaultTemplate: str | None = None

    def to_dict(self) -> dict:
        d = {k: v for k, v in asdict(self).items()
             if v is not None and k != "graphics"}
        d["graphics"] = [g.to_dict() for g in self.graphics]
        return d

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self.to_dict(), indent=2))

    @classmethod
    def load(cls, path: Path) -> ShowManifest:
        data = json.loads(path.read_text())
        graphics_data = data.pop("graphics", [])
        graphics = [GraphicSpec(**g) for g in graphics_data]
        return cls(graphics=graphics, **data)
