"""Audio QC: find where a RECORDED feed was clipped upstream, by comparing it with a clean iso of the same source.

Ported 10/1 from an earlier one-off script (numerics unchanged). LESSONS 4.x: an overdriven mixer/recorder input
is INVISIBLE to peak meters (the clipped wave is recorded at a safe level, -4.5 dBFS on one talk) but audible as crunch.

Method: align the feed (camera/recorder program audio) with an iso that carries the same voice (SQ multitrack lav), take 5 ms
peaks. Clean = the feed tracks the iso at a constant offset. Above a knee the offset falls (> DROP_DB):
  slope of feed vs iso >= 0.35 dB/dB  -> COMPRESSION (bus compressor still lets it rise; JOB-0000 0.7 dB/dB)
  pinned, < FLAT_CLIP % flat tops     -> LIMITER (gain turned down, wave shape kept)
  pinned, >= FLAT_CLIP % flat tops    -> HARD CLIP (one room feed: 60-66 % flat; clean JOB-0000 program 1 %)
A first version measured high-band energy vs level on the iso alone and found nothing, including on the flagged laugh.
"""
from __future__ import annotations

import subprocess

import numpy as np

SR, W, DROP_DB = 48000, 240, 3.0          # 5 ms frames
FLAT_CLIP = 30.0                          # % flat-topped loud frames that marks a real clip


def read(f, ss, d, ch=0):
    """Mono float samples of ONE channel. Never measure peaks on `-ac 1`: it sums identical L/R (+3 dB) (10/1 probe error)."""
    b = subprocess.run(["ffmpeg", "-v", "quiet", "-ss", f"{ss:.3f}", "-t", f"{d:.3f}", "-i", str(f), "-af",
                        f"pan=mono|c0=c{ch}", "-ar", str(SR), "-f", "f32le", "-"], capture_output=True).stdout
    return np.frombuffer(b, np.float32).astype(np.float64)


def flat_share(x, tol_db=0.05, run=4):
    """% of the loudest 10 % of 5 ms frames whose peak is a FLAT TOP (>= run samples within tol_db of it)."""
    a = np.abs(x); n = len(a) // W; fr = a[: n * W].reshape(n, W); pk = fr.max(1); loud = pk >= np.percentile(pk, 90)
    hits = 0
    for f, p in zip(fr[loud], pk[loud]):
        d = np.diff(np.concatenate([[0], (f >= p * 10 ** (-tol_db / 20)).astype(int), [0]]))
        hits += ((np.where(d == -1)[0] - np.where(d == 1)[0]) >= run).any()
    return 100.0 * hits / max(1, loud.sum())


def align(p, l):
    """Trim to whole frames, fine-align the iso to the feed by xcorr over the first 4 s (+-50 ms). Returns (p, l, lag)."""
    n = min(len(p), len(l)) // W * W
    if n < SR:
        return None
    p, l = p[:n], l[:n]
    a = p[: SR * 4] - p[: SR * 4].mean(); b = l[2400: SR * 4 - 2400]
    k = int(np.argmax(np.correlate(a, b - b.mean(), "valid"))) - 2400
    return p, np.roll(l, k), k


def peaks(x):
    return np.abs(x).reshape(-1, W).max(1)


def classify(pdb, ldb, flat, tt=None):
    """Verdict from per-frame feed/iso peak levels (dBFS) and the feed's flat-top share. Pure."""
    curve = []
    for b in np.arange(np.floor(np.percentile(ldb, 50)), np.ceil(ldb.max()), 2.0):
        s = (ldb >= b) & (ldb < b + 2)
        if s.sum() >= 20:
            curve.append((float(b), float(np.median(pdb[s] - ldb[s])), int(s.sum())))
    # clean tracking = the HIGHEST run of 3+ bins whose offset varies < 1.5 dB (there the iso's own talker dominates the
    # feed; at low iso levels the feed is other talkers and the offset is meaningless)
    base, top = None, None
    for i in range(len(curve) - 3, -1, -1):
        win = [c[1] for c in curve[i:i + 3]]
        if max(win) - min(win) < 1.5:
            base, top = float(np.median(win)), i + 2; break
    if base is None:
        return dict(verdict="no clean tracking found (iso and feed carry different sources?)", kind="UNKNOWN", curve=curve)
    knee = next((c[0] for c in curve[top + 1:] if c[1] < base - DROP_DB), None)
    if knee is None:
        return dict(verdict="CLEAN: feed tracks the iso to its loudest level", kind="CLEAN", clean_offset_db=round(base, 2), curve=curve)
    above = [c for c in curve if c[0] >= knee]
    x = np.array([c[0] for c in above]); y = x + np.array([c[1] for c in above])        # feed level vs iso level
    slope = float(np.polyfit(x, y, 1)[0]) if len(above) >= 2 else 0.0
    ceil = float(np.median(y))
    if slope >= 0.35:
        return dict(verdict=f"COMPRESSION above iso {knee} dBFS (feed still rises {slope:.2f} dB/dB): not clipping", kind="COMPRESSION",
                    clean_offset_db=round(base, 2), knee_iso_dbfs=knee, slope=round(slope, 2), curve=curve)
    if flat < FLAT_CLIP:
        return dict(verdict=f"LIMITER: feed held at {ceil:.1f} dBFS above iso {knee} dBFS but only {flat:.0f} % flat tops: not clipping",
                    kind="LIMITER", clean_offset_db=round(base, 2), knee_iso_dbfs=knee, flat_top_pct=round(flat, 1), curve=curve)
    hit = (ldb >= knee) & (pdb >= ceil - 1.5)
    secs = sorted({round(float(v), 0) for v in tt[hit]}) if tt is not None else []
    return dict(verdict=f"HARD CLIP: feed pinned at {ceil:.1f} dBFS above iso {knee} dBFS (slope {slope:.2f}, {flat:.0f} % flat tops)",
                kind="HARD CLIP", clean_offset_db=round(base, 2), knee_iso_dbfs=knee, ceiling_feed_dbfs=round(ceil, 2),
                slope=round(slope, 2), flat_top_pct=round(flat, 1), curve=curve, clipped_seconds=secs)


def analyse_arrays(feed, iso):
    """Same verdict from in-memory samples (48 kHz, roughly aligned). Used by tests and for already-decoded audio."""
    r = align(feed, iso)
    if r is None:
        return dict(verdict="too short", kind="UNKNOWN")
    p, l, _ = r
    flat = float(np.median([flat_share(p[i:i + SR * 10]) for i in range(0, max(1, len(p) - SR), SR * 10)]))
    P, L = peaks(p), peaks(l)
    return classify(20 * np.log10(P + 1e-9), 20 * np.log10(L + 1e-9), flat, np.arange(len(P)) * W / SR)


def analyse(feed, iso, off, t0, t1, step=60.0):
    """File version (validated 10/1). off = iso time minus feed time (s)."""
    P, L, starts, lags = [], [], [], []
    flats = [flat_share(read(feed, t, min(10.0, t1 - t))) for t in np.arange(t0, t1, max(step, (t1 - t0) / 8))]
    for t in np.arange(t0, t1, step):
        r = align(read(feed, t, min(step, t1 - t)), read(iso, t + off, min(step, t1 - t)))
        if r is None:
            continue
        p, l, k = r
        P.append(peaks(p)); L.append(peaks(l)); lags.append(k); starts += [t] * len(P[-1])
    P, L = np.concatenate(P), np.concatenate(L); starts = np.array(starts)
    tt = starts + (np.arange(len(P)) - np.searchsorted(starts, starts, "left")) * W / SR
    out = classify(20 * np.log10(P + 1e-9), 20 * np.log10(L + 1e-9), float(np.median(flats)), tt)
    out["lags"] = lags
    return out
