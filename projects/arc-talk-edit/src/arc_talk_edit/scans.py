"""Scan stage (P0.5 port, LESSONS L7): screen-feed dropout ("LOSS OF VIDEO" bars) detection.

Port of JOB-0000 `dropout_scan.py`: full-rate 64x36 RGB decode; a frame is BAD when its mean abs difference to a bars-card
template frame is under a threshold; clusters = runs of bad frames with <= 30 good frames between. Reads job.yaml
`scans.dropouts: {source, template_frame, threshold}` and decodes the ORIGINAL recording (`original:` path if given).
"""
from __future__ import annotations
import json, subprocess
from pathlib import Path
import numpy as np

W, H = 64, 36


def _dec(path, seek_s=None):
    pre = ["-ss", f"{seek_s:.4f}"] if seek_s is not None else []
    return subprocess.Popen(["ffmpeg", "-v", "error", *pre, "-i", str(path), "-vf",
                             f"setparams=color_primaries=bt709:color_trc=bt709,scale={W}:{H}",
                             "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)


def dropouts(path, template_frame: int, fps: float, threshold: float = 25.0, gap: int = 31) -> dict:
    t = _dec(path, template_frame / fps)
    tmpl = np.frombuffer(t.stdout.read(W * H * 3), np.uint8).reshape(H, W, 3).astype(np.int16); t.kill()
    pr = _dec(path); bad, i = [], 0
    while True:
        b = pr.stdout.read(W * H * 3 * 600)
        if not b:
            break
        fr = np.frombuffer(b, np.uint8).reshape(-1, H, W, 3).astype(np.int16)
        dd = np.abs(fr - tmpl).mean(axis=(1, 2, 3))
        bad += [i + int(k) for k in np.nonzero(dd < threshold)[0]]
        i += len(fr)
    cl = []
    for f in bad:
        if cl and f - cl[-1][1] <= gap:
            cl[-1][1] = f; cl[-1][2] += 1
        else:
            cl.append([f, f, 1])
    return {"frames": i, "bad": bad, "clusters": cl}


def run_dropouts(job, work: Path) -> dict:
    spec = job.raw["scans"]["dropouts"]
    media = Path(job.raw.get("media_root", "")).expanduser()
    path = media / spec.get("original", job.sources[spec["source"]].path)
    out = dropouts(path, spec["template_frame"], job.f, spec.get("threshold", 25.0))
    work.mkdir(parents=True, exist_ok=True)
    (work / "dropouts.json").write_text(json.dumps(out))
    return out


def silences(path, noise_db: float = -30.0, min_s: float = 0.5) -> list[tuple[float, float]]:
    """ffmpeg silencedetect -> [(start_s, duration_s)]. Pause truth comes from audio, not Whisper gaps (LESSONS L18).
    An earlier job's lost settings were recovered 9/30: noise=-30dB d=0.5 reproduces silencedetect_raw.txt exactly (672 events)."""
    import re
    o = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-af",
                        f"silencedetect=noise={noise_db}dB:d={min_s}", "-f", "null", "-"], capture_output=True, text=True).stderr
    return [(float(e) - float(d), float(d)) for e, d in re.findall(r"silence_end: ([\d.]+) \| silence_duration: ([\d.]+)", o)]


def run_pauses(job) -> dict:
    spec = job.raw["scans"]["pauses"]
    src = job.sources[spec["source"]]
    path = Path(job.raw.get("media_root", "")).expanduser() / src.path
    ev = silences(path, spec.get("noise_db", -30.0), spec.get("min_s", 0.5))
    a, b = spec.get("scope", (0, float("inf")))
    long_ = [(s, d) for s, d in ev if a <= s <= b and d >= spec.get("pause_min_s", 2.5)]
    return {"events": len(ev), "long": len(long_), "long_total_s": round(sum(d for _, d in long_), 1)}


# ---- motion / whips / Q&A settle / faces (P1.5 ports of JOB-0000 whip_scan, qa_settle, camera_faces) ----------------
MW, MH, MFPS = 160, 90, 4
WHIP = 10.0                     # calibrated 9/30 on JOB-0000: whip bins 14-31, AM7 relock 14, tight-shot gestures <= 3.5
SETTLE_STOPPED, SETTLE_SLOWED = 2.0, 3.5


def motion_frames(path, start: float, dur: float, fps: int = MFPS) -> np.ndarray:
    """Per-frame mean abs grey difference at `fps`, 160x90 (first value = 0 for the first frame)."""
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{start:.2f}", "-t", f"{dur:.2f}", "-i", str(path), "-vf",
                          f"fps={fps},setparams=color_primaries=bt709:color_trc=bt709,scale={MW}:{MH},format=gray",
                          "-f", "rawvideo", "-"], capture_output=True).stdout
    fr = np.frombuffer(raw, np.uint8).reshape(-1, MH, MW).astype(np.float32)
    return np.r_[0, np.abs(np.diff(fr, axis=0)).mean(axis=(1, 2))] if len(fr) else np.zeros(0)


def whip_bins(path, start: float, dur: float) -> list[float]:
    """2 s motion bins (whip_scan: drop the first frame's 0, then 8-frame means)."""
    m = motion_frames(path, start, dur)[1:]
    return [float(m[i:i + 8].mean()) for i in range(0, len(m), 8)]


def settle(path, q_in: float, q_out: float, lead: float = 12.0, accept_before: float = 2.0, hold_s: float = 1.5) -> dict:
    """Audience-camera settle for a question (qa_settle): first moment from (q_in - accept_before) where motion stays under
    STOPPED (else SLOWED) for hold_s, searching from q_in - lead."""
    s0 = q_in - lead
    raw = motion_frames(path, s0, q_out - s0)
    mot = np.r_[99, raw[1:]]
    need = int(hold_s * MFPS)
    for thr, tier in ((SETTLE_STOPPED, "stopped"), (SETTLE_SLOWED, "slowed")):
        for i in range(len(mot) - need):
            t = s0 + i / MFPS
            if t >= q_in - accept_before and (mot[i:i + need] < thr).all():
                return {"settle": round(t, 2), "tier": tier}
    return {"settle": None, "tier": None}


def face_at(path, t: float, W: int = 960, H: int = 540):
    """Largest frontal (else profile) Haar face at time t -> (x, y, h) as frame fractions, or None (camera_faces)."""
    import cv2
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{t:.3f}", "-i", str(path), "-frames:v", "1", "-vf",
                          f"setparams=color_primaries=bt709:color_trc=bt709,scale={W}:{H},format=gray", "-f", "rawvideo", "-"],
                         capture_output=True).stdout
    if len(raw) < W * H:
        return None
    g = np.frombuffer(raw[:W * H], np.uint8).reshape(H, W)
    fc = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
    pc = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_profileface.xml")
    f = list(fc.detectMultiScale(g, 1.1, 5, minSize=(20, 20))) or list(pc.detectMultiScale(g, 1.1, 5, minSize=(20, 20)))
    if not f:
        return None
    x, y, w, h = max(f, key=lambda b: b[2] * b[3])
    return round((x + w / 2) / W, 3), round((y + h / 2) / H, 3), round(h / H, 3)
