#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Post-render derivation pipeline.

Takes one master render (ProRes 4444 with alpha channel) out of Fusion and
produces the three downstream delivery variants without re-rendering from
the comp.

Consumer requirements
─────────────────────
arc-lower-thirds (Swift custom skin)
    ProRes 4444 with alpha, same dims as master. The Swift GraphicsEngine
    composites live text over this as an AVPlayer video layer. We pass
    the master through unchanged (still with alpha) — just copy + tag.

ATEM Media Pool
    PNG sequence, premultiplied alpha. ATEM Software Control loads frames
    as numbered stills (frame0000.png …) for Media Pool playback via DVE
    or M/E keyer. We sample at 30 fps (ATEM native) and cap duration so
    the pool isn't overwhelmed.

arc-keyer (luma key)
    ProRes 4444 on SOLID BLACK — no alpha. The KeyEngine.swift Metal shader
    luma-keys against black to composite over a camera feed. We flatten the
    master's alpha onto a black background via ffmpeg's alphamerge/overlay
    chain, preserving color fidelity.

Usage
─────
    from arc_studio.fusion.derive import derive_all
    result = derive_all(Path("fusion/renders/master/arc_lt_fullwidth_v1.mov"))
    print(result.manifest_path)
"""

from __future__ import annotations

import logging
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from arc_studio import config

log = logging.getLogger(__name__)

# ── delivery roots ──────────────────────────────────────────────────────────
FUSION_ROOT = config.STUDIO_ROOT / "fusion"
MASTER_DIR = FUSION_ROOT / "renders" / "master"
DERIVED_ROOT = FUSION_ROOT / "renders" / "derived"
DERIVED_LT = DERIVED_ROOT / "lower-thirds"
DERIVED_ATEM = DERIVED_ROOT / "atem-media"
DERIVED_KEYER = DERIVED_ROOT / "keyer-luma"

# ATEM Media Pool sampling — ATEM Mini runs 30p in North America, media pool
# loads stills not video so we unroll the master into numbered PNGs.
ATEM_FPS = 30
ATEM_MAX_FRAMES = 300  # 10 s ceiling — Media Pool only holds ~20 slots total


@dataclass
class DeriveResult:
    master: Path
    lower_thirds: Path | None = None
    atem_sequence_dir: Path | None = None
    atem_frame_count: int = 0
    keyer_luma: Path | None = None
    manifest_path: Path | None = None
    warnings: list[str] = field(default_factory=list)


# ── ffmpeg helpers ──────────────────────────────────────────────────────────

def _ffmpeg_path() -> str:
    path = shutil.which("ffmpeg")
    if not path:
        raise RuntimeError("ffmpeg not found on PATH — install via `brew install ffmpeg`")
    return path


def _run(cmd: list[str]) -> None:
    log.debug("exec: %s", " ".join(cmd))
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"ffmpeg failed ({result.returncode}):\n"
            f"  cmd: {' '.join(cmd)}\n"
            f"  stderr: {result.stderr.strip()}"
        )


def _probe_master(master: Path) -> dict:
    """Return minimal ffprobe info: width, height, fps, duration, has_alpha."""
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        raise RuntimeError("ffprobe not found (comes with ffmpeg)")
    cmd = [
        ffprobe, "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,pix_fmt,duration",
        "-of", "default=noprint_wrappers=1",
        str(master),
    ]
    out = subprocess.check_output(cmd, text=True)
    info: dict = {}
    for line in out.strip().splitlines():
        k, _, v = line.partition("=")
        info[k] = v
    # parse fps fraction
    fps_raw = info.get("r_frame_rate", "30/1")
    num, _, den = fps_raw.partition("/")
    try:
        info["fps"] = float(num) / float(den) if den else float(num)
    except (ValueError, ZeroDivisionError):
        info["fps"] = 30.0
    info["has_alpha"] = info.get("pix_fmt", "") in {
        "yuva444p10le", "yuva444p12le", "yuva420p", "rgba", "bgra"
    }
    return info


# ── variant builders ────────────────────────────────────────────────────────

def _derive_lower_thirds(master: Path, info: dict) -> Path:
    """LT custom skin = master passed through (alpha preserved).

    We copy rather than re-encode so there's zero quality loss — the arc-lower-
    thirds Swift app consumes the file as an AVAsset video layer. A stream
    copy ensures the ProRes 4444 stays pristine.
    """
    DERIVED_LT.mkdir(parents=True, exist_ok=True)
    out = DERIVED_LT / f"{master.stem}__lt.mov"
    if not info.get("has_alpha"):
        log.warning("master %s lacks alpha — LT custom skin will render opaque", master.name)
    _run([
        _ffmpeg_path(), "-y",
        "-i", str(master),
        "-c", "copy",
        str(out),
    ])
    return out


def _derive_atem_sequence(master: Path, info: dict) -> tuple[Path, int]:
    """ATEM Media Pool — numbered PNG sequence with premultiplied alpha.

    Sampled at ATEM_FPS. Capped at ATEM_MAX_FRAMES so we don't exceed Media
    Pool capacity. Output files are named atem_0000.png, atem_0001.png…
    """
    seq_dir = DERIVED_ATEM / master.stem
    if seq_dir.exists():
        shutil.rmtree(seq_dir)
    seq_dir.mkdir(parents=True)

    out_pattern = str(seq_dir / "atem_%04d.png")
    _run([
        _ffmpeg_path(), "-y",
        "-i", str(master),
        "-vf", f"fps={ATEM_FPS}",
        "-frames:v", str(ATEM_MAX_FRAMES),
        "-pix_fmt", "rgba",
        out_pattern,
    ])
    frame_count = len(list(seq_dir.glob("atem_*.png")))
    return seq_dir, frame_count


def _derive_keyer_luma(master: Path, info: dict) -> Path:
    """arc-keyer luma variant — flatten alpha onto solid black, ProRes 4444.

    The keyer's Metal shader luma-keys against black, so we bake the alpha
    into a color composite. Using ffmpeg's overlay of the master onto a
    color=black source preserves YUV fidelity for the downstream keyer.
    """
    DERIVED_KEYER.mkdir(parents=True, exist_ok=True)
    out = DERIVED_KEYER / f"{master.stem}__luma.mov"
    width = info.get("width", "1920")
    height = info.get("height", "1080")
    fps = info.get("fps", 30.0)

    # Build a black background of matching dims/fps then overlay the master
    # (which has alpha) on top. Result is fully opaque black-backed color.
    _run([
        _ffmpeg_path(), "-y",
        "-f", "lavfi",
        "-i", f"color=c=black:s={width}x{height}:r={fps:g}",
        "-i", str(master),
        "-filter_complex", "[0:v][1:v]overlay=shortest=1[out]",
        "-map", "[out]",
        "-c:v", "prores_ks",
        "-profile:v", "4",   # ProRes 4444 (no alpha needed — keyer takes luma)
        "-pix_fmt", "yuv444p10le",
        str(out),
    ])
    return out


# ── public entrypoint ───────────────────────────────────────────────────────

def derive_all(master: Path, *, skip: set[str] | None = None) -> DeriveResult:
    """Run the full derive pipeline on a single master render.

    Parameters
    ----------
    master : Path
        Path to the ProRes 4444 master (should live under fusion/renders/master/).
    skip : set[str], optional
        Variants to skip: any of {"lt", "atem", "keyer"}. Defaults to none.

    Returns
    -------
    DeriveResult with paths to each derived variant (None for skipped).
    """
    skip = skip or set()
    master = master.resolve()
    if not master.exists():
        raise FileNotFoundError(f"master render not found: {master}")

    info = _probe_master(master)
    log.info(
        "master: %s  %sx%s  %.3f fps  pix_fmt=%s  alpha=%s",
        master.name, info.get("width"), info.get("height"),
        info.get("fps", 0), info.get("pix_fmt"), info.get("has_alpha"),
    )

    result = DeriveResult(master=master)

    if "lt" not in skip:
        result.lower_thirds = _derive_lower_thirds(master, info)
        log.info("  → LT skin:    %s", result.lower_thirds.relative_to(config.STUDIO_ROOT))
    if "atem" not in skip:
        seq_dir, frames = _derive_atem_sequence(master, info)
        result.atem_sequence_dir = seq_dir
        result.atem_frame_count = frames
        log.info("  → ATEM seq:   %s  (%d frames @ %d fps)",
                 seq_dir.relative_to(config.STUDIO_ROOT), frames, ATEM_FPS)
    if "keyer" not in skip:
        result.keyer_luma = _derive_keyer_luma(master, info)
        log.info("  → keyer luma: %s", result.keyer_luma.relative_to(config.STUDIO_ROOT))

    # manifest is written by the caller (fusion CLI) so derive.py stays
    # focused on ffmpeg and doesn't need to know about manifest schema.
    return result
