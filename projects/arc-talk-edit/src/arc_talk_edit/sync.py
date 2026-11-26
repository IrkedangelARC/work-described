"""Sync stage: audio cross-correlation of every source against one reference (LESSONS L11).

Port of the JOB-0000 `xcorr_offsets.py` (coarse 100 Hz RMS envelope, then a fine pass on 16 kHz audio at several
anchors) that reads job.yaml instead of hard-coded paths, extracts the audio itself, and reports drift.

Convention: offset = t_ref - t_other (a moment at t_other in OTHER sits at t_other + offset in the reference), which for
job.yaml clocks is clocks[other.clock] - clocks[ref.clock].
"""
from __future__ import annotations
import json, subprocess
from pathlib import Path
import numpy as np
from scipy.signal import fftconvolve
import soundfile as sf

SR = 16000


def extract(path: str | Path, out: Path, stream: int = 0, channel: int = 0) -> Path:
    """16 kHz mono float WAV of one channel of one audio stream (cached)."""
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists() and out.stat().st_size > 0:
        return out
    tmp = out.with_suffix(".part.wav")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(path), "-map", f"0:a:{stream}",
                    "-af", f"pan=mono|c0=c{channel}", "-ar", str(SR), "-c:a", "pcm_f32le", str(tmp)], check=True)
    tmp.rename(out)
    return out


def env(x: np.ndarray, hop: int = 160) -> np.ndarray:
    n = len(x) // hop
    return np.sqrt((x[: n * hop].reshape(n, hop) ** 2).mean(1))


def _xc(a, b):
    a = (a - a.mean()) / (a.std() + 1e-9); b = (b - b.mean()) / (b.std() + 1e-9)
    c = fftconvolve(a, b[::-1], mode="full")
    k = int(np.argmax(c))
    return k - (len(b) - 1), float(c[k] / min(len(a), len(b)))


def offset(ref: np.ndarray, other: np.ndarray, anchors: int | None = None, win_s: float = 20.0) -> dict:
    """Coarse envelope lag, then fine 16 kHz offsets at anchors spread through OTHER (one per ~10 min, min 5)."""
    if anchors is None:
        anchors = max(5, int(len(other) / SR / 600))
    lag, score = _xc(env(ref), env(other))
    coarse = lag / 100.0
    fine = []
    for t in np.linspace(120, len(other) / SR - 180, anchors):
        seg = other[int(t * SR): int((t + win_s) * SR)]
        r0 = int((t + coarse - 1) * SR)
        if r0 < 0 or r0 + len(seg) + 2 * SR > len(ref) or len(seg) < win_s * SR:
            continue
        w = ref[r0: r0 + len(seg) + 2 * SR]
        c = fftconvolve(w, seg[::-1], mode="valid")
        nrm = np.sqrt(np.convolve(w ** 2, np.ones(len(seg)), "valid")) * np.linalg.norm(seg) + 1e-9
        k = int(np.argmax(c / nrm))
        fine.append({"at_other_s": round(float(t), 1), "offset_s": (r0 + k) / SR - t, "ncc": float((c / nrm)[k])})
    ok = [f for f in fine if f["ncc"] >= 0.5]
    good = [f["offset_s"] for f in ok]
    slope = None
    if len(ok) >= 3:                                  # drift rate: ms of offset change per hour of OTHER (L13)
        slope = float(np.polyfit([f["at_other_s"] for f in ok], good, 1)[0] * 3600 * 1000)
    return {"coarse_s": coarse, "env_ncc": score, "fine": fine,
            "offset_s": float(np.median(good)) if good else coarse,
            "drift_ms": float((max(good) - min(good)) * 1000) if len(good) > 1 else None,
            "drift_ms_per_h": slope, "anchors_ok": len(ok), "anchors": len(fine)}


def auto_spec(job, work: Path) -> dict:
    """Reference + pairs from ingest.json: every source with a live channel; reference = the longest one unless the
    job names it (`sync_ref:`). Uses each source's first LIVE channel (measured, never a label: L1)."""
    ing = json.loads((work / "ingest.json").read_text())["sources"]
    live = {}
    for r in ing:
        ch = next((c for c in r.get("audio", []) if c["state"] == "live"), None)
        if ch and not r.get("missing"):
            # stream index in ingest is the absolute ffprobe index; extract() wants the audio-relative index
            rel = sorted({c["stream"] for c in r["audio"]}).index(ch["stream"])
            live[r["source"]] = {"source": r["source"], "stream": rel, "channel": ch["channel"], "dur": r["duration_s"]}
    ref_key = job.raw.get("sync_ref") or max(live, key=lambda k: live[k]["dur"])
    strip = lambda d: {k: v for k, v in d.items() if k != "dur"}
    return {"ref": strip(live[ref_key]), "pairs": [strip(v) for k, v in live.items() if k != ref_key], "auto": True}


def run(job, work: Path) -> dict:
    """job.raw['sync'] = {ref: {source, stream, channel}, pairs: [...]}, or automatic from ingest when absent."""
    spec = job.raw.get("sync") or auto_spec(job, work)
    media = Path(job.raw.get("media_root", "")).expanduser()

    def load(s):
        src = job.sources[s["source"]]
        p = job.path(s["source"])
        w = extract(p, work / "audio" / f"{s['source']}_a{s.get('stream', 0)}c{s.get('channel', 0)}.16k.wav",
                    s.get("stream", 0), s.get("channel", 0))
        return sf.read(str(w), dtype="float32")[0], src.clock

    ref, ref_clock = load(spec["ref"])
    out = {"ref": spec["ref"], "auto": bool(spec.get("auto")), "pairs": []}
    for s in spec["pairs"]:
        x, clock = load(s)
        r = offset(ref, x)
        r.update(source=s["source"], clock=clock)
        if ref_clock in job.offsets and clock in job.offsets:
            r["expected_s"] = job.offsets[clock] - job.offsets[ref_clock]
            r["error_ms"] = (r["offset_s"] - r["expected_s"]) * 1000
        frame_ms = 1000 / job.f
        if r.get("drift_ms_per_h") is not None and abs(r["drift_ms_per_h"]) * (len(x) / SR / 3600) > frame_ms:
            r["flag"] = f"drifts {r['drift_ms_per_h']:.1f} ms/h: more than a frame over the file, sync per segment (L13)"
        out["pairs"].append(r)
    (work / "sync.json").write_text(json.dumps(out, indent=1))
    return out


def _inputs(job):
    return [job.path(k) for k in job.sources]


from .stages import stage  # noqa: E402


@stage("sync", inputs=_inputs)
def sync_stage(job, work: Path) -> dict:
    out = run(job, work)
    lines = [f"# Sync report {job.arc} (reference {out['ref']['source']}{', automatic pairs' if out['auto'] else ''})", "",
             "| Source | Offset s | Expected s | Error ms | Drift ms (ms/h) | Anchors | Flag |", "|---|---|---|---|---|---|---|"]
    for r in out["pairs"]:
        e = r.get("error_ms"); d = r.get("drift_ms"); dh = r.get("drift_ms_per_h")
        lines.append(f"| {r['source']} | {r['offset_s']:+.4f} | {r.get('expected_s', '')} | {'' if e is None else f'{e:.2f}'} | "
                     f"{'' if d is None else f'{d:.1f}'} ({'' if dh is None else f'{dh:.1f}'}) | {r['anchors_ok']}/{r['anchors']} | {r.get('flag', '')} |")
    (work / "sync.md").write_text("\n".join(lines) + "\n")
    return out
