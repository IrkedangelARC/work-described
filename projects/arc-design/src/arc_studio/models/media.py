#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Media asset model — represents any ingested file with metadata."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

from arc_studio import config


class MediaType(Enum):
    IMAGE = "image"
    VIDEO = "video"
    DOCUMENT = "document"
    VECTOR = "vector"
    RAW_PHOTO = "raw_photo"
    AUDIO = "audio"
    FONT = "font"
    UNKNOWN = "unknown"

    @classmethod
    def from_extension(cls, ext: str) -> MediaType:
        ext = ext.lower()
        if ext in config.IMAGE_EXTENSIONS:
            return cls.IMAGE
        if ext in config.VIDEO_EXTENSIONS:
            return cls.VIDEO
        if ext in config.DOCUMENT_EXTENSIONS:
            return cls.DOCUMENT
        if ext in config.VECTOR_EXTENSIONS:
            return cls.VECTOR
        if ext in config.RAW_PHOTO_EXTENSIONS:
            return cls.RAW_PHOTO
        if ext in config.AUDIO_EXTENSIONS:
            return cls.AUDIO
        if ext in config.FONT_EXTENSIONS:
            return cls.FONT
        return cls.UNKNOWN


@dataclass
class MediaAsset:
    """A single ingested media file with extracted metadata."""

    path: Path
    media_type: MediaType
    label: str = ""                          # User-assigned label (e.g., "client_logo")
    tags: list[str] = field(default_factory=list)

    # Populated after ingestion
    width: int | None = None
    height: int | None = None
    duration_seconds: float | None = None    # Video/audio
    page_count: int | None = None            # PDF/PPTX
    color_mode: str | None = None            # RGB, RGBA, CMYK, Grayscale
    has_alpha: bool = False
    file_size_bytes: int = 0
    content_hash: str = ""                   # SHA-256 for dedup

    # Extracted content
    extracted_text: str | None = None        # From PDF/PPTX/DOCX
    extracted_images: list[Path] = field(default_factory=list)  # Pages/slides as PNGs
    thumbnail_path: Path | None = None

    @property
    def extension(self) -> str:
        return self.path.suffix.lower()

    @property
    def filename(self) -> str:
        return self.path.name

    @property
    def is_raster(self) -> bool:
        return self.media_type in (MediaType.IMAGE, MediaType.RAW_PHOTO)

    @property
    def is_temporal(self) -> bool:
        return self.media_type in (MediaType.VIDEO, MediaType.AUDIO)

    @property
    def dimensions(self) -> tuple[int, int] | None:
        if self.width and self.height:
            return (self.width, self.height)
        return None

    def compute_hash(self) -> str:
        h = hashlib.sha256()
        with open(self.path, "rb") as f:
            for chunk in iter(lambda: f.read(8192), b""):
                h.update(chunk)
        self.content_hash = h.hexdigest()
        return self.content_hash

    @classmethod
    def from_path(cls, path: Path, label: str = "", tags: list[str] | None = None) -> MediaAsset:
        path = Path(path).resolve()
        media_type = MediaType.from_extension(path.suffix)
        asset = cls(
            path=path,
            media_type=media_type,
            label=label or path.stem,
            tags=tags or [],
            file_size_bytes=path.stat().st_size if path.exists() else 0,
        )
        return asset


@dataclass
class AssetCollection:
    """A named group of media assets (e.g., 'client_materials', 'event_photos')."""

    name: str
    assets: list[MediaAsset] = field(default_factory=list)
    description: str = ""

    def add(self, asset: MediaAsset) -> None:
        self.assets.append(asset)

    def add_path(self, path: Path, label: str = "", tags: list[str] | None = None) -> MediaAsset:
        asset = MediaAsset.from_path(path, label, tags)
        self.assets.append(asset)
        return asset

    def by_type(self, media_type: MediaType) -> list[MediaAsset]:
        return [a for a in self.assets if a.media_type == media_type]

    @property
    def images(self) -> list[MediaAsset]:
        return self.by_type(MediaType.IMAGE)

    @property
    def videos(self) -> list[MediaAsset]:
        return self.by_type(MediaType.VIDEO)

    @property
    def documents(self) -> list[MediaAsset]:
        return self.by_type(MediaType.DOCUMENT)

    @property
    def vectors(self) -> list[MediaAsset]:
        return self.by_type(MediaType.VECTOR)

    def find(self, label: str) -> MediaAsset | None:
        for a in self.assets:
            if a.label == label:
                return a
        return None

    def all_paths(self) -> list[Path]:
        return [a.path for a in self.assets]
