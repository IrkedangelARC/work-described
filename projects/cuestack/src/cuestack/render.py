#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Render presentations to slide images using LibreOffice and pdf2image."""
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

from .models import Show, Cue, Slide

# Render resolution
DEFAULT_DPI = 200  # ~1920x1080 for standard slides


def render_show(show: Show, force: bool = False) -> Show:
    """Render all cues in a show to images."""
    render_base = Path(show.render_base)
    render_base.mkdir(parents=True, exist_ok=True)

    total = len(show.cues)
    for i, cue in enumerate(show.cues):
        if cue.rendered and not force:
            print(f"  [{i+1}/{total}] Skipping (already rendered): {cue.name}")
            continue

        print(f"  [{i+1}/{total}] Rendering: {cue.name} ({cue.format})")
        try:
            render_cue(cue, render_base)
            print(f"           -> {cue.slide_count} slides")
        except Exception as e:
            print(f"           ERROR: {e}")

    return show


def render_cue(cue: Cue, render_base: Path):
    """Render a single cue to slide images."""
    source = Path(cue.source_path)
    if not source.exists():
        raise FileNotFoundError(f"Source file not found: {source}")

    # Create output directory for this cue
    cue_dir = render_base / cue.id
    if cue_dir.exists():
        shutil.rmtree(cue_dir)
    cue_dir.mkdir(parents=True)

    fmt = cue.format.lower()

    if fmt == ".pdf":
        slides = _render_pdf(source, cue_dir)
    elif fmt in (".pptx", ".ppt", ".odp", ".key"):
        slides = _render_via_libreoffice(source, cue_dir)
    else:
        raise ValueError(f"Unsupported format: {fmt}")

    cue.slides = slides
    cue.render_dir = str(cue_dir)
    cue.rendered = True


def _render_pdf(source: Path, output_dir: Path) -> list[Slide]:
    """Render PDF pages to images using pdf2image."""
    try:
        from pdf2image import convert_from_path
    except ImportError:
        raise RuntimeError(
            "pdf2image not installed. Run: pip install pdf2image\n"
            "Also need poppler: brew install poppler"
        )

    images = convert_from_path(str(source), dpi=DEFAULT_DPI, fmt="png")
    slides = []
    for i, img in enumerate(images):
        img_path = output_dir / f"slide_{i:04d}.png"
        img.save(str(img_path), "PNG")
        slides.append(Slide(
            index=i,
            image_path=str(img_path),
            width=img.width,
            height=img.height,
        ))
    return slides


def _render_via_libreoffice(source: Path, output_dir: Path) -> list[Slide]:
    """Convert presentation to PDF via LibreOffice, then render to images."""
    lo_path = _find_libreoffice()
    if not lo_path:
        raise RuntimeError(
            "LibreOffice not found. Install it:\n"
            "  brew install --cask libreoffice\n"
            "Or set LIBREOFFICE_PATH environment variable."
        )

    # Step 1: Convert to PDF using LibreOffice headless
    with tempfile.TemporaryDirectory() as tmpdir:
        cmd = [
            lo_path,
            "--headless",
            "--convert-to", "pdf",
            "--outdir", tmpdir,
            str(source),
        ]
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"LibreOffice conversion failed:\n{result.stderr}"
            )

        # Find the output PDF
        pdf_files = list(Path(tmpdir).glob("*.pdf"))
        if not pdf_files:
            raise RuntimeError("LibreOffice produced no PDF output")

        # Step 2: Render PDF to images
        return _render_pdf(pdf_files[0], output_dir)


def _find_libreoffice() -> str | None:
    """Find the LibreOffice binary."""
    import os

    # Check environment variable first
    env_path = os.environ.get("LIBREOFFICE_PATH")
    if env_path and Path(env_path).exists():
        return env_path

    # Common macOS paths
    candidates = [
        "/Applications/LibreOffice.app/Contents/MacOS/soffice",
        "/usr/local/bin/soffice",
        "/opt/homebrew/bin/soffice",
    ]
    for c in candidates:
        if Path(c).exists():
            return c

    # Try PATH
    result = subprocess.run(
        ["which", "soffice"], capture_output=True, text=True
    )
    if result.returncode == 0:
        return result.stdout.strip()

    return None


def check_dependencies() -> dict[str, bool]:
    """Check if required external tools are available."""
    deps = {}

    # LibreOffice
    deps["libreoffice"] = _find_libreoffice() is not None

    # Poppler (for pdf2image)
    result = subprocess.run(
        ["which", "pdftoppm"], capture_output=True, text=True
    )
    deps["poppler"] = result.returncode == 0

    # Python packages
    try:
        import pdf2image  # noqa: F401
        deps["pdf2image"] = True
    except ImportError:
        deps["pdf2image"] = False

    try:
        import PIL  # noqa: F401
        deps["pillow"] = True
    except ImportError:
        deps["pillow"] = False

    try:
        import pygame  # noqa: F401
        deps["pygame"] = True
    except ImportError:
        deps["pygame"] = False

    return deps
