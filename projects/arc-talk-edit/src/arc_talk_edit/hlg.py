"""HLG (Sony "HLG mild look", BT.2020) -> display-referred Rec.709, in numpy (this ffmpeg build has no zscale).

JOB-0000 (2026-10-21, PXW-Z200 XAVC 4K59.94 HLG). Path: HLG signal R'G'B' (BT.2020 primaries) -> inverse HLG OETF (scene
linear 0..1) -> HLG OOTF (system gamma 1.2 on luminance) -> BT.2020 to BT.709 primaries -> scale so HLG reference white
(75 % signal) lands at `ref_white` -> soft shoulder above `knee` -> BT.709 encode (sRGB-like curve, matching grade.py).
`lut()` composes this with any display-referred grade into one 33^3 cube whose INPUT is the HLG signal, so ffmpeg lut3d
or a Resolve node applies decode + grade in one step.
"""
from __future__ import annotations
import subprocess
import numpy as np
from . import grade as G

A, B, C = 0.17883277, 0.28466892, 0.55991073
M2020_709 = np.array([[1.6605, -0.5876, -0.0728], [-0.1246, 1.1329, -0.0083], [-0.0182, -0.1006, 1.1187]])
Y2020 = np.array([0.2627, 0.6780, 0.0593])


def inv_oetf(e):
    e = np.clip(e, 0, 1)
    return np.where(e <= 0.5, e ** 2 / 3, (np.exp((e - C) / A) + B) / 12)


REF = float(inv_oetf(np.array(0.75)))      # scene linear of HLG 75 % reference white


def to709(sig: np.ndarray, exposure: float = 0.75, knee: float = 0.45, top: float = 0.95, gamma: float = 1.2) -> np.ndarray:
    """HLG signal (..., 3) in 0..1 -> Rec.709 display-referred 0..1.
    exposure: linear scale with HLG reference white = 1.0 (C0118: 0.75 puts lit skin at ~0.70 encoded; white shirts sit at
    HLG 0.88 = 2.3x reference white, so a 1.0 scale clipped them). Highlights above `knee` (linear) roll exponentially
    toward `top` on LUMINANCE with chroma fading to white, so no channel clips and hue holds (10/21 v1 clipped skin R)."""
    e = inv_oetf(sig)
    ys = np.clip(e @ Y2020, 1e-9, None)[..., None]
    d = e * ys ** (gamma - 1) / REF ** gamma                # OOTF, reference white -> 1.0
    d = np.clip(d @ M2020_709.T, 0, None) * exposure        # BT.709 primaries, display linear
    y = np.clip(d @ np.array([0.2126, 0.7152, 0.0722]), 1e-9, None)[..., None]
    over = np.clip(y - knee, 0, None)
    y2 = np.where(y > knee, knee + (top - knee) * (1 - np.exp(-over / (top - knee))), y)
    d = d * y2 / y
    w = np.clip((y2 - knee) / (top - knee), 0, 1) ** 2      # 0 at the knee, 1 at the top
    d = d + (y2 - d) * w * np.clip(d.max(-1, keepdims=True) - top, 0, None) / np.maximum(d.max(-1, keepdims=True) - y2, 1e-6)
    return np.clip(G.to_enc(np.clip(d, 0, 1)), 0, 1)


def frame(src, t: float, w: int = 1920, h: int = 1080) -> np.ndarray:
    """One frame as the HLG R'G'B' SIGNAL (BT.2020 matrix, limited range), float 0..1."""
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{t:.3f}", "-i", str(src), "-frames:v", "1", "-vf",
                          f"scale={w}:{h}:flags=lanczos:in_color_matrix=bt2020:in_range=tv:out_range=pc,format=rgb48le",
                          "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.uint16).reshape(h, w, 3).astype(np.float64) / 65535


def lut(grade_fn=None, n: int = G.N, **kw) -> np.ndarray:
    """Cube from HLG signal: decode (to709) then the display-referred grade_fn (rgb -> rgb), if any."""
    g = G.grid(n)
    x = to709(g, **kw)
    return np.clip(grade_fn(x) if grade_fn else x, 0, 1)


def grade_fn(black: float, mid: float = 0.36, black_target: float = 0.035, sat: float = 1.06):
    """Open-shade exterior finish (JOB-0000): the clip's own black (p0.5 after decode) -> black_target, `mid` held where
    the decode put it (power curve through it), additive luma move, chroma x sat with neutrals kept neutral. The full
    grade.finish S crushed this footage (C0118 black 0.007, darker skin 0.39), so no S here."""
    nb = lambda v: np.clip((v - black) / (1 - black), 1e-6, 1)
    gam = float(np.log((mid - black_target) / (1 - black_target)) / np.log(nb(mid)))

    def f(x):
        x = G.tone(x, lambda y: black_target + (1 - black_target) * nb(y) ** gam)
        lab = G.rgb2lab(x); c = np.hypot(lab[..., 1], lab[..., 2])[..., None]
        lab[..., 1:] *= 1 + (sat - 1) * np.clip((c - 4) / 8, 0, 1)
        return np.clip(G.lab2rgb(lab), 0, 1)
    return f
