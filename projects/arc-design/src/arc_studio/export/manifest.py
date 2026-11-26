#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Export ShowManifest as arc-lower-thirds-compatible JSON."""

from __future__ import annotations

import logging
from pathlib import Path

from arc_studio import config
from arc_studio.models.graphic import ShowManifest

log = logging.getLogger(__name__)


def export_manifest(manifest: ShowManifest, output_dir: Path | None = None) -> Path:
    """Write manifest.json in the format GraphicsImporter.swift expects."""
    arc_num = manifest.arcNumber or "unnamed"
    out_dir = output_dir or config.OUTPUT_DIR / arc_num
    out_dir.mkdir(parents=True, exist_ok=True)

    path = out_dir / "manifest.json"
    manifest.save(path)
    log.info(f"Manifest exported: {path} ({len(manifest.graphics)} graphics)")
    return path
