#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Global configuration — paths, canvas defaults, API endpoints."""

import os
from pathlib import Path

# --- Paths ---
STUDIO_ROOT = Path(__file__).resolve().parent.parent
LOGO_DIR = STUDIO_ROOT / "logo"
BRANDS_DIR = STUDIO_ROOT / "brands"
OUTPUT_DIR = STUDIO_ROOT / "output"
FONTS_DIR = STUDIO_ROOT / "fonts"

# Arc Events registry (sibling project)
ARC_EVENTS_DIR = Path(os.environ.get(
    "ARC_EVENTS_DIR",
    str(STUDIO_ROOT.parent / "arc-events"),
))
EVENT_REGISTRY_PATH = ARC_EVENTS_DIR / "event_registry.json"

# --- Canvas ---
CANVAS_WIDTH = 1920
CANVAS_HEIGHT = 1080

# Broadcast safe zones (action safe / title safe)
ACTION_SAFE_MARGIN = 0.035   # 3.5% inset
TITLE_SAFE_MARGIN = 0.10     # 10% inset

# --- Brand defaults ---
ARC_RED = "#C1272D"
ARC_BLACK = "#000000"
ARC_WHITE = "#FFFFFF"
DEFAULT_FONT = "Futura"

# --- AI backends ---
REPLICATE_API_TOKEN = os.environ.get("REPLICATE_API_TOKEN", "")
OLLAMA_STUDIO_URL = os.environ.get("OLLAMA_STUDIO_URL", "http://192.0.2.41:11434")
OLLAMA_MINI_URL = os.environ.get("OLLAMA_MINI_URL", "http://192.0.2.126:11434")

# --- Supported media formats ---
# Organized by processing pipeline required

IMAGE_EXTENSIONS = {
    # Pillow-native (direct load)
    ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tiff", ".tif",
    ".webp", ".ico", ".ppm", ".pgm", ".pbm",
    # Pillow with plugins
    ".heic", ".heif", ".avif",
    # Requires specialized loader
    ".svg",        # cairosvg → PNG
    ".eps",        # Ghostscript via Pillow or Wand
    ".ai",         # Treated as PDF/EPS
    ".psd",        # psd-tools
}

VIDEO_EXTENSIONS = {
    ".mp4", ".mov", ".avi", ".mkv", ".mxf", ".wmv",
    ".webm", ".flv", ".m4v", ".ts", ".mpg", ".mpeg",
    ".prores",     # ProRes MOV
    ".mts", ".m2ts",  # AVCHD
}

DOCUMENT_EXTENSIONS = {
    ".pdf",        # PyMuPDF → page images
    ".pptx",       # python-pptx → slide images
    ".ppt",        # Legacy PowerPoint (via LibreOffice)
    ".docx",       # python-docx → text + images
    ".key",        # Keynote (macOS-only conversion)
    ".pages",      # Pages (macOS-only conversion)
}

VECTOR_EXTENSIONS = {
    ".svg", ".eps", ".ai",
}

RAW_PHOTO_EXTENSIONS = {
    ".cr2", ".cr3",   # Canon
    ".arw",           # Sony
    ".nef",           # Nikon
    ".orf",           # Olympus
    ".rw2",           # Panasonic
    ".dng",           # Adobe DNG
    ".raf",           # Fuji
}

AUDIO_EXTENSIONS = {
    ".wav", ".mp3", ".aiff", ".aif", ".m4a",
    ".flac", ".ogg", ".wma",
}

FONT_EXTENSIONS = {
    ".ttf", ".otf", ".woff", ".woff2",
}

ALL_SUPPORTED = (
    IMAGE_EXTENSIONS | VIDEO_EXTENSIONS | DOCUMENT_EXTENSIONS
    | RAW_PHOTO_EXTENSIONS | AUDIO_EXTENSIONS | FONT_EXTENSIONS
)
