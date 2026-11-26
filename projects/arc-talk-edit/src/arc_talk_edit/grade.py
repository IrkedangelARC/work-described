"""Measured grades as 33^3 .cube LUTs + face power windows (ported 10/1 from an earlier one-off tool, numerics unchanged).

finish     clean Rec.709 camera (a 4K AM7 talk recording, approved by eye): WB from a measured NEUTRAL patch, black p0.5 ->
           0.025 before the S (~0.006 after it), gentle S + soft shoulder, chroma trim with neutrals kept neutral (< 1 dE).
backlight  backlit / low-light (a two-day programme in a backlit room): global LUT (black, exposure to a median target, S + glare shoulder)
           + per-face power windows (Haar faces, skin-validated, one lift per face toward a skin target), LUMINANCE-QUALIFIED
           so only tones darker than the background lift (LESSONS: an unqualified ellipse haloed the print behind the speaker).
Colour maths: display-referred Rec.709 with an sRGB-like transfer for LAB.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

import numpy as np

N = 33


# ---- cube io --------------------------------------------------------------------------------------------------------
def read_cube(p) -> np.ndarray:
    rows, size = [], None
    for ln in open(p):
        t = ln.strip().split()
        if not t or t[0].startswith("#"):
            continue
        if t[0] == "LUT_3D_SIZE":
            size = int(t[1])
        elif t[0][0] in "-0123456789." and len(t) == 3:
            rows.append([float(v) for v in t])
    return np.array(rows).reshape(size, size, size, 3)        # file order: R fastest -> index [b, g, r]


def write_cube(p, lut: np.ndarray, title: str):
    n = lut.shape[0]
    with open(p, "w") as f:
        f.write(f'TITLE "{title}"\nLUT_3D_SIZE {n}\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n')
        for b in range(n):
            for g in range(n):
                for r in range(n):
                    f.write("%.6f %.6f %.6f\n" % tuple(lut[b, g, r]))


def grid(n=N) -> np.ndarray:
    v = np.linspace(0, 1, n)
    b, g, r = np.meshgrid(v, v, v, indexing="ij")
    return np.stack([r, g, b], -1)                            # [b, g, r, (r,g,b)]


def apply(lut, img):
    """Trilinear lookup of float RGB img (0..1) through lut."""
    n = lut.shape[0]; x = img * (n - 1)
    i0 = np.clip(np.floor(x).astype(int), 0, n - 2); f = x - i0
    r0, g0, b0 = i0[..., 0], i0[..., 1], i0[..., 2]; fr, fg, fb = f[..., 0:1], f[..., 1:2], f[..., 2:3]
    c = lambda db, dg, dr: lut[b0 + db, g0 + dg, r0 + dr]
    c00 = c(0, 0, 0) * (1 - fr) + c(0, 0, 1) * fr; c01 = c(0, 1, 0) * (1 - fr) + c(0, 1, 1) * fr
    c10 = c(1, 0, 0) * (1 - fr) + c(1, 0, 1) * fr; c11 = c(1, 1, 0) * (1 - fr) + c(1, 1, 1) * fr
    return (c00 * (1 - fg) + c01 * fg) * (1 - fb) + (c10 * (1 - fg) + c11 * fg) * fb


# ---- colour maths ---------------------------------------------------------------------------------------------------
def to_lin(x): return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)
def to_enc(x): return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.clip(x, 0, None) ** (1 / 2.4) - 0.055)
M = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]]); MI = np.linalg.inv(M)
WP = M @ np.ones(3)


def rgb2lab(rgb):
    xyz = to_lin(np.clip(rgb, 0, 1)) @ M.T / WP
    f = np.where(xyz > 216 / 24389, np.cbrt(xyz), (24389 / 27 * xyz + 16) / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def lab2rgb(lab):
    fy = (lab[..., 0] + 16) / 116; fx = fy + lab[..., 1] / 500; fz = fy - lab[..., 2] / 200
    inv = lambda t: np.where(t ** 3 > 216 / 24389, t ** 3, (116 * t - 16) / (24389 / 27))
    xyz = np.stack([inv(fx), inv(fy), inv(fz)], -1) * WP
    return np.clip(to_enc(xyz @ MI.T), 0, 1)


def skin_weight(lab):
    """1 on skin (hue ~ 35-75 deg in a*b*, moderate chroma), 0 on neutrals and other hues; soft edges."""
    h = np.degrees(np.arctan2(lab[..., 2], lab[..., 1])); c = np.hypot(lab[..., 1], lab[..., 2])
    wh = np.exp(-0.5 * ((h - 55) / 16) ** 2)
    wc = np.clip((c - 6) / 10, 0, 1) * np.clip((60 - c) / 15, 0, 1)
    wl = np.clip((lab[..., 0] - 30) / 15, 0, 1)                  # dark brown hair (L* < 30) is not skin
    return wh * wc * wl


def luma(rgb): return rgb @ np.array([0.2126, 0.7152, 0.0722])


def tone(rgb, curve):
    """Additive luma shift (a ratio also multiplies chroma; the lifted toe turned dark hair red, 10/1)."""
    y = luma(rgb)[..., None]
    return np.clip(rgb + (curve(y) - y), 0, 1)


def shoulder(y, knee=0.78, top=0.97):
    over = np.clip(y - knee, 0, None); span = 1 - knee
    return np.where(y > knee, knee + (top - knee) * np.tanh(over / span * 1.6) / np.tanh(1.6), y)


def finish_curve(y, black, knee=0.80, top=0.985, contrast=1.12, pivot=0.42):
    """black -> 0.025 (then the S takes it to ~0.006), gentle S around the pivot, soft shoulder so hot skin/screens roll off."""
    x = np.clip((y - black) / (1 - black), 0, 1) * 0.975 + 0.025
    x = pivot + (x - pivot) * contrast - 0.06 * (x - pivot) ** 3 / 0.3 ** 2 * (contrast - 1)
    return shoulder(np.clip(x, 0, 1), knee, top)


# ---- frames ---------------------------------------------------------------------------------------------------------
def frame(src, t) -> np.ndarray:
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", str(t), "-i", str(src), "-frames:v", "1", "-vf", "scale=1920:1080",
                          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(1080, 1920, 3) / 255.0


def black_point(src, fracs=(0.2, 0.4, 0.6, 0.8)) -> float:
    """Median of p0.5 luma over frames spread across the source."""
    dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(src)],
                               capture_output=True, text=True).stdout)
    return float(np.median([np.percentile(luma(frame(src, dur * f).reshape(-1, 3)), 0.5) for f in fracs]))


# ---- finish ---------------------------------------------------------------------------------------------------------
def neutral_wb(img, box):
    """(r, g, b) mean of the brightest 60 % of UNCLIPPED pixels in a neutral patch box=(x0, y0, x1, y1)."""
    x0, y0, x1, y1 = box
    a = img[y0:y1, x0:x1].reshape(-1, 3); ok = a[a.max(1) < 245 / 255]
    return tuple(ok[ok.sum(1) > np.percentile(ok.sum(1), 40)].mean(0))


def finish_lut(wb, black, chroma=0.93, n=N):
    """Pure: the finish LUT from a measured neutral (r, g, b) and black point."""
    r, g, b = wb
    x = np.clip(grid(n) * np.array([g / r, 1.0, g / b]), 0, 1)
    x = tone(x, lambda y: finish_curve(y, black))
    lab = rgb2lab(x); c = np.hypot(lab[..., 1], lab[..., 2])[..., None]
    lab[..., 1:] *= 1 - (1 - chroma) * np.clip((c - 4) / 8, 0, 1)       # neutrals stay exactly neutral
    return lab2rgb(lab)


def partial_wb(wb, strength: float):
    """Move only `strength` (0..1) of the way to neutral: for a "neutral" patch that is not lit by the room's key light
    (JOB-0000: the white wall under the projection screens is lit bluish by them; correcting it fully turned the whole
    room yellow, 40 % looked right)."""
    r, g, b = wb
    return (g * (r / g) ** strength, g, g * (b / g) ** strength)


def finish(src, t, box, out_cube, chroma=0.93, title="finish", wb_strength=1.0):
    img = frame(src, t); wb = neutral_wb(img, box); blk = black_point(src)
    r, g, b = wb
    lut = finish_lut(partial_wb(wb, wb_strength), blk, chroma)
    Path(out_cube).parent.mkdir(parents=True, exist_ok=True)
    write_cube(out_cube, lut, f"{title}: R/G {r / g:.3f} B/G {b / g:.3f} wb_strength {wb_strength} black {blk:.3f} chroma {chroma}")
    return dict(r_g=round(r / g, 3), b_g=round(b / g, 3), wb_strength=wb_strength, black=round(blk, 3), lut=str(out_cube))


# ---- backlight + power windows --------------------------------------------------------------------------------------
def faces(img):
    """Face boxes (x, y, w, h) in a 1920x1080 float frame: OpenCV frontal Haar cascade, largest first."""
    import cv2
    g = (img.mean(2) * 255).astype(np.uint8)
    det = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
    f = det.detectMultiScale(g, scaleFactor=1.08, minNeighbors=6, minSize=(36, 36))
    return sorted([tuple(int(v) for v in b) for b in f], key=lambda b: -b[2] * b[3])


def core(im, b):
    """Central half of a face box (skin sample)."""
    return im[b[1] + b[3] // 4:b[1] + 3 * b[3] // 4, b[0] + b[2] // 4:b[0] + 3 * b[2] // 4].reshape(-1, 3)


def skin_faces(img, boxes, min_skin=0.12):
    """Drop non-skin false detections."""
    return [b for b in boxes if skin_weight(rgb2lab(core(img, b))).mean() > min_skin]


def window_mask(shape, boxes, grow=(1.45, 2.2), drop=0.5, feather=0.45):
    """Soft power window: one feathered ellipse per face, head + shoulders (centre dropped below the face)."""
    h, w = shape[:2]; yy, xx = np.mgrid[0:h, 0:w]; m = np.zeros((h, w))
    for x, y, bw, bh in boxes:
        cx, cy, rx, ry = x + bw / 2, y + bh / 2 + drop * bh, grow[0] * bw, grow[1] * bh
        d = np.sqrt(((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2)
        m = np.maximum(m, np.clip((1 + feather - d) / feather, 0, 1) ** 2 * (3 - 2 * np.clip((1 + feather - d) / feather, 0, 1)))
    return m[..., None]


def backlight_lut(black, median, mid_target=0.40, n=N):
    """Pure: global backlight LUT. Returns (lut, stops)."""
    stops = float(np.clip(np.log2(mid_target / max(median, 1e-3)) * 1.2, 0, 1.5))
    x = np.clip((grid(n) - black) / (1 - black), 0, 1)
    x = to_enc(to_lin(x) * 2 ** stops)
    x = tone(np.clip(x, 0, 1), lambda yy: finish_curve(yy, 0.0, knee=0.72, top=0.97, contrast=1.10, pivot=0.45))
    lab = rgb2lab(x); c = np.hypot(lab[..., 1], lab[..., 2])[..., None]; lab[..., 1:] *= 1 - 0.05 * np.clip((c - 4) / 8, 0, 1)
    return lab2rgb(lab), stops


def lift_for(skin_luma, skin_target=0.58, max_lift=1.2):
    return float(np.clip(np.log2(skin_target / max(skin_luma, 1e-3)), 0, max_lift))


def apply_windows(g1, boxes, lifts, skins, by_lift=True):
    """Pure: luminance-qualified power windows on a globally graded frame. boxes (x, y, w, h); one lift + skin per face.
    by_lift: stills composite smallest lift first (looks.backlight); the video renderer composites in track order."""
    g2 = g1.copy(); yl = luma(g1)[..., None]
    z = list(zip(boxes, lifts, skins))
    for b, lf, sk in (sorted(z, key=lambda v: v[1]) if by_lift else z):
        if lf <= 0.05:
            continue
        q = np.clip((yl - (sk + 0.12)) / 0.18, 0, 1); q = 1 - q * q * (3 - 2 * q)      # only tones darker than background
        m = window_mask(g1.shape, [b]) * q
        boosted = tone(np.clip(to_enc(to_lin(g1) * 2 ** lf), 0, 1), lambda yy: shoulder(yy, 0.80, 0.98))
        g2 = g2 * (1 - m) + np.maximum(g2, boosted) * m
    return np.clip(g2, 0, 1)


def backlight(src, t, out_dir, key, mid_target=0.40, skin_target=0.58, max_lift=1.2):
    """Measure one frame -> <out_dir>/<key>_backlight_global.cube + <key>_backlight.png (raw | global | windows)."""
    img = frame(src, t); y = luma(img.reshape(-1, 3)); blk = float(np.percentile(y, 0.5)); med = float(np.median(y))
    lut, stops = backlight_lut(blk, med, mid_target)
    out = Path(out_dir); out.mkdir(parents=True, exist_ok=True)
    cube = out / f"{key}_backlight_global.cube"
    write_cube(cube, lut, f"{key} backlight global: black {blk:.3f} +{stops:.2f} stops")
    g1 = apply(lut, img); fb = skin_faces(img, faces(img))
    skin = [float(np.median(luma(core(g1, b)))) for b in fb]
    lifts = [lift_for(v, skin_target, max_lift) for v in skin]
    g2 = apply_windows(g1, fb, lifts, skin)
    try:
        from PIL import Image
        row = np.concatenate([im[::2, ::2] for im in (img, g1, g2)], 1)
        Image.fromarray((row * 255).astype(np.uint8)).save(out / f"{key}_backlight.png")
    except ImportError:
        pass
    return dict(lut=str(cube), black=round(blk, 3), median=round(med, 3), global_stops=round(stops, 2), faces=len(fb),
                window_stops=[round(v, 2) for v in lifts],
                skin_final=[round(float(np.median(luma(core(g2, b)))), 3) for b in fb])


def darken(lut: np.ndarray, stops: float, shoulder: float = 0.75) -> np.ndarray:
    """A finish LUT followed by an exposure pull of `stops` (negative = darker), in linear light, with the highlights
    eased into the reduced range (soft shoulder from `shoulder` of the new peak) so white walls and screens come down
    without banding (Room B 10/3: the video needed to be darkened)."""
    def to_lin(v):
        return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)

    def to_gam(v):
        return np.where(v <= 0.0031308, v * 12.92, 1.055 * np.clip(v, 0, None) ** (1 / 2.4) - 0.055)
    g = 2.0 ** stops
    out = to_gam(np.clip(to_lin(np.clip(lut, 0, 1)) * g, 0, 1))
    top = float(to_gam(np.array(g)))                       # where 1.0 lands: keep a soft roll into it
    k = shoulder * top
    over = out > k
    out = np.where(over, k + (top - k) * np.tanh((out - k) / max(top - k, 1e-6)), out)
    return np.clip(out, 0, 1)


def darken_mids(lut: np.ndarray, stops: float, white: float = 0.92) -> np.ndarray:
    """Darken faces and midtones by `stops` but keep whites near white (`white` of full scale): a tone curve through
    (0, 0), (0.18 linear -> 0.18 * 2**stops) and (1 -> white), applied after the finish LUT. For over-exposed rooms
    where a straight exposure pull turns clipped walls and screens flat grey (Room B 10/4)."""
    def to_lin(v):
        return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)

    def to_gam(v):
        return np.where(v <= 0.0031308, v * 12.92, 1.055 * np.clip(v, 0, None) ** (1 / 2.4) - 0.055)
    w_lin = float(to_lin(np.array(white)))
    # power curve y = w_lin * x**p with 0.18 -> 0.18 * 2**stops
    p = np.log(0.18 * 2.0 ** stops / w_lin) / np.log(0.18)
    return np.clip(to_gam(w_lin * np.clip(to_lin(np.clip(lut, 0, 1)), 0, 1) ** p), 0, 1)
