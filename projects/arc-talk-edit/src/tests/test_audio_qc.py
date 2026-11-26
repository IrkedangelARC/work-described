"""audio_qc verdicts on synthetic signals (no drives needed). Run: python3 tests/test_audio_qc.py

A voice-like signal (harmonic stack, random phases, 200 ms 'syllables' spread over ~40 dB) is the clean iso; the feed is the
same signal at +12 dB through: nothing (CLEAN), a hard clipper scaled back down (HARD CLIP, the case this tool was written for), a
smooth-gain brickwall limiter (LIMITER), a 2:1 compressor (COMPRESSION)."""
from pathlib import Path
import sys
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from arc_talk_edit import audio_qc as Q

SR = Q.SR
RNG = np.random.default_rng(7)


def voice(seconds=60):
    t = np.arange(SR * seconds) / SR
    x = np.zeros_like(t)
    for k in range(1, 14):                                         # 180 Hz harmonic stack, 1/k rolloff, random phase
        x += np.sin(2 * np.pi * 180 * k * t + RNG.uniform(0, 2 * np.pi)) / k
    x /= np.abs(x).max()
    seg = SR // 5
    lv = 10 ** (RNG.uniform(-40, 0, len(t) // seg + 1) / 20)       # syllable levels over 40 dB
    env = np.repeat(lv, seg)[: len(t)]
    k = np.hanning(SR // 50); env = np.convolve(env, k / k.sum(), "same")   # 20 ms ramps
    return x * env


def env_peak(x, win):
    from numpy.lib.stride_tricks import sliding_window_view
    a = np.abs(np.pad(x, (win // 2, win - win // 2 - 1), mode="edge"))
    return sliding_window_view(a, win).max(1)


ISO = voice() * 10 ** (-20 / 20)
LOUD = ISO * 10 ** (20 / 20)            # feed +20 dB over the iso, peaks at 0 dBFS; the top ~6 dB is what gets overdriven


def test_clean():
    feed = ISO * 10 ** (12 / 20)
    assert Q.analyse_arrays(feed, ISO)["kind"] == "CLEAN"


def test_hard_clip():
    feed = np.clip(LOUD, -0.5, 0.5) * 10 ** (-4 / 20)             # input overdriven, then sent on at a lower level
    r = Q.analyse_arrays(feed, ISO)
    assert r["kind"] == "HARD CLIP", r["verdict"]
    assert r["flat_top_pct"] >= Q.FLAT_CLIP


def test_limiter():
    g = np.minimum(1.0, 0.5 / np.maximum(env_peak(LOUD, SR // 100), 1e-9))   # 10 ms look-around gain: wave shape kept
    k = np.hanning(SR // 200); g = np.convolve(g, k / k.sum(), "same")
    r = Q.analyse_arrays(LOUD * g * 10 ** (-4 / 20), ISO)
    assert r["kind"] == "LIMITER", r["verdict"]                     # pinned but round: never called a clip
    assert r["flat_top_pct"] < Q.FLAT_CLIP


def test_compressor():
    e = env_peak(LOUD, SR // 50); thr = 0.25
    gain = np.where(e > thr, (thr * (e / thr) ** 0.5) / e, 1.0)     # 2:1 above -12 dBFS: still rising, not pinned
    k = np.hanning(SR // 100); gain = np.convolve(gain, k / k.sum(), "same")
    r = Q.analyse_arrays(LOUD * gain * 0.5, ISO)
    assert r["kind"] in ("COMPRESSION", "CLEAN"), r["verdict"]


if __name__ == "__main__":
    for f in (test_clean, test_hard_clip, test_limiter, test_compressor):
        f(); print("ok", f.__name__)
