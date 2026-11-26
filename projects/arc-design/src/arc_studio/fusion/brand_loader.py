#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Brand token loader for Fusion workflows.

Reads brands/<slug>.json (via BrandProfile) and exposes values in the
representations Fusion and ffmpeg consume:

  • hex_to_fusion_rgb()   — #RRGGBB → (r, g, b) floats in 0.0–1.0 (Fusion native)
  • hex_to_ffmpeg_color() — #RRGGBB → "0xRRGGBB" (ffmpeg drawbox/colorchannelmixer)
  • FusionBrand           — resolved brand with absolute logo path + Fusion colors

The hex→float conversion matches how Fusion's Background and Text+ tools
serialize TopLeftRed/Green/Blue parameters in .setting files.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from arc_studio import config
from arc_studio.models.brand import BrandProfile


def hex_to_fusion_rgb(hex_color: str) -> tuple[float, float, float]:
    """Convert '#RRGGBB' (or 'RRGGBB') to Fusion's 0.0–1.0 float tuple."""
    h = hex_color.lstrip("#")
    if len(h) != 6:
        raise ValueError(f"Expected 6-char hex, got {hex_color!r}")
    r = int(h[0:2], 16) / 255.0
    g = int(h[2:4], 16) / 255.0
    b = int(h[4:6], 16) / 255.0
    return (r, g, b)


def hex_to_ffmpeg_color(hex_color: str) -> str:
    """Convert '#RRGGBB' to ffmpeg's '0xRRGGBB' form."""
    return "0x" + hex_color.lstrip("#").upper()


@dataclass
class FusionBrand:
    """Brand profile resolved for Fusion consumption.

    All color fields are Fusion-native float tuples. Logo path is absolute
    (or None if the SVG listed in the profile doesn't exist on disk).
    """

    slug: str
    name: str
    primary: tuple[float, float, float]
    secondary: tuple[float, float, float]
    accent: tuple[float, float, float]
    background: tuple[float, float, float]
    text_primary: tuple[float, float, float]
    text_secondary: tuple[float, float, float]
    primary_hex: str
    background_hex: str
    text_primary_hex: str
    font_primary: str
    font_secondary: str
    font_accent: str
    logo_path: Path | None
    design_notes: str = ""
    extras: dict[str, str] = field(default_factory=dict)

    @classmethod
    def load(cls, slug: str = "arc") -> "FusionBrand":
        brand_path = config.BRANDS_DIR / f"{slug}.json"
        if brand_path.exists():
            profile = BrandProfile.load(brand_path)
        else:
            # Fall back to the hard-coded default rather than crashing — lets
            # `arc-studio fusion` work on a fresh checkout before `brand init`.
            profile = BrandProfile.arc_default()

        logo_path: Path | None = None
        for rel in profile.logo_paths:
            candidate = (config.STUDIO_ROOT / rel).resolve()
            if candidate.exists():
                logo_path = candidate
                break

        c = profile.colors
        return cls(
            slug=profile.slug,
            name=profile.name,
            primary=hex_to_fusion_rgb(c.primary),
            secondary=hex_to_fusion_rgb(c.secondary),
            accent=hex_to_fusion_rgb(c.accent),
            background=hex_to_fusion_rgb(c.background),
            text_primary=hex_to_fusion_rgb(c.text_primary),
            text_secondary=hex_to_fusion_rgb(c.text_secondary),
            primary_hex=c.primary,
            background_hex=c.background,
            text_primary_hex=c.text_primary,
            font_primary=profile.font_primary,
            font_secondary=profile.font_secondary,
            font_accent=profile.font_accent,
            logo_path=logo_path,
            design_notes=profile.design_notes,
            extras=dict(c.extras),
        )

    def summary(self) -> str:
        lines = [
            f"Brand: {self.name} ({self.slug})",
            f"  primary    {self.primary_hex}  →  rgb{tuple(round(v, 3) for v in self.primary)}",
            f"  background {self.background_hex}  →  rgb{tuple(round(v, 3) for v in self.background)}",
            f"  text       {self.text_primary_hex}  →  rgb{tuple(round(v, 3) for v in self.text_primary)}",
            f"  font       {self.font_primary}",
            f"  logo       {self.logo_path or '(not resolved)'}",
        ]
        return "\n".join(lines)
