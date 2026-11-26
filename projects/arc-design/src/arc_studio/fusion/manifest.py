#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Delivery manifest writer for Fusion-derived assets.

Writes a JSON sidecar next to each master that declares:
  • the master render (path, sha256, dimensions, fps, duration)
  • the brand slug used
  • each derived variant (consumer, path, format, notes)

Downstream consumers read the manifest to locate the correct variant without
guessing directory layout:

    arc-lower-thirds  → manifest.variants["lower-thirds"].path
    arc-keyer         → manifest.variants["keyer-luma"].path
    ATEM Companion    → manifest.variants["atem-media"].path  (sequence dir)
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path

from arc_studio import config
from arc_studio.fusion.derive import DeriveResult


MANIFEST_SCHEMA_VERSION = 1


def _sha256(path: Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            buf = f.read(chunk)
            if not buf:
                break
            h.update(buf)
    return h.hexdigest()


def _rel(path: Path) -> str:
    """Render paths relative to arc-design root for portability across machines."""
    try:
        return str(path.resolve().relative_to(config.STUDIO_ROOT))
    except ValueError:
        return str(path.resolve())


@dataclass
class Variant:
    consumer: str
    path: str
    format: str
    notes: str = ""
    frame_count: int | None = None


@dataclass
class DeliveryManifest:
    schema_version: int
    generated_at: str
    template_id: str
    brand_slug: str
    master: dict
    variants: dict[str, Variant] = field(default_factory=dict)

    def to_json(self) -> str:
        payload = asdict(self)
        # Variant dataclasses need manual unwrapping inside the dict
        payload["variants"] = {k: asdict(v) for k, v in self.variants.items()}
        return json.dumps(payload, indent=2)


def build_manifest(
    result: DeriveResult,
    *,
    template_id: str,
    brand_slug: str,
) -> DeliveryManifest:
    """Construct a manifest describing the derive result."""
    master_stat = result.master.stat()
    master_info = {
        "path": _rel(result.master),
        "filename": result.master.name,
        "size_bytes": master_stat.st_size,
        "sha256": _sha256(result.master),
    }

    variants: dict[str, Variant] = {}
    if result.lower_thirds:
        variants["lower-thirds"] = Variant(
            consumer="arc-lower-thirds",
            path=_rel(result.lower_thirds),
            format="prores_4444_alpha",
            notes="Custom skin background for ArcLowerThirds Swift app — composite live text over.",
        )
    if result.atem_sequence_dir:
        variants["atem-media"] = Variant(
            consumer="atem-software-control",
            path=_rel(result.atem_sequence_dir),
            format="png_sequence_rgba",
            notes="Numbered PNGs for ATEM Media Pool. Load via ATEM SC → Media → Still Import.",
            frame_count=result.atem_frame_count or None,
        )
    if result.keyer_luma:
        variants["keyer-luma"] = Variant(
            consumer="arc-keyer",
            path=_rel(result.keyer_luma),
            format="prores_4444_black_bg",
            notes="Solid-black background for KeyEngine luma key. No alpha — composited opaque.",
        )

    return DeliveryManifest(
        schema_version=MANIFEST_SCHEMA_VERSION,
        generated_at=datetime.now(timezone.utc).isoformat(),
        template_id=template_id,
        brand_slug=brand_slug,
        master=master_info,
        variants=variants,
    )


def write_manifest(
    result: DeriveResult,
    *,
    template_id: str,
    brand_slug: str,
) -> Path:
    """Write the manifest next to the master render as <master>.manifest.json."""
    manifest = build_manifest(result, template_id=template_id, brand_slug=brand_slug)
    out = result.master.with_suffix(result.master.suffix + ".manifest.json")
    out.write_text(manifest.to_json())
    return out
