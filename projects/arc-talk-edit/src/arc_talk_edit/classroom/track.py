"""Where the presenter is and who is on stage (media -> JSON; no decisions here, framing.py decides).

colour track   The presenter's clothing colour (job: classroom.subject.colour, OpenCV HSV, hue may wrap) inside each
               presenter camera's stage band, 2 fps: [t, cx, top, w, h, edge_cut] as frame fractions (None when not found).
               On JOB-0000 the subject colour was found 97 % (tight) / 88 % (wide) of the talk, 56 s for 81 min x 2 cameras.
people         torchvision Faster R-CNN MobileNet-v3 FPN, COCO person, every 2 s: [t, [[x0, y0, x1, y1, score], ...]].
               CPU, one model per worker process (R-CNN on MPS ran > 10 s per frame, 10/3). Raw boxes: the stage-floor
               filter is framing.on_stage(), so a filter change needs no re-detection.
pose           Keypoint R-CNN: people with their wrists. Tight camera over the whole program (hands for framing), both
               cameras at the track rate where the colour track is not valid (who to follow, by continuity).
valid windows  When the colour track can be trusted: classroom.subject.valid, or measured (colour_valid) when absent.
               The tight camera only runs the person detector outside them (JOB-0000: the opening, before the colour is on stage).

All times are on the program clock; each source is read at job.convert(t, program_clock, source.clock).
"""
from __future__ import annotations
import subprocess
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
import numpy as np

CHUNK_S = 60.0


def frames(path, t: float, dur: float, fps: float, size) -> np.ndarray:
    """BGR frames (n, h, w, 3) from source time t for dur seconds at fps (first frame at t)."""
    w, h = size
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{t:.3f}", "-i", str(path), "-t", str(dur), "-vf",
                          f"fps={fps},scale={w}:{h}", "-pix_fmt", "bgr24", "-f", "rawvideo", "-"],
                         capture_output=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(-1, h, w, 3)


def run_chunks(fn, jobs: list, workers: int, label: str, procs: bool = False, every_s: float = 60.0, media: bool = True) -> list:
    """fn over jobs (one per CHUNK_S of media) in a pool, results in job order, with a progress line at most every
    `every_s` and at the end: "[label] 12/84 chunks (14 %), 12.0 min of media in 2.1 min, ETA 12.5 min" (10/3: a
    30 min pose pass gave no sign of life)."""
    import multiprocessing as mp, sys, time
    from concurrent.futures import as_completed
    if not jobs:
        return []
    t0 = last = time.time(); done = 0; out = [None] * len(jobs)
    pool = ProcessPoolExecutor(workers, mp_context=mp.get_context("spawn")) if procs else ThreadPoolExecutor(workers)
    with pool as ex:
        futs = {ex.submit(fn, j): i for i, j in enumerate(jobs)}
        for f in as_completed(futs):
            out[futs[f]] = f.result(); done += 1
            now = time.time()
            if now - last >= every_s or done == len(jobs):
                el = now - t0; eta = el / done * (len(jobs) - done)
                what = f"{done * CHUNK_S / 60:.1f} min of media" if media else f"{done} done"
                print(f"[{label}] {done}/{len(jobs)} ({100 * done // len(jobs)} %), {what} in {el / 60:.1f} min, "
                      f"ETA {eta / 60:.1f} min", file=sys.stderr, flush=True)
                last = now
    return out


def chunks(t0: float, t1: float):
    return [(float(a), float(min(CHUNK_S, t1 - a))) for a in np.arange(t0, t1, CHUNK_S)]


# ---- colour track ---------------------------------------------------------------------------------------------------
def colour_mask(img_bgr: np.ndarray, colour: dict) -> np.ndarray:
    import cv2
    hsv = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2HSV)
    lo, hi = colour["hue"]
    hue = (hsv[..., 0] >= lo) & (hsv[..., 0] <= hi) if lo <= hi else (hsv[..., 0] >= lo) | (hsv[..., 0] <= hi)
    return (hue & (hsv[..., 1] > colour.get("sat_min", 110)) & (hsv[..., 2] > colour.get("val_min", 50))).astype(np.uint8)


def colour_blob(img_bgr: np.ndarray, colour: dict, band, min_area: int = 25):
    """Largest blob of the subject colour inside the stage band (rows band[0]..band[1] of the frame height):
    [cx, top, w, h, edge_cut] as frame fractions, or None."""
    import cv2
    H, W = img_bgr.shape[:2]
    m = colour_mask(img_bgr, colour)
    m[:int(band[0] * H)] = 0; m[int(band[1] * H):] = 0
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    n, _, st, _ = cv2.connectedComponentsWithStats(m)
    if n <= 1:
        return None
    i = 1 + int(np.argmax(st[1:, cv2.CC_STAT_AREA]))
    x, y, w, h, a = (int(v) for v in st[i])
    if a < min_area:
        return None
    return [round((x + w / 2) / W, 4), round(y / H, 4), round(w / W, 4), round(h / H, 4), bool(x <= 1 or x + w >= W - 1)]


def _colour_chunk(args):
    path, t_src, t_prog, dur, fps, size, colour, band, min_area = args
    fr = frames(path, t_src, dur, fps, size)
    return [[round(t_prog + k / fps, 2), *(colour_blob(f, colour, band, min_area) or [None] * 5)] for k, f in enumerate(fr)]


def colour_track(job, c: dict) -> dict:
    """{role: [[t, cx, top, w, h, edge], ...]} for the tight and wide cameras over the program window."""
    pc = job.program_clock; t0, t1 = job.program["in"], job.program["out"]
    tk, out = c["track"], {}
    for role in ("tight", "wide"):
        cam = c["cameras"][role]; src = job.sources[cam["source"]]
        off = job.convert(0.0, pc, src.clock)
        jobs = [(str(job.path(cam["source"])), a + off, a, d, tk["fps"], tk["size"], c["subject"]["colour"], cam["band"],
                 tk["min_area"]) for a, d in chunks(t0, t1)]
        out[role] = [r for part in run_chunks(_colour_chunk, jobs, 8, f"colour {role}") for r in part]
    return out


def found(track: list, min_h: float = 0.0) -> float:
    return sum(r[1] is not None and r[4] >= min_h for r in track) / max(1, len(track))


def colour_valid(track: dict, c: dict, win_s: float = 30.0, frac: float = 0.5, gap_s: float = 30.0) -> list[list]:
    """Measured windows where the colour track is trustworthy: a plausible-size blob in either presenter camera for at
    least `frac` of a rolling `win_s`; windows closer than `gap_s` are joined. (JOB-0000: valid from the clothing change.)"""
    fps = c["track"]["fps"]
    ok = np.zeros(len(track["tight"]), bool)
    for role in ("tight", "wide"):
        mh = c["cameras"][role]["min_h"]
        ok |= np.array([r[1] is not None and r[4] >= mh for r in track[role]])
    k = max(1, int(win_s * fps))
    dens = np.convolve(ok.astype(float), np.ones(k) / k, "same") >= frac
    t = [r[0] for r in track["tight"]]
    wins, i = [], 0
    while i < len(dens):
        if dens[i]:
            j = i
            while j + 1 < len(dens) and dens[j + 1]:
                j += 1
            if wins and t[i] - wins[-1][1] < gap_s:
                wins[-1][1] = t[j]
            else:
                wins.append([t[i], t[j]])
            i = j + 1
        else:
            i += 1
    return wins


def valid_windows(job, c: dict, track: dict) -> list[list]:
    """classroom.subject.valid ([[in, out|null], ...], program clock) or the measured windows."""
    v = c["subject"].get("valid")
    if v:
        return [[a if a is not None else job.program["in"], b if b is not None else job.program["out"]] for a, b in v]
    return colour_valid(track, c)


def invalid_windows(job, valid: list[list], pad_s: float) -> list[list]:
    """Program time NOT covered by the colour track, each window extended pad_s into the valid side."""
    t0, t1 = job.program["in"], job.program["out"]
    out, a = [], t0
    for va, vb in sorted(valid):
        if va > a:
            out.append([a, min(t1, va + pad_s)])
        a = max(a, vb)
    if a < t1 - 1e-6:
        out.append([max(t0, a - pad_s), t1])
    return out


# ---- people ---------------------------------------------------------------------------------------------------------
_MODEL = None


def _model(threads: int):
    global _MODEL
    if _MODEL is None:
        import torch
        from torchvision.models.detection import fasterrcnn_mobilenet_v3_large_fpn, FasterRCNN_MobileNet_V3_Large_FPN_Weights
        torch.set_num_threads(threads)
        _MODEL = fasterrcnn_mobilenet_v3_large_fpn(weights=FasterRCNN_MobileNet_V3_Large_FPN_Weights.DEFAULT).eval()
    return _MODEL


def _people_chunk(args):
    import torch
    path, t_src, t_prog, dur, fps, size, score, threads = args
    m = _model(threads)
    fr = frames(path, t_src, dur, fps, size)
    W, H = size
    out = []
    for k in range(0, len(fr), 8):
        batch = torch.from_numpy(fr[k:k + 8][..., ::-1].copy()).permute(0, 3, 1, 2).float().div(255)
        with torch.no_grad():
            res = m(list(batch))
        for j, r in enumerate(res):
            keep = [[round(float(v), 4) for v in (*(b / np.array([W, H, W, H])), s)]
                    for b, l, s in zip(r["boxes"].numpy(), r["labels"].numpy(), r["scores"].numpy()) if l == 1 and s >= score]
            out.append([round(t_prog + (k + j) / fps, 2), keep])
    return out


def people(job, c: dict, role: str, windows: list[list] | None = None) -> list:
    """[[t, [[x0, y0, x1, y1, score], ...]], ...] for one camera role over `windows` (default: the program window)."""
    pc = job.program_clock
    cam = c["cameras"][role]; src = job.sources[cam["source"]]
    off = job.convert(0.0, pc, src.clock)
    pp = c["people"]
    windows = windows if windows is not None else [[job.program["in"], job.program["out"]]]
    workers = max(1, int(pp["workers"]))
    import os
    threads = max(1, (os.cpu_count() or 8) // workers - 1)
    jobs = [(str(job.path(cam["source"])), a + off, a, d, pp["fps"], pp["size"], pp["score"], threads)
            for w0, w1 in windows for a, d in chunks(w0, w1)]
    if not jobs:
        return []
    parts = run_chunks(_people_chunk, jobs, workers, f"people {role}", procs=workers > 1)
    return [r for part in parts for r in part]


# ---- pose: people with wrists ---------------------------------------------------------------------------------------
_POSE = None
L_WRIST, R_WRIST = 9, 10                                     # COCO keypoint order


def _pose_model(threads: int):
    global _POSE
    if _POSE is None:
        import torch
        from torchvision.models.detection import keypointrcnn_resnet50_fpn, KeypointRCNN_ResNet50_FPN_Weights
        torch.set_num_threads(threads)
        _POSE = keypointrcnn_resnet50_fpn(weights=KeypointRCNN_ResNet50_FPN_Weights.DEFAULT).eval()
    return _POSE


def _pose_chunk(args):
    import torch
    path, t_src, t_prog, dur, fps, size, score, threads = args
    m = _pose_model(threads)
    fr = frames(path, t_src, dur, fps, size)
    W, H = size
    out = []
    for k in range(0, len(fr), 4):
        batch = torch.from_numpy(fr[k:k + 4][..., ::-1].copy()).permute(0, 3, 1, 2).float().div(255)
        with torch.no_grad():
            res = m(list(batch))
        for j, r in enumerate(res):
            keep = []
            for b, s, kp, ks in zip(r["boxes"].numpy(), r["scores"].numpy(), r["keypoints"].numpy(), r["keypoints_scores"].numpy()):
                if s < score:
                    continue
                row = [float(b[0] / W), float(b[1] / H), float(b[2] / W), float(b[3] / H), float(s)]
                for i in (L_WRIST, R_WRIST):
                    row += [float(kp[i][0] / W), float(kp[i][1] / H), float(ks[i])]
                keep.append([round(v, 4) for v in row])
            out.append([round(t_prog + (k + j) / fps, 2), keep])
    return out


def pose(job, c: dict, role: str, windows: list) -> list:
    """Keypoint R-CNN (ResNet-50 FPN, COCO): [[t, [[x0, y0, x1, y1, score, lwx, lwy, lws, rwx, rwy, rws], ...]], ...]
    for one camera over windows [[in, out, fps], ...]. Boxes and wrists are frame fractions; a wrist score > 0 is a
    confident wrist. It finds the wrists of a presenter in white against a white wall (where the empty-room
    difference finds nothing), 0.34 s per frame on 8 threads."""
    import multiprocessing as mp, os
    pc = job.program_clock
    cam = c["cameras"][role]; src = job.sources[cam["source"]]
    off = job.convert(0.0, pc, src.clock)
    pp = c["pose"]
    workers = max(1, int(pp["workers"]))
    threads = max(1, (os.cpu_count() or 8) // workers - 1)
    jobs = [(str(job.path(cam["source"])), a + off, a, d, fps, pp["size"], pp["score"], threads)
            for w0, w1, fps in windows for a, d in chunks(w0, w1)]
    if not jobs:
        return []
    parts = run_chunks(_pose_chunk, jobs, workers, f"pose {role}", procs=workers > 1)
    return sorted((r for part in parts for r in part), key=lambda r: r[0])


# ---- slides ---------------------------------------------------------------------------------------------------------
def _slide_chunk(args):
    path, t_src, t_prog, dur, fps = args
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{t_src:.3f}", "-i", str(path), "-t", str(dur), "-vf",
                          f"fps={fps},scale=96:54,format=gray", "-f", "rawvideo", "-"], capture_output=True).stdout
    v = np.frombuffer(raw, np.uint8).reshape(-1, 54, 96).astype(np.float32)
    return [[round(t_prog + k / fps, 2), round(float(f.mean()), 1), round(float(f.std()), 2)] for k, f in enumerate(v)]


def slide_stats(job, c: dict) -> list:
    """[[t, mean, std, blank], ...] for the slide feed over the program at the track rate (program clock)."""
    key = c["slides"]; off = job.convert(0.0, job.program_clock, job.sources[key].clock)
    fps = c["track"]["fps"]
    jobs = [(str(job.path(key)), a + off, a, d, fps) for a, d in chunks(job.program["in"], job.program["out"])]
    rows = [r for part in run_chunks(_slide_chunk, jobs, 8, "slides") for r in part]
    return [[t, m, sd, sd < c["blank"]["std_max"]] for t, m, sd in rows]
