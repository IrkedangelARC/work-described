"""Reframe (JOB-0000, 2026-10-21): virtual camera moves inside a locked 4K wide, rendered to 1080p.

The operator's rules: subtle push-ins/outs and pans, no cuts to singles on multi-person shots (every 2x single caught a
neighbour), headroom 3/4 to 1 head height above the top of the head, 1080p delivery (crops <= 2x stay native).
Faces: Haar on graded 1080 frames at `fps`, missing samples interpolated, heavily smoothed. Head top / height are estimated
from the face box (Haar boxes run brow to chin; hair adds ~0.3 h). Moves are keyframed on transcript turns: pull out
when a question starts, ease in over the answer; optional pan bias toward the active speaker (lav dominance).
"""
from __future__ import annotations
import subprocess
from pathlib import Path
import numpy as np
from . import grade as G

W4, H4 = 3840, 2160


def ffmpeg_graded(src, cube, t0: float, dur: float, w: int, h: int, fps: float | None = None):
    """ffmpeg reading the HLG source through the clip LUT, yielding rgb48 frames at w x h (generator of uint16 arrays)."""
    vf = (f"scale={w}:{h}:flags=lanczos:in_color_matrix=bt2020:in_range=tv:out_range=pc,format=gbrp16le,"
          f"lut3d='{cube}':interp=tetrahedral,format=rgb48le") + (f",fps={fps}" if fps else "")
    p = subprocess.Popen(["ffmpeg", "-v", "error", "-ss", f"{t0:.3f}", "-t", f"{dur:.3f}", "-i", str(src), "-vf", vf,
                          "-f", "rawvideo", "-"], stdout=subprocess.PIPE)
    n = w * h * 3 * 2
    while True:
        b = p.stdout.read(n)
        if len(b) < n:
            break
        yield np.frombuffer(b, np.uint16).reshape(h, w, 3)
    p.wait()


def face_track(src, cube, t0, dur, fps=4.0, max_people=3):
    """Per-sample face boxes (1080 space) -> list of tracks [(t, x, y, w, h)], tracks ordered left to right."""
    samples = []
    for i, f in enumerate(ffmpeg_graded(src, cube, t0, dur, 1920, 1080, fps)):
        img = f / 65535.0
        samples.append((i / fps, faces_any(img)[:max_people]))
    # people = clusters of face centre x across samples
    xs = np.array([b[0] + b[2] / 2 for _, bs in samples for b in bs])
    if not len(xs):
        return []
    k = int(np.median([len(bs) for _, bs in samples]) or 1)
    cent = np.percentile(xs, np.linspace(10, 90, k)) if k > 1 else np.array([np.median(xs)])
    for _ in range(10):                                                    # 1-D k-means
        lab = np.argmin(np.abs(xs[:, None] - cent[None]), 1)
        cent = np.array([xs[lab == j].mean() if (lab == j).any() else cent[j] for j in range(k)])
    tracks = []
    for j in np.argsort(cent):
        pts = [(t, *b) for t, bs in samples for b in bs if np.argmin(np.abs(b[0] + b[2] / 2 - cent)) == j]
        tracks.append(np.array(pts, float))
    return tracks


def faces_any(img):
    """Frontal + profile (both directions) Haar faces, skin-validated, overlaps merged (10/21: C0121's guest stands in
    profile and the frontal cascade alone found only the interviewer)."""
    import cv2
    g = (img.mean(2) * 255).astype(np.uint8)
    prof = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_profileface.xml")
    boxes = list(G.faces(img))
    for flip in (False, True):
        gg = g[:, ::-1] if flip else g
        for x, y, w, h in prof.detectMultiScale(gg, scaleFactor=1.08, minNeighbors=6, minSize=(36, 36)):
            boxes.append((int(g.shape[1] - x - w) if flip else int(x), int(y), int(w), int(h)))
    boxes = sorted(G.skin_faces(img, boxes), key=lambda b: -b[2] * b[3])
    keep = []
    for b in boxes:
        cx, cy = b[0] + b[2] / 2, b[1] + b[3] / 2
        if all(abs(cx - (k[0] + k[2] / 2)) > 0.6 * k[2] or abs(cy - (k[1] + k[3] / 2)) > 0.6 * k[3] for k in keep):
            keep.append(b)
    return keep


def smooth_track(tr, T, win_s=2.0):
    """Interpolate a track onto times T and smooth (moving median then mean, win_s)."""
    out = np.stack([np.interp(T, tr[:, 0], tr[:, k]) for k in range(1, 5)], 1)
    n = max(1, int(win_s / (T[1] - T[0])))
    pad = np.pad(out, ((n, n), (0, 0)), mode="edge")
    med = np.stack([np.median(pad[i:i + 2 * n + 1], 0) for i in range(len(T))])
    pad = np.pad(med, ((n, n), (0, 0)), mode="edge")
    return np.stack([pad[i:i + 2 * n + 1].mean(0) for i in range(len(T))])


def head_geom(box4):
    """(x, y, w, h) face box in 4K -> (centre x, head top y, head height)."""
    x, y, w, h = box4
    return x + w / 2, y - 0.30 * h, 1.35 * h


def ease(u):
    u = np.clip(u, 0, 1)
    return u * u * (3 - 2 * u)


def zoom_curve(T, questions, z_out, z_in, pull_s=3.0):
    """z(t): at each question start pull out to z_out over pull_s, then ease in to z_in by the next question."""
    z = np.full(len(T), z_out, float)
    starts = sorted(questions) + [T[-1] + 1]
    for a, b in zip(starts, starts[1:]):
        prev = z[np.searchsorted(T, a) - 1] if np.searchsorted(T, a) > 0 else z_out
        for i in np.where((T >= a) & (T < b))[0]:
            t = T[i] - a
            if t < pull_s:
                z[i] = prev + (z_out - prev) * ease(t / pull_s)
            else:
                z[i] = z_out + (z_in - z_out) * ease((t - pull_s) / max(b - a - pull_s, 1e-3))
    return z


def frame_rects(T, heads, zoom, focus_x=None, headroom=0.85, aspect=16 / 9):
    """Crop rect (x0, y0, w, h) in 4K per time. heads: list of (cx, top, hh) arrays per person (len T each).
    Vertical: frame top = highest head top - headroom * that head's height. Horizontal: group centre, or focus_x."""
    cx = np.mean([h[:, 0] for h in heads], 0) if focus_x is None else focus_x
    top_i = np.argmin(np.stack([h[:, 1] for h in heads]), 0)
    top = np.array([heads[p][i, 1] for i, p in enumerate(top_i)]); hh = np.array([heads[p][i, 2] for i, p in enumerate(top_i)])
    h = H4 / zoom; w = h * aspect
    x0 = np.clip(cx - w / 2, 0, W4 - w); y0 = np.clip(top - headroom * hh, 0, H4 - h)
    return np.stack([x0, y0, w, h], 1)


def render(src, cube, audio_src, t0, dur, jobs, fps_out="60000/1001", size=(1920, 1080), codec="prores", afade=0.0, af=None):
    """One graded 4K decode -> several reframes. jobs = [(rects, out_path)]. Per-frame subpixel crop+scale (pre-blurred
    against aliasing) with the mixed audio. codec "prores" = ProRes 422 HQ deliverable, "review" = HEVC 10-bit 40 Mb/s."""
    import cv2
    W, H = size
    vc = (["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le"] if codec == "prores" else
          ["-c:v", "hevc_videotoolbox", "-b:v", "40M", "-tag:v", "hvc1", "-profile:v", "main10", "-pix_fmt", "p010le"])
    ac = ["-c:a", "pcm_s24le"] if codec == "prores" else ["-c:a", "aac", "-b:a", "320k"]
    encs = [subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb48le", "-s", f"{W}x{H}",
                              "-r", fps_out, "-i", "-", "-ss", f"{t0:.3f}", "-t", f"{dur:.3f}", "-i", str(audio_src),
                              "-map", "0:v", "-map", "1:a", "-vf", "scale=out_color_matrix=bt709:out_range=tv", *vc,
                              *(["-af", af] if af else ["-af", f"afade=t=in:d={afade},afade=t=out:st={dur - afade:.4f}:d={afade}"] if afade else []),
                              "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", *ac, "-shortest",
                              str(out)], stdin=subprocess.PIPE) for _, out in jobs]
    for i, f in enumerate(ffmpeg_graded(src, cube, t0, dur, W4, H4)):
        for (rects, _), enc in zip(jobs, encs):
            x0, y0, w, h = rects[min(i, len(rects) - 1)]
            s = W / w
            sig = max(0.0, 0.5 * (1 / s - 1))
            img = cv2.GaussianBlur(f, (0, 0), sig) if sig > 0.05 else f
            M = np.array([[s, 0, -x0 * s], [0, s, -y0 * s]], np.float32)
            enc.stdin.write(cv2.warpAffine(img, M, (W, H), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE).tobytes())
    for enc in encs:
        enc.stdin.close(); enc.wait()
    return [out for _, out in jobs]


SEG_MODEL = Path(__file__).resolve().parent.parent / "models/selfie_multiclass_256x256.tflite"   # MediaPipe, hair class


def measured_heads(src, heads, times):
    """Real head top (hair) and height (hair top to chin) per person, median over `times`, from MediaPipe's multiclass
    selfie segmenter on a crop around each face box. 10/22: the face-box estimate (head_geom) put the top 0-130 px too
    high and the height 5-20 % too big, so 0.42 planned headroom was 0.40-0.76 real (11 of 13 over the operator's half a head).
    Returns heads with (cx, top, hh) replaced where measured; None for a person the segmenter can't find (C0120's rig)."""
    import cv2, mediapipe as mp
    from mediapipe.tasks.python import vision, BaseOptions
    seg = vision.ImageSegmenter.create_from_options(vision.ImageSegmenterOptions(
        base_options=BaseOptions(model_asset_path=str(SEG_MODEL)), output_category_mask=True))
    got = [[] for _ in heads]
    for t in times:
        f = np.frombuffer(subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{t:.3f}", "-i", str(src), "-frames:v", "1",
                                          "-vf", f"scale={W4}:{H4}", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"],
                                         capture_output=True, check=True).stdout, np.uint8).reshape(H4, W4, 3)
        for i, (cx, top, hh) in enumerate(heads):
            s = int(hh * 2.2); x0 = int(max(cx - s / 2, 0)); y0 = int(max(top - 0.6 * hh, 0))
            crop = np.ascontiguousarray(f[y0:y0 + s, x0:x0 + s])
            m = seg.segment(mp.Image(image_format=mp.ImageFormat.SRGB, data=crop)).category_mask.numpy_view()
            m = cv2.resize(m, (crop.shape[1], crop.shape[0]), interpolation=cv2.INTER_NEAREST)
            band = m[:, int(s / 2 - 0.35 * hh):int(s / 2 + 0.35 * hh)]
            head, face = np.isin(band, (1, 3)).mean(1) > 0.08, (band == 3).mean(1) > 0.08      # 1 hair, 3 face skin
            if head.any() and face.any():
                ht = y0 + int(np.argmax(head))
                got[i].append((ht, y0 + len(face) - 1 - int(np.argmax(face[::-1])) - ht))
    return [np.array([h[0], np.median([g[0] for g in v]), np.median([g[1] for g in v])]) if v else None
            for h, v in zip(heads, got)]


def planned_rects(T, heads, zoom, focus_x, headroom=0.42, aspect=16 / 9, keep=None):
    """Operator-style framing (10/21 v2): NO per-frame tracking. heads = per person (cx, top, hh) MEDIANS over the
    clip; vertical anchor = the tallest person's median head top minus headroom * head height, fixed for the clip;
    horizontal = focus_x (a planned, eased curve). v1 glued the frame to live face boxes: constant wander, and on two
    people the 'highest head' switched between them = one-frame 25 px snaps (C0117 9.6/10.5/20.7/21.0 s).
    10/21: headroom about half of 3/4-1 head (0.42). 10/22: half a head AT MOST, so heads should come from
    measured_heads (real hair top) and None entries (not a person) are skipped for the vertical anchor."""
    tall = min((h for h in heads if h is not None), key=lambda h: h[1])
    h = H4 / np.asarray(zoom, float); w = h * aspect
    x0 = focus_x - w / 2
    if keep is not None:                 # (left, right) of everyone's shoulders: a speaker lean never cuts the others
        x0 = np.clip(x0, np.minimum(keep[1] - w, keep[0]), np.maximum(keep[0], keep[1] - w))
    x0 = np.clip(x0, 0, W4 - w); y0 = np.clip(tall[1] - headroom * tall[2], 0, H4 - h)
    return np.stack([x0, y0, w, h], 1)


def eased_steps(T, keys, settle_s=4.0):
    """Piecewise-constant targets [(t, value)] joined by smoothstep ramps of settle_s (no exponential chase)."""
    keys = sorted(keys)
    out = np.full(len(T), keys[0][1], float)
    for (t, v), (_, prev) in zip(keys[1:], keys):
        u = ease((T - t) / settle_s)
        out = np.where(T >= t, prev + (v - prev) * u, out)
    return out


def map_lavs(src, cube, t0, dur, boxes, words, lavs=("TX01", "TX02"), fps=10):
    """lav -> on-screen person index from mouth-region motion while each lav is the dominant talker (C0117: 2270 vs 1081).
    boxes = median 1080-space face boxes per person. Returns {lav: person} only where the best person moves >= 1.4x the
    next (an off-screen interviewer bleeding into a guest lav maps to nobody)."""
    prev, mot = None, []
    for f in ffmpeg_graded(src, cube, t0, dur, 1920, 1080, fps):
        g = f[..., 1].astype(np.float32)
        row = [g[int(y + 0.65 * h):int(y + h), int(x + 0.25 * w):int(x + 0.75 * w)] for x, y, w, h in boxes]
        if prev is not None:
            mot.append([float(np.abs(a - b).mean()) for a, b in zip(row, prev)])
        prev = row
    mot = np.array(mot)
    spk = np.full(len(mot), "", object)
    for w in words:
        a, b = int((w["start"] - t0) * fps), int((w["end"] - t0) * fps)
        spk[max(a, 0):max(min(b, len(spk)), 0)] = w["spk"]
    out = {}
    for tx in lavs:
        sel = spk == tx
        if sel.sum() < fps * 3 or not len(boxes):
            continue
        m = mot[sel].mean(0) / np.maximum(mot[~sel & (spk != "")].mean(0), 1e-6) if (~sel & (spk != "")).any() else mot[sel].mean(0)
        order = np.argsort(m)[::-1]
        if len(m) == 1 or m[order[0]] >= 1.4 * m[order[1]]:
            out[tx] = int(order[0])
    return out
