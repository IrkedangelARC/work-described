"""Measured speech EQ (10/21, JOB-0000 breakouts): long-term average spectrum of SPEECH frames in third-octave bands,
compared with a reference (clean close-miked speech, e.g. the day's interview lav mixes), turned into a few broad
peaking bands. Corrective only: the curve is smoothed over an octave, clamped to +-max_db, bands under min_db dropped,
and nothing below `lo` Hz (the low cut handles that) or above `hi`. No dynamic or narrow EQ (no NR, the operator's rule)."""
from __future__ import annotations
import subprocess
import numpy as np

SR = 48000
CENTRES = 1000 * 2.0 ** (np.arange(-17, 14) / 3)      # 20 Hz .. 20 kHz third-octave centres
# Neutral reference: long-term average speech spectrum, talker at 1 m (Byrne et al. 1994, combined male/female), dB per
# third octave. VALUES ENTERED FROM MEMORY 10/22, not from the paper: verify before relying on absolute numbers. Used
# instead of the interview lav mixes, which measured 9-12 dB dull at 3-5 kHz against it (chest-worn lavs).
LTASS = {63: 38.6, 80: 43.5, 100: 54.4, 125: 57.7, 160: 56.8, 200: 58.2, 250: 59.7, 315: 60.0, 400: 62.4, 500: 62.6,
         630: 60.6, 800: 55.7, 1000: 53.1, 1250: 53.4, 1600: 51.3, 2000: 50.6, 2500: 50.6, 3150: 49.4, 4000: 47.6,
         5000: 45.8, 6300: 45.0, 8000: 44.4, 10000: 42.4, 12500: 41.0, 16000: 40.3}


def ltass() -> np.ndarray:
    return np.array([np.interp(np.log10(c), np.log10(list(LTASS)), list(LTASS.values())) for c in CENTRES])


def read(path, t0=0.0, dur=None, ch: int | None = None) -> np.ndarray:
    af = ["-af", f"pan=mono|c0=c{ch}"] if ch is not None else ["-ac", "1"]
    cmd = ["ffmpeg", "-v", "error", "-ss", str(t0), "-i", str(path)] + (["-t", str(dur)] if dur else []) + \
          ["-map", "0:a:0", *af, "-ar", str(SR), "-f", "f32le", "-"]
    return np.frombuffer(subprocess.run(cmd, capture_output=True, check=True).stdout, np.float32).astype(np.float64)


def ltas(x: np.ndarray, n: int = 8192, speech_db: float = 12.0) -> np.ndarray:
    """Third-octave band levels (dB) averaged over frames at least `speech_db` above the 10th-percentile frame (speech)."""
    hop = n // 2
    k = (len(x) - n) // hop
    if k < 4:
        raise ValueError("too short")
    idx = np.arange(n)[None, :] + hop * np.arange(k)[:, None]
    fr = x[idx] * np.hanning(n)
    lvl = 10 * np.log10((fr ** 2).mean(1) + 1e-12)
    keep = lvl > np.percentile(lvl, 10) + speech_db
    p = (np.abs(np.fft.rfft(fr[keep], axis=1)) ** 2).mean(0)
    f = np.fft.rfftfreq(n, 1 / SR)
    out = []
    for c in CENTRES:
        m = (f >= c / 2 ** (1 / 6)) & (f < c * 2 ** (1 / 6))
        out.append(10 * np.log10(p[m].mean() + 1e-20) if m.any() else np.nan)
    return np.array(out)


def correction(room: np.ndarray, ref: np.ndarray, lo=120.0, hi=10000.0, max_db=4.0) -> np.ndarray:
    """ref - room, level-matched on 300 Hz-3 kHz, smoothed over +-1 band (an octave), clamped, zero outside lo..hi."""
    d = ref - room
    mid = (CENTRES >= 300) & (CENTRES <= 3000)
    d = d - np.nanmean(d[mid])
    d = np.nan_to_num(d)
    d = np.convolve(np.pad(d, 1, mode="edge"), np.ones(3) / 3, "valid")
    d[(CENTRES < lo) | (CENTRES > hi)] = 0
    return np.clip(d, -max_db, max_db)


def bands(corr: np.ndarray, min_db=1.0, max_bands=4) -> list[tuple[float, float]]:
    """Local extrema of the correction beyond min_db, strongest first: [(freq, gain_db)], at least an octave apart."""
    cand = [(abs(corr[i]), CENTRES[i], corr[i]) for i in range(1, len(corr) - 1)
            if abs(corr[i]) >= min_db and abs(corr[i]) >= abs(corr[i - 1]) and abs(corr[i]) >= abs(corr[i + 1])]
    out = []
    for _, f, g in sorted(cand, reverse=True):
        if all(abs(np.log2(f / o[0])) >= 1 for o in out):
            out.append((float(f), round(float(g), 1)))
        if len(out) == max_bands:
            break
    return sorted(out)


def af(bnds: list[tuple[float, float]], width_oct: float = 1.0) -> str:
    """ffmpeg filter string: one peaking band per entry, `width_oct` octaves wide."""
    return ",".join(f"equalizer=f={f:.0f}:t=o:w={width_oct}:g={g}" for f, g in bnds) or "anull"
