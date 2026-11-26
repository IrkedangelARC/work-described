#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Event package — bundles all generated outputs into a structured directory."""

from __future__ import annotations

import json
import logging
from datetime import datetime
from pathlib import Path

from arc_studio import config
from arc_studio.models.graphic import ShowManifest

log = logging.getLogger(__name__)


class EventPackage:
    """Manages the output directory structure for a single event.

    output/{ARC-NUMBER}/
        manifest.json          — arc-lower-thirds import file
        metadata.json          — generation metadata
        previews/              — preview PNGs
        luma-key/              — luma key source PNGs
        assets/                — copies of used brand assets
        video/                 — motion graphics exports
    """

    def __init__(self, arc_number: str, output_root: Path | None = None):
        self.arc_number = arc_number
        self.root = (output_root or config.OUTPUT_DIR) / arc_number
        self.previews_dir = self.root / "previews"
        self.luma_dir = self.root / "luma-key"
        self.assets_dir = self.root / "assets"
        self.video_dir = self.root / "video"
        self._ensure_dirs()

    def _ensure_dirs(self) -> None:
        for d in [self.root, self.previews_dir, self.luma_dir,
                  self.assets_dir, self.video_dir]:
            d.mkdir(parents=True, exist_ok=True)

    def save_manifest(self, manifest: ShowManifest) -> Path:
        path = self.root / "manifest.json"
        manifest.save(path)
        return path

    def save_metadata(self, extra: dict | None = None) -> Path:
        meta = {
            "arc_number": self.arc_number,
            "generated_at": datetime.now().isoformat(),
            "studio_version": "0.1.0",
            "canvas": {"width": config.CANVAS_WIDTH, "height": config.CANVAS_HEIGHT},
        }
        if extra:
            meta.update(extra)
        path = self.root / "metadata.json"
        path.write_text(json.dumps(meta, indent=2))
        return path

    @property
    def manifest_path(self) -> Path:
        return self.root / "manifest.json"

    def list_outputs(self) -> dict[str, list[str]]:
        result = {}
        for subdir in [self.previews_dir, self.luma_dir, self.assets_dir, self.video_dir]:
            files = sorted(f.name for f in subdir.iterdir() if f.is_file())
            if files:
                result[subdir.name] = files
        return result
