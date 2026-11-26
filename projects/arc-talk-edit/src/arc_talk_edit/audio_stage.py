"""audio stage (P1.6, port of JOB-0000 audio_sweep.py): is an iso mic better than the mix? (LESSONS L24-L27)

Per section (50 ms frames, 48 kHz): speech level (p95), noise floor (p10), SNR, <100 Hz rumble share of the quiet frames,
speech spectral centroid; for mix vs iso also the share of the mix that is NOT the iso (lag-aligned least squares).
Sections come from job.yaml `audio.sections: [{name, in, out, iso: {source, stream, channel}}]` (program clock), compared
against `audio.mix: {source, stream, channel}`. Without sections it ranks every live channel by SNR over the program.
"""
from __future__ import annotations
import json, subprocess
from pathlib import Path
import numpy as np
from scipy.signal import fftconvolve
from .stages import stage

SR = 48000


def read(path, t0: float, dur: float, stream: int = 0, channel: int = 0) -> np.ndarray:
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{max(0.0, t0):.3f}", "-t", f"{dur:.3f}", "-i", str(path),
                          "-map", f"0:a:{stream}", "-af", f"pan=mono|c0=c{channel}", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True).stdout
    return np.frombuffer(raw, np.float32).astype(np.float64)


def stats(x: np.ndarray) -> dict:
    n = 2400; k = len(x) // n
    if k < 10:
        return {}
    f = x[:k * n].reshape(k, n)
    rms = 20 * np.log10(np.sqrt((f ** 2).mean(1)) + 1e-9)
    sp, nf = np.percentile(rms, 95), np.percentile(rms, 10)
    X = np.abs(np.fft.rfft(f * np.hanning(n), axis=1)) ** 2; fq = np.fft.rfftfreq(n, 1 / SR)
    loud, quiet = rms > sp - 15, rms < nf + 3
    cen = float((X[loud] * fq).sum() / X[loud].sum())
    rum = float(10 * np.log10(X[quiet][:, fq < 100].sum() / X[quiet].sum() + 1e-12))
    return {"speech_db": round(float(sp), 1), "floor_db": round(float(nf), 1), "snr_db": round(float(sp - nf), 1),
            "rumble_db": round(rum, 1), "centroid_hz": round(cen)}


def not_iso(mix: np.ndarray, iso: np.ndarray) -> dict:
    L = min(len(mix), len(iso), SR * 20)
    c = fftconvolve(mix[:L], iso[:L][::-1], mode="full"); lag = int(np.argmax(np.abs(c))) - (L - 1)
    i2 = np.roll(iso, lag)[:len(mix)]; m = mix[:len(i2)]
    g = (m @ i2) / (i2 @ i2 + 1e-12); res = m - g * i2
    return {"mix_not_iso_db": round(float(10 * np.log10((res ** 2).sum() / (m ** 2).sum() + 1e-12)), 1), "lag_ms": round(lag / 48, 2)}


def _inputs(job):
    return [job.path(k) for k in job.sources]


@stage("audio", inputs=_inputs)
def run(job, work: Path) -> dict:
    media = Path(job.raw.get("media_root", "")).expanduser()
    cfg = job.raw.get("audio") or {}
    pc = job.program_clock

    def grab(spec, a, b):
        src = job.sources[spec["source"]]
        p = job.path(spec["source"])
        t0 = job.convert(a, pc, src.clock)
        return read(p, t0, b - a, spec.get("stream", 0), spec.get("channel", 0))

    rows, rep = [], [f"# Audio sweep {job.arc}", ""]
    if cfg.get("sections") and cfg.get("mix"):
        rep += ["| Section | Source | Speech | Floor | SNR | <100 Hz | Centroid | Mix not iso |", "|---|---|---|---|---|---|---|---|"]
        for s in cfg["sections"]:
            m, i = grab(cfg["mix"], s["in"], s["out"]), grab(s["iso"], s["in"], s["out"])
            r = {"section": s["name"], "mix": stats(m), "iso": stats(i), **not_iso(m, i)}
            rows.append(r)
            for lab, st in (("MIX", r["mix"]), (s["iso"]["source"], r["iso"])):
                rep.append(f"| {s['name']} | {lab} | {st.get('speech_db')} | {st.get('floor_db')} | {st.get('snr_db')} | "
                           f"{st.get('rumble_db')} | {st.get('centroid_hz')} | {r['mix_not_iso_db'] if lab == 'MIX' else ''} |")
    else:
        ing = json.loads((work / "ingest.json").read_text())["sources"]
        a, b = job.program.get("in"), job.program.get("out")
        if a is None or b is None:                    # new job: program window is set from the transcript later
            ref = next(r0 for r0 in ing if job.sources[r0["source"]].clock == job.ref)
            a, b = 0.0, ref["duration_s"]
        mid = (a + b) / 2
        rep += ["Ranked live channels, 120 s at mid-program:", "", "| Source | Stream.ch | Speech | Floor | SNR |", "|---|---|---|---|---|"]
        for r0 in ing:
            streams = sorted({c["stream"] for c in r0.get("audio", [])})
            for c in r0.get("audio", []):
                if c["state"] != "live":
                    continue
                spec = {"source": r0["source"], "stream": streams.index(c["stream"]), "channel": c["channel"]}
                st = stats(grab(spec, mid - 60, mid + 60))
                rows.append({**spec, **st})
        rows.sort(key=lambda r: -(r.get("snr_db") or -99))
        rep += [f"| {r['source']} | {r['stream']}.{r['channel']} | {r.get('speech_db')} | {r.get('floor_db')} | {r.get('snr_db')} |" for r in rows]
    (work / "audio.md").write_text("\n".join(rep) + "\n")
    return {"rows": rows}
