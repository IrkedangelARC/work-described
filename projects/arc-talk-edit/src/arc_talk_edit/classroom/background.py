"""Silhouettes: people as the difference from the empty room (idea of 10/3: the classrooms are very similar in layout,
colour and shape, so subjects can be tracked by their contrast against the known setting).

The cameras are fixed, so the per-pixel median of frames spread over the recording IS the empty room (people move, the
room does not). Anything far from that plate inside the stage band is a person: the whole body, arms and hands included,
with no clothing colour and no detector. Pixels that change all the time anyway (projection screens, audience heads)
are found from the same sample frames and ignored (`volatile`).

Used for: the subject's extent, so framing keeps the hands in (review note: framing must be aware of the hands
and keep them in frame), and for following a person when there is no colour to track (the opening of JOB-0000,
where a 0.5 fps detector let the pan drift and lose him).
"""
from __future__ import annotations
import numpy as np


def plate(frames: np.ndarray) -> np.ndarray:
    """Empty-room plate: per-pixel median of frames (n, h, w, 3) sampled across the recording."""
    return np.median(frames, axis=0).astype(np.uint8)


def volatile(frames: np.ndarray, bg: np.ndarray, thr: int = 30, frac: float = 0.30, grow: int = 5) -> np.ndarray:
    """Mask (h, w) of pixels that differ from the plate in more than `frac` of the sample frames: screens, audience,
    anything that is not a stable room surface. A person crossing a spot covers it far less often than that."""
    import cv2
    d = np.abs(frames.astype(np.int16) - bg.astype(np.int16)).max(axis=3) > thr
    m = (d.mean(axis=0) > frac).astype(np.uint8)
    return cv2.dilate(m, np.ones((grow, grow), np.uint8)).astype(bool)


def blobs(img: np.ndarray, bg: np.ndarray, band, skip: np.ndarray | None = None, thr: int = 38, min_h: float = 0.12,
          min_area: int = 120) -> list:
    """People-sized regions of img that differ from the plate inside the stage band, largest first:
    [[x0, y0, x1, y1, area], ...] as frame fractions (area in px of the analysis frame). The plate is gain-matched to
    the frame's band median first (the wall brightness follows the slides); `skip` pixels never count."""
    import cv2
    H, W = img.shape[:2]
    r0, r1 = int(band[0] * H), int(band[1] * H)
    a = cv2.GaussianBlur(img, (5, 5), 0).astype(np.float32); b = cv2.GaussianBlur(bg, (5, 5), 0).astype(np.float32)
    gain = (np.median(a[r0:r1].sum(2)) + 3) / (np.median(b[r0:r1].sum(2)) + 3)
    m = (np.abs(a - b * gain).max(2) > thr).astype(np.uint8)
    m[:r0] = 0; m[r1:] = 0
    if skip is not None:
        m[skip] = 0
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, np.ones((9, 5), np.uint8))
    n, _, st, _ = cv2.connectedComponentsWithStats(m)
    out = []
    for i in range(1, n):
        x, y, w, h, ar = (int(v) for v in st[i])
        if h >= min_h * H and ar >= min_area:
            out.append([round(x / W, 4), round(y / H, 4), round((x + w) / W, 4), round((y + h) / H, 4), ar])
    return sorted(out, key=lambda q: -q[4])
