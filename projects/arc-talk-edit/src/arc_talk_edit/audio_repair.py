"""Program-audio repair + master for a recording with no clean iso (first job JOB-0000: room mics at maximum gain
driving the recorder into overload; the operator picked "De-clip + De-click" from a loudness-matched A/B, 10/3).

job.yaml (top level; `audio:` belongs to the iso-mix stage):
  audio_repair:
    source: {source: FRONT, channel: 0}            # the program channel; output is on this source's clock, full length
    pre_gain_db: -1                                 # decode is float: room for the codec overshoot around flat tops
    chain:                                          # VST3 plug-ins hosted with pedalboard, in order, any parameters
      - {plugin: "RX 12 De-clip", clipping_threshold: -1.0, quality: High, post_limiter: false}
      - {plugin: "RX 12 De-click", algorithm: "Multi-band (random clicks)", sensitivity: 4.0}
    splices:                                        # replace a window with another channel (level-matched, crossfaded)
      - {channel: 1, in: 798.5, out: 856.0, note: "played video: clean laptop channel"}
      - {source: MTLAV1, channel: 0, in: 400, out: 584.6, match: [586, 640], note: "another file on its own clock"}
        # source: another job source (its clock aligns it; any sample rate); match: program-clock window where BOTH carry
        # the voice, used for the level match when the program channel is silent or wrong inside [in, out) (JOB-0000)
    master: {lufs: -14, ...}                        # see DEFAULTS
Never: noise reduction, gates, expanders (LESSONS L24). The chain is whatever the operator approved by ear for the job.

How: one pass of the chain from the head of the recording to the program out (+ pad_s); after that the recording
passes through. The repaired file is 32-bit float (peaks above full scale survive to the master). Master: gain to a working level, light compression of speech peaks only, gain to the target
loudness measured over the PROGRAM window, true-peak limiter; a second pass corrects what the dynamics took.
The delivery gate (docs/defaults.yaml deliver.*) is reported as `gate_ok`.
"""
from __future__ import annotations
import json, subprocess
from pathlib import Path
import numpy as np

from .stages import stage

SR = 48000
VST_DIRS = [Path("/Library/Audio/Plug-Ins/VST3"), Path.home() / "Library/Audio/Plug-Ins/VST3"]
DEFAULTS = {
    "pre_gain_db": -1.0, "pad_s": 30.0, "chain": [], "splices": [],
    "master": {"lufs": -14.0, "limit_dbtp": -1.5, "work_lufs": -20.0,
               "compressor": {"threshold_lu": -0.6, "ratio": 2.5, "attack_ms": 8, "release_ms": 150, "knee": 6},
               "gate": {"lufs": [-15.5, -13.0], "true_peak_max": -1.0}},
}


def config(job) -> dict:
    from .classroom import _merge
    raw = job.raw.get("audio_repair")
    if not raw or "source" not in raw:
        raise ValueError(f"{job.arc}: audio_repair.source missing in the job.yaml")
    return _merge(DEFAULTS, raw)


def out_paths(job) -> tuple[Path, Path]:
    from .classroom import edit_root
    import hashlib
    d = edit_root(job) / "audio"                     # one pair per repair config: never replaced in place (see column_file)
    h = hashlib.md5(json.dumps(_config(job), sort_keys=True, default=str).encode()).hexdigest()[:8]
    return d / f"{job.arc}_program_REPAIRED_{h}.wav", d / f"{job.arc}_program_MASTER_{h}.wav"


# ---- io -------------------------------------------------------------------------------------------------------------
def decode(path, stream: int = 0) -> np.ndarray:
    """Whole audio stream as float32 (n, channels): float keeps the codec's overshoot above full scale."""
    ch = int(subprocess.run(["ffprobe", "-v", "error", "-select_streams", f"a:{stream}", "-show_entries", "stream=channels",
                             "-of", "csv=p=0", str(path)], capture_output=True, text=True).stdout.strip())
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-map", f"0:a:{stream}", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32).reshape(-1, ch)


def rms(v) -> float:
    return float(np.sqrt(np.mean(np.square(v, dtype=np.float64)))) if len(v) else 0.0


# ---- chain ----------------------------------------------------------------------------------------------------------
def plugin_path(name: str) -> Path:
    for d in VST_DIRS:
        p = d / f"{name}.vst3"
        if p.exists():
            return p
    raise FileNotFoundError(f"VST3 plug-in '{name}' not found in {[str(d) for d in VST_DIRS]}")


def load_chain(chain: list[dict]):
    import pedalboard
    plugs = []
    for spec in chain:
        p = pedalboard.load_plugin(str(plugin_path(spec["plugin"])))
        for k, v in spec.items():
            if k == "plugin":
                continue
            if k not in p.parameters:
                raise KeyError(f"{spec['plugin']}: no parameter '{k}' (has {sorted(p.parameters)})")
            setattr(p, k, v)
        plugs.append(p)
    return pedalboard.Pedalboard(plugs)


def process(x: np.ndarray, chain: list[dict], end: int | None = None, xfade_s: float = 0.02) -> np.ndarray:
    """x (mono float32) through the plug-in chain in ONE pass from sample 0 to `end`; the rest passes through raw (20 ms
    crossfade back). One pass from the head of the recording on purpose: RX De-click's decisions depend on where the
    stream starts (measured 10/3: the same audio processed from a different start differs by -30 dB everywhere, both
    results valid), so block-wise or windowed processing would not be repeatable. Deterministic run to run (-240 dB)."""
    out = x.astype(np.float32, copy=True)
    if not chain:
        return out
    end = len(x) if end is None else max(0, min(len(x), end))
    xf = min(int(xfade_s * SR), len(x) - end)
    y = load_chain(chain)(x[None, :end + xf], SR, reset=True)[0]
    out[:end] = y[:end]
    if xf > 0:
        w = np.linspace(0, 1, xf, dtype=np.float32)
        out[end:end + xf] = y[end:end + xf] * (1 - w) + x[end:end + xf] * w
    return out


def splice(y: np.ndarray, other: np.ndarray, a: float, b: float, fade_s: float = 0.5,
           match: tuple[float, float] | None = None) -> tuple[np.ndarray, float]:
    """y with [a, b) s replaced by `other` (level-matched to y over the window, or over `match` when given: a window where
    both carry the voice, for a program channel that is silent inside [a, b)), equal-power crossfades of fade_s."""
    ia, ib, nf = int(a * SR), int(b * SR), int(fade_s * SR)
    ma, mb = (int(t * SR) for t in (match or (a, b)))
    g = rms(y[ma:mb]) / max(rms(other[ma:mb]), 1e-9)
    lo, hi = max(0, ia - nf), min(len(y), ib + nf)
    ramp = np.ones(hi - lo, np.float32)
    ramp[:ia - lo] = np.linspace(0, 1, ia - lo); ramp[ib - lo:] = np.linspace(1, 0, hi - ib)
    th = ramp * (np.pi / 2)
    out = y.copy()
    out[lo:hi] = y[lo:hi] * np.cos(th) + other[lo:hi] * g * np.sin(th)
    return out, g


def align(o: np.ndarray, delta_s: float, n: int) -> np.ndarray:
    """o (on its own clock) resampled onto this clock: out[i] = o[i + delta_s * SR], where delta_s = this clock's zero
    expressed on o's clock (job.convert(0, this, other)); zero-padded to n samples."""
    d = int(round(delta_s * SR)); out = np.zeros(n, np.float32)
    lo, hi = max(0, -d), min(n, len(o) - d)
    if hi > lo:
        out[lo:hi] = o[lo + d:hi + d]
    return out


# ---- master ---------------------------------------------------------------------------------------------------------
def lufs(path, ss: float | None = None, to: float | None = None) -> tuple[float, float]:
    """(integrated LUFS, true peak dBFS) of a file, optionally over [ss, to]."""
    cmd = ["ffmpeg", "-v", "info", "-nostats"] + (["-ss", str(ss), "-to", str(to)] if ss is not None else []) + \
          ["-i", str(path), "-af", "ebur128=peak=true", "-f", "null", "-"]
    r = subprocess.run(cmd, capture_output=True, text=True).stderr
    tail = r[r.rfind("Summary:"):]
    return float(tail.split("I:")[1].split("LUFS")[0]), float(tail.split("Peak:")[1].split("dBFS")[0])


def master(rep: Path, mst: Path, window: tuple[float, float], m: dict) -> dict:
    """rep (float mono) -> mst (24-bit dual-mono stereo): gain to work_lufs, compress speech peaks, gain to m.lufs over
    `window`, peak limit. Up to four passes: each corrects the gain for what compressor + limiter took and lowers the
    limiter ceiling by any true-peak excess (the limiter is sample-peak; inter-sample peaks ran 1.3 dB over on JOB-0000).
    Stereo is c0 = c1 = the mono signal at FULL level: ffmpeg's `-ac 2` applies a -3 dB pan law AFTER the limiter, which
    left peaks at -4.5 dBFS and made the limiter work 3 dB harder for the same loudness (found 10/3)."""
    comp = m["compressor"]
    I0, _ = lufs(rep, *window)
    g1 = m["work_lufs"] - I0
    thr = m["work_lufs"] + comp["threshold_lu"]
    g2, ceil, res = m["lufs"] - m["work_lufs"] - 3.0, m["limit_dbtp"], {}    # -3: two full-level channels read 3 LU louder
    for k in range(4):
        af = (f"volume={g1:.2f}dB,acompressor=threshold={thr:.2f}dB:ratio={comp['ratio']}:attack={comp['attack_ms']}:"
              f"release={comp['release_ms']}:knee={comp['knee']},volume={g2:.2f}dB,"
              f"alimiter=limit={10 ** (ceil / 20):.4f}:attack=1:release=50:level=false,pan=stereo|c0=c0|c1=c0")
        tmp = mst.with_name(mst.stem + ".partial.wav")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(rep), "-af", af, "-c:a", "pcm_s24le", str(tmp)], check=True)
        tmp.replace(mst)
        I, tp = lufs(mst, *window)
        res = {"repaired_lufs": I0, "gain_db": round(g1 + g2, 2), "limiter_ceiling_db": round(ceil, 2), "master_lufs": I,
               "master_true_peak": tp, "passes": k + 1}
        if abs(I - m["lufs"]) <= 0.3 and tp <= m["limit_dbtp"] + 0.05:
            break
        g2 += m["lufs"] - I
        ceil -= max(0.0, tp - m["limit_dbtp"])
    g = m["gate"]
    res["gate_ok"] = bool(g["lufs"][0] <= res["master_lufs"] <= g["lufs"][1] and res["master_true_peak"] <= g["true_peak_max"])
    return res


# ---- the stage ------------------------------------------------------------------------------------------------------
def run(job, work: Path | None = None) -> dict:
    import soundfile as sf
    from .classroom.column import disk_guard
    c = config(job)
    src = c["source"]; key = src["source"]
    pc = job.program_clock; sclock = job.sources[key].clock
    rep, mst = out_paths(job)
    all_ch = decode(job.path(key), src.get("stream", 0))
    disk_guard(rep.parent, len(all_ch) * 4 + len(all_ch) * 6 * 2, 5)       # float mono + 24-bit stereo (+ its .partial)
    pre = 10 ** (c["pre_gain_db"] / 20)
    x = np.ascontiguousarray(all_ch[:, src.get("channel", 0)]) * np.float32(pre)
    window = tuple(job.convert(t, pc, sclock) for t in (job.program["in"], job.program["out"]))
    y = process(x, c["chain"], end=int((window[1] + c["pad_s"]) * SR))     # head of the file -> program out + pad

    spl = []
    for s in c["splices"]:
        a, b = (job.convert(t, pc, sclock) for t in (s["in"], s["out"]))  # splice times are on the program clock
        if s.get("source", key) == key:
            other = np.ascontiguousarray(all_ch[:, s["channel"]]) * np.float32(pre)
        else:                                                             # another file: decode, then align to this clock
            o = decode(job.path(s["source"]), s.get("stream", 0))[:, s.get("channel", 0)] * np.float32(pre)
            other = align(o, job.convert(0.0, sclock, job.sources[s["source"]].clock), len(y))
        m = tuple(job.convert(t, pc, sclock) for t in s["match"]) if s.get("match") else None
        y, g = splice(y, other, a, b, s.get("fade_s", 0.5), m)
        spl.append({"in": s["in"], "out": s["out"], "source": s.get("source", key), "channel": s.get("channel", 0),
                    "gain": round(g, 3)})
    sf.write(rep, y, SR, subtype="FLOAT")
    a, b = (int(t * SR) for t in window)
    res = {"repaired": str(rep), "master": str(mst), "seconds": round(len(x) / SR, 2),
           "peak_in": round(float(np.max(np.abs(x))) / pre, 3), "peak_repaired": round(float(np.max(np.abs(y))), 3),
           "changed_db": round(20 * np.log10(rms(y[a:b] - x[a:b]) / max(rms(x[a:b]), 1e-9)), 1), "splices": spl}
    del all_ch, x, y
    res.update(master(rep, mst, window, c["master"]))
    return res


def _inputs(job):
    c = config(job)
    return [job.path(c["source"]["source"])] + sorted({job.path(s["source"]) for s in c["splices"] if s.get("source")}, key=str)


def _config(job):
    return {"repair": config(job), "clocks": job.offsets, "program": [job.program.get("in"), job.program.get("out")],
            "edit_root": job.raw.get("edit_root")}


@stage("audio_repair", inputs=_inputs, config=_config, code=(__import__("sys").modules[__name__],))
def stage_run(job, work: Path) -> dict:
    return run(job, work)
