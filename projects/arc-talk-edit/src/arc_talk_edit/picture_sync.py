"""Picture sync between sources that see the same action (first use JOB-0000: a Pearl recorder delays each input's
embedded audio differently, so audio xcorr alone cannot be trusted for the picture).

Per source: motion energy per frame (mean |frame difference| on a 64x36 grey), cross-correlated with the reference over
several windows. Same convention as sync.py: offset = t_ref - t_other, compared with the job's clocks.
Use it on CAMERAS. For a laptop / slide feed, sync by the feed's own embedded audio instead: the projected image a camera
sees is later than the feed by the projector's latency (JOB-0000: 159 ms, heard as laptop video out of sync with its sound).
"""
from __future__ import annotations
import subprocess
import numpy as np

W, H = 64, 36


def energy(path, t0: float, dur: float, fps: float, crop: str | None = None) -> np.ndarray:
    vf = (f"crop={crop}," if crop else "") + f"scale={W}:{H},format=gray"
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", str(t0), "-i", str(path), "-t", str(dur), "-vf", vf, "-r", str(fps),
                          "-f", "rawvideo", "-"], capture_output=True).stdout
    f = np.frombuffer(raw, np.uint8).reshape(-1, H, W).astype(np.float32)
    e = np.abs(np.diff(f, axis=0)).mean(axis=(1, 2))
    return (e - e.mean()) / (e.std() + 1e-9)


def lag(a: np.ndarray, b: np.ndarray, maxlag: int) -> tuple[int, float]:
    """(L, r): b best matches a when read L frames later in a (an event is L frames EARLIER in b), r = correlation."""
    n = min(len(a), len(b)); a, b = a[:n], b[:n]
    sc = {k: float(np.dot(a[max(0, k):n + min(0, k)], b[max(0, -k):n - max(0, k)]) / (n - abs(k))) for k in range(-maxlag, maxlag + 1)}
    best = max(sc, key=sc.get)
    return best, sc[best]


def run(job, ref: str, keys: list[str], at: list[float], dur: float = 300.0, max_s: float = 3.0) -> list[dict]:
    """For each source key: per-window offsets (s), their median and spread, and the job's expected offset."""
    fps = job.f; rclock = job.sources[ref].clock
    eref = {t: energy(job.path(ref), t, dur, fps) for t in at}
    out = []
    for k in keys:
        rows = []
        for t in at:
            L, r = lag(eref[t], energy(job.path(k), t, dur, fps), int(max_s * fps))
            rows.append({"at": t, "offset_s": round(L / fps, 4), "r": round(r, 2)})
        good = [x["offset_s"] for x in rows if x["r"] >= 0.3]
        exp = job.offsets.get(job.sources[k].clock, 0) - job.offsets.get(rclock, 0)
        med = float(np.median(good)) if good else None
        out.append({"source": k, "windows": rows, "offset_s": med, "spread_s": round(max(good) - min(good), 4) if good else None,
                    "expected_s": round(exp, 4), "error_frames": None if med is None else round((med - exp) * fps, 1)})
    return out
