"""Tracked, luminance-qualified face power windows rendered to ProRes HQ 59.94 (ported 10/1 from
an earlier one-off tool, numerics unchanged; proven on a backlit feature edit).

Global = grade.backlight's measured LUT for the clip's first frame. Faces every STEP frames (0.5 s) on the RAW frames,
skin-validated, linked into tracks by nearest centre, interpolated per frame and smoothed (3-sample moving average) so the
ellipse glides. Each track gets ONE lift (median skin over its first samples -> SKIN_TARGET, <= MAX_LIFT) so exposure never
pumps. Per frame the lift is luminance-qualified (grade.apply_windows).
"""
from __future__ import annotations

import subprocess
from pathlib import Path

import numpy as np

from . import grade as G

W, H = 1920, 1080
SKIN_TARGET, MAX_LIFT, STEP = 0.58, 1.2, 30


def frames(src, t, dur, vf=""):
    cmd = ["ffmpeg", "-v", "error", "-ss", f"{t:.3f}", "-t", f"{dur:.3f}", "-i", str(src), "-vf",
           f"setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,fps=60000/1001,scale={W}:{H}{vf}",
           "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    while True:
        b = p.stdout.read(W * H * 3)
        if len(b) < W * H * 3:
            return
        yield np.frombuffer(b, np.uint8).reshape(H, W, 3)


def writer(path):
    return subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                             "-r", "60000/1001", "-i", "-", "-c:v", "prores_ks", "-profile:v", "3", "-vendor", "apl0",
                             "-pix_fmt", "yuv422p10le", "-color_primaries", "bt709", "-color_trc", "bt709",
                             "-colorspace", "bt709", str(path)], stdin=subprocess.PIPE)


def link(samples):
    """Pure: [(frame_index, [(cx, cy, w, h), ...]), ...] -> tracks [{frame_index: box}], flickers (< 1/3 of samples) dropped."""
    trk = []
    for i, boxes in samples:
        for c in boxes:
            best = min(trk, key=lambda tr: np.hypot(*(np.array(tr[max(tr)][:2]) - c[:2])), default=None)
            if best is not None and max(best) < i and np.hypot(*(np.array(best[max(best)][:2]) - c[:2])) < 1.2 * c[2]:
                best[i] = c
            else:
                trk.append({i: c})
    return [tr for tr in trk if len(tr) >= max(2, len(samples) // 3)]


def per_frame(tr, n):
    """Pure: interpolate + smooth one track to every frame (held at the ends) -> (n, 4) array of (cx, cy, w, h)."""
    ks = sorted(tr); arr = np.array([tr[k] for k in ks], float)
    if len(arr) >= 3:
        arr = np.vstack([arr[:1], (arr[:-2] + arr[1:-1] + arr[2:]) / 3, arr[-1:]])
    return np.stack([np.interp(np.arange(n), ks, arr[:, j]) for j in range(4)], 1)


def tracks(src, t, dur):
    samples = []; i = -1
    for i, f in enumerate(frames(src, t, dur)):
        if i % STEP == 0:
            img = f / 255.0
            samples.append((i, [(x + w / 2, y + h / 2, w, h) for x, y, w, h in G.skin_faces(img, G.faces(img))]))
    return link(samples), i + 1


def render(src, t, dur, key, out_dir):
    """-> <out_dir>/<key>_global.mov + <key>_window.mov (+ the global .cube and stills sheet from grade.backlight)."""
    out = Path(out_dir); out.mkdir(parents=True, exist_ok=True)
    info = G.backlight(src, t, out, key)
    lut_path = info["lut"]
    trk, n = tracks(src, t, dur)
    paths = [per_frame(tr, n) for tr in trk]
    lifts = []
    gw, ww = writer(out / f"{key}_global.mov"), writer(out / f"{key}_window.mov")
    skin_acc = [[] for _ in trk]
    for i, f in enumerate(frames(src, t, dur, f",lut3d=file='{lut_path}':interp=tetrahedral")):
        g1 = f / 255.0
        if i == 0 or (i % STEP == 0 and i < 4 * STEP):                # measure skin on the first samples, then freeze
            for k, p in enumerate(paths):
                cx, cy, w, h = p[min(i, n - 1)]
                y0, y1, x0, x1 = int(cy - h / 4), int(cy + h / 4), int(cx - w / 4), int(cx + w / 4)
                skin_acc[k].append(float(np.median(G.luma(g1[max(0, y0):y1, max(0, x0):x1].reshape(-1, 3)))))
            lifts = [G.lift_for(float(np.median(s)), SKIN_TARGET, MAX_LIFT) for s in skin_acc]
        boxes = [(p[i][0] - p[i][2] / 2, p[i][1] - p[i][3] / 2, p[i][2], p[i][3]) for p in paths]
        g2 = G.apply_windows(g1, boxes, lifts, [float(np.median(s)) for s in skin_acc], by_lift=False)
        gw.stdin.write(f.tobytes()); ww.stdin.write((g2 * 255 + 0.5).astype(np.uint8).tobytes())
    for p in (gw, ww):
        p.stdin.close(); p.wait()
    return dict(frames=n, tracks=len(trk), lifts=[round(v, 2) for v in lifts], global_stops=info["global_stops"],
                global_mov=str(out / f"{key}_global.mov"), window_mov=str(out / f"{key}_window.mov"))
