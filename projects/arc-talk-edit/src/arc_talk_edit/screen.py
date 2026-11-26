"""Screen-feed map (P1.5 port of JOB-0000 screen_map.py): content segments, content/motion boxes, 16:9 zoom rect, PiP
corner scored by the content it would cover. Logic identical to the legacy tool; every constant is a parameter
(job.yaml `scans.screen`). The JOB-0000 narrative|pane SPLIT layout is the optional `split_x` setting.
Coordinates are in the 960x540 decode (x2 for 1080p)."""
from __future__ import annotations
import subprocess
from pathlib import Path
import numpy as np

W, H = 960, 540


def decode(path, out: Path, fps: int = 2) -> Path:
    """2 fps 960x540 grey decode (cached); the JOB-0000 cache was decoded WITH the AJA clean-aperture crop."""
    if out.exists() and out.stat().st_size > 0:
        return out
    tmp = out.with_suffix(".part")
    with open(tmp, "wb") as fh:
        subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-vf",
                        f"fps={fps},setparams=color_primaries=bt709:color_trc=bt709,scale={W}:{H},format=gray",
                        "-f", "rawvideo", "-"], stdout=fh, check=True)
    tmp.rename(out)
    return out


def screen_map(gray: Path, top=34, bot=503, pane_top=80, split_x=(385, 392), thresh=4.0, min_seg=2.0,
               pip=(240, 135), margin=8, max_zoom=2.0, fps=2) -> list[dict]:
    TOP, BOT, PANE_TOP, THRESH, MIN_SEG, FPS, MAX_ZOOM, M = top, bot, pane_top, thresh, min_seg, fps, max_zoom, margin
    PIP_W, PIP_H = pip
    SPLIT_X0, SPLIT_X1 = split_x if split_x else (None, None)
    f = np.memmap(gray, np.uint8, "r").reshape(-1, H, W)
    N = len(f)
    small = f[:, TOP:BOT:4, ::4].astype(np.int16)


    # --- segments against a reference frame (catches slow scrolls that frame-diff misses)
    cuts, ref = [0], small[0]
    i = 1
    while i < N:
        if np.abs(small[i] - ref).mean() > THRESH:
            # confirm it stays changed for 1 s (ignore a cursor pass or a flash)
            j = min(i + FPS, N - 1)
            if np.abs(small[j] - ref).mean() > THRESH:
                cuts.append(i); ref = small[j]; i = j + 1; continue
        i += 1
    segs = []
    for a, b in zip(cuts, cuts[1:] + [N]):
        if (b - a) / FPS < MIN_SEG and segs:
            segs[-1][1] = b; continue
        segs.append([a, b])


    def bbox(mask, x0=0, y0=0):
        ys, xs = np.nonzero(mask)
        if len(xs) < 20: return None
        return [int(x0 + np.percentile(xs, 0.5)), int(y0 + np.percentile(ys, 0.5)),
                int(x0 + np.percentile(xs, 99.5)), int(y0 + np.percentile(ys, 99.5))]


    def fit169(b, pad=12):
        x0, y0, x1, y1 = b[0] - pad, b[1] - pad, b[2] + pad, b[3] + pad
        w, h = x1 - x0, y1 - y0
        if w / h > 16 / 9: h = w * 9 / 16
        else: w = h * 16 / 9
        w = max(w, W / MAX_ZOOM); h = w * 9 / 16
        cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
        x0 = min(max(cx - w / 2, 0), W - w); y0 = min(max(cy - h / 2, 0), H - h)
        return [round(x0), round(y0), round(x0 + w), round(y0 + h)], round(W / w, 2)


    out = []
    for a, b in segs:
        fr = np.median(f[a:b:max(1, (b - a) // 15)], axis=0)
        content = fr.copy(); content[:TOP] = 255; content[BOT:] = 255
        bg = np.median(content[TOP:BOT])
        # SPLIT = the gutter between narrative column and pane is ink-free (pane border optional)
        split = bool(SPLIT_X0) and float((np.abs(fr[60:480, SPLIT_X0 - 2:SPLIT_X1] - bg) > 30).mean()) < 0.005
        ink = np.abs(content - bg) > 25                         # anything not background
        dark = content < 110                                    # active text / strong content
        motion = (f[a:b].max(axis=0).astype(int) - f[a:b].min(axis=0)) > 40
        motion[:TOP] = False; motion[BOT:] = False
        if split: motion[:, :SPLIT_X1] = False   # scroll of the narrative column is not demo motion
        s = {"aja_in": a / FPS, "aja_out": b / FPS, "dur": (b - a) / FPS,
             "layout": "SPLIT" if split else "FULL", "mean_luma": round(float(fr[TOP:BOT].mean()), 1)}
        if split:
            act = dark[TOP:BOT, 15:SPLIT_X0].any(axis=1)
            ys = np.nonzero(act)[0]
            s["active_y"] = [int(TOP + ys.min()), int(TOP + ys.max())] if len(ys) else None
            # strong content only (faint borders, pane header and progress rule excluded)
            strong = np.abs(content - bg) > 60
            s["pane_bbox"] = bbox(strong[PANE_TOP:BOT, SPLIT_X1 + 8:W - 20], SPLIT_X1 + 8, PANE_TOP)
        else:
            s["active_y"] = None
            s["pane_bbox"] = bbox((np.abs(content - bg) > 60)[TOP:BOT, :], 0, TOP)
        s["motion_bbox"] = bbox(motion)
        if s["pane_bbox"]:
            s["zoom_rect"], s["zoom"] = fit169(s["pane_bbox"])
        # PiP: fixed size, slide it over a grid, cost = strong content covered
        cost = dark.astype(float) + 0.5 * ink
        if split:   # faded narrative text is free to cover; the active paragraph is not
            cost[:, :SPLIT_X0] = 0
            if s["active_y"]: cost[s["active_y"][0] - 6:s["active_y"][1] + 6, 15:SPLIT_X0] = 3
        cost[:TOP] = 9; cost[BOT:] = 9
        ii = cost.cumsum(0).cumsum(1)
        best = None
        for y in range(TOP + M, BOT - M - PIP_H + 1, 4):
            for x in range(M, W - M - PIP_W + 1, 4):
                c = ii[y + PIP_H - 1, x + PIP_W - 1] - ii[y - 1, x + PIP_W - 1] - ii[y + PIP_H - 1, x - 1] + ii[y - 1, x - 1]
                if best is None or c < best[0] - 1e-6: best = (c, x, y)
        c, x, y = best
        s["pip"] = [x, y, x + PIP_W, y + PIP_H]
        s["pip_cover"] = round(float(c) / (PIP_W * PIP_H), 4)
        out.append(s)
    return out
