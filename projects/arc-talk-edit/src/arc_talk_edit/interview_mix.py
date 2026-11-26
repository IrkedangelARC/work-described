"""Interview mix (JOB-0000, 2026-10-21): two iso lavs -> one dual-mono program track, no noise reduction, no gates.

Lav floor is ~70 % below 300 Hz (room/HVAC): 100 Hz 24 dB/oct low cut, light compression, -16 LUFS (room tone
controlled by gain structure, slightly under -14 is fine). Each lav is one talker, with the other talker bleeding in 8-18 dB down at 1-8 ms. A static sum comb-filters that bleed.
`share` = Dugan-style gain sharing: amplitude gain_i = P_i / sum(P) (smoothed power), floored at `floor_db`, so the talking
lav stays open and the other dips; total gain stays near constant, so room tone holds steady (not a gate or expander).
Talkers are level-matched first (speech p95 on frames each lav dominates). Loudness/true peak is the ffmpeg tail."""
from __future__ import annotations
import json, subprocess
from pathlib import Path
import numpy as np
from scipy.signal import butter, sosfilt, lfilter

SR = 48000


def read(path, stream: int, t0: float = 0.0, dur: float | None = None) -> np.ndarray:
    cmd = ["ffmpeg", "-v", "error", "-ss", f"{t0:.3f}", "-i", str(path)] + (["-t", f"{dur:.3f}"] if dur else []) + \
          ["-map", f"0:a:{stream}", "-ar", str(SR), "-f", "f32le", "-"]
    return np.frombuffer(subprocess.run(cmd, capture_output=True, check=True).stdout, np.float32).astype(np.float64)


def frames_db(x, n=2400):
    k = len(x) // n
    return 20 * np.log10(np.sqrt((x[:k * n].reshape(k, n) ** 2).mean(1)) + 1e-9)


def match_gains(a, b, target_db=-26.0):
    """Gain (linear) per lav so each talker's own speech p95 sits at target_db."""
    da, db = frames_db(a), frames_db(b)
    out = []
    for own, other in ((da, db), (db, da)):
        m = (own - other > 6) & (own > np.percentile(own, 50))
        lvl = np.percentile(own[m], 95) if m.sum() > 20 else np.percentile(own, 95)
        out.append(10 ** ((target_db - lvl) / 20))
    return out


def smooth_power(x, ms=20.0):
    a = np.exp(-1 / (SR * ms / 1000))
    return lfilter([1 - a], [1, -a], x ** 2)


def cam_lag(cam, lav, secs=20.0, max_ms=50.0) -> int:
    """Samples the lav arrives after the camera mic (DJI wireless latency, 13-20 ms measured on JOB-0000)."""
    n = min(len(cam), len(lav), int(SR * secs))
    r = np.fft.irfft(np.fft.rfft(lav[:n], 2 * n) * np.conj(np.fft.rfft(cam[:n], 2 * n)))
    m = int(SR * max_ms / 1000)
    win = np.concatenate([r[-m:], r[:m + 1]])
    return int(np.argmax(np.abs(win))) - m


def interviewer(cam, lavs, n=2400, gap_s=1.5, min_s=0.4, pad_s=0.3, min_total_s=15.0):
    """Per-frame mask of interviewer speech: camera mic 6 dB over every lav AND 12 dB over its own floor, gaps under
    gap_s closed (a question opens once, not word by word), runs under min_s dropped, pad_s added each side.
    Returns (mask, gain putting the interviewer's p95 at -26 dB)."""
    dc = frames_db(cam, n)
    dl = np.max([frames_db(x, n)[:len(dc)] for x in lavs], 0)
    m = (dc - dl > 6) & (dc > np.percentile(dc, 10) + 12)
    lvl = np.percentile(dc[m], 95) if m.sum() > 20 else np.percentile(dc, 95)
    fs = SR / n
    for val, lim in ((False, gap_s), (True, min_s)):              # close short gaps, then drop short runs
        edges = np.flatnonzero(np.diff(np.r_[False, m == val, False].astype(int)))
        for s, e in zip(edges[::2], edges[1::2]):
            if e - s < lim * fs and (val or (s > 0 and e < len(m))):
                m[s:e] = not val
    p = int(pad_s * fs)
    m = np.convolve(m.astype(float), np.ones(2 * p + 1), "same") > 0
    if m.sum() < min_total_s * fs:    # interviewer wore a lav: JOB-0000 single-guest clips open 0-9 s, all on guest
        m[:] = False                  # speech; two-guest clips (both lavs on guests) open 25-57 s
    return m, 10 ** ((-26.0 - lvl) / 20)


def mix(a, b, mode="share", floor_db=-10.0, hpf=100.0, smooth_ms=60.0, cam=None, ride_ms=80.0, cam_ride=True, cam_duck_db=-6.0):
    """`cam` = the camera mic, the only mic on the interviewer (10/22 C0117: questions sat 12 dB under the answers on lav
    bleed alone). It is NOT in the gain sharing: in every pause its higher room floor won the share and lifted room tone
    10 dB. Instead a fader ride: up on interviewer spans (time-aligned to the lavs), fully down elsewhere."""
    sos = butter(4, hpf, "highpass", fs=SR, output="sos")
    a, b = sosfilt(sos, a), sosfilt(sos, b)
    ga, gb = match_gains(a, b)
    a, b = a * ga, b * gb
    if mode == "sum":
        out = 0.5 * (a + b)
        if cam is None:
            return out
        # 10/23 decision: the mics are never ducked. The camera mic (only on clips where every lav is on a guest) is
        # mixed at ONE fixed level for the whole clip, set from the interviewer's speech (p95 at -26 dB like the ride)
        c = sosfilt(sos, cam)
        lag = cam_lag(c, a if np.abs(a).mean() > np.abs(b).mean() else b)
        c = np.concatenate([np.zeros(max(lag, 0)), c[max(-lag, 0):]])
        c = np.pad(c, (0, max(len(out) - len(c), 0)))[:len(out)]
        m, g = interviewer(c, [a, b])
        if not cam_ride or not m.any():
            return out + g * c
        # 10/23 decision: the camera mic may duck subtly, the two lavs never: full on the questions, cam_duck_db between
        # them, slow zero-phase ramps (ride_ms) so the room tone it carries moves gently
        lo = 10 ** (cam_duck_db / 20)
        ride = np.repeat(m.astype(float), 2400); ride = np.pad(ride, (0, max(len(out) - len(ride), 0)))[:len(out)]
        r = np.exp(-1 / (SR * ride_ms / 1000))
        ride = lfilter([1 - r], [1, -r], lfilter([1 - r], [1, -r], ride[::-1])[::-1])
        return out + g * (lo + (1 - lo) * ride) * c
    pa, pb = smooth_power(a), smooth_power(b)
    wa = pa / (pa + pb + 1e-12)
    fl = 10 ** (floor_db / 20)
    wa, wb = np.maximum(wa, fl), np.maximum(1 - wa, fl)
    k = np.exp(-1 / (SR * smooth_ms / 1000))                      # de-zipper the gains
    wa, wb = lfilter([1 - k], [1, -k], wa), lfilter([1 - k], [1, -k], wb)
    out = wa * a + wb * b
    if cam is not None:
        c = sosfilt(sos, cam)
        lag = cam_lag(c, a if np.abs(a).mean() > np.abs(b).mean() else b)
        c = np.concatenate([np.zeros(max(lag, 0)), c[max(-lag, 0):]])
        c = np.pad(c, (0, max(len(out) - len(c), 0)))[:len(out)]
        m, g = interviewer(c, [a, b])
        ride = np.repeat(m.astype(float), 2400)
        ride = np.pad(ride, (0, len(out) - len(ride)))
        r = np.exp(-1 / (SR * ride_ms / 1000))
        ride = lfilter([1 - r], [1, -r], lfilter([1 - r], [1, -r], ride[::-1])[::-1])   # zero-phase ramp: opens before
        out = out + g * ride * c                                                         # the first word, not after
    return out


# Static gain FIRST, then dynamics at known levels. 10/21 bug: a fixed -18 dB compressor on the unscaled mix (-35 LUFS) did
# nothing, and loudnorm needing +18.7 dB with peaks at +5.7 silently fell back to DYNAMIC mode = audible overdrive.
# Never use loudnorm for the gain here; the chain below is static gain -> peak compressor -> true-peak limiter.
def chain(gain_db: float, tp: float = -1.5) -> str:
    # 10/23 the operator picked version E of the C0113 A/B (the first sounded thin -> gentler dynamics, EQ unchanged): 1.6:1 from -10 dB,
    # soft knee, slower attack and release (was 2.5:1 from -14 dB, 5 / 150 ms)
    return (f"volume={gain_db:.2f}dB,acompressor=threshold=-10dB:ratio=1.6:knee=8:attack=10:release=200:makeup=1,"
            f"alimiter=limit={10 ** (tp / 20):.4f}:attack=5:release=60:level=false:asc=true")


def integrated(path, af: str = "anull") -> float:
    r = subprocess.run(["ffmpeg", "-v", "info", "-i", str(path), "-af", af + ",ebur128=peak=true", "-f", "null", "-"],
                       capture_output=True, text=True).stderr
    return float(r[r.rindex("I:"):].split()[1])


def master(x: np.ndarray, out_wav: Path, lufs: float = -16.0) -> dict:
    """Mixed mono -> static gain, peak compressor, true-peak limiter (2 passes to land on `lufs`), dual-mono 24-bit wav."""
    raw = out_wav.with_suffix(".raw.wav")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f64le", "-ar", str(SR), "-ac", "1", "-i", "-", "-c:a", "pcm_f32le", str(raw)],
                   input=x.astype(np.float64).tobytes(), check=True)
    g = lufs - integrated(raw)     # NO make-up trim after dynamics: it feeds gain back into the compressor (10/21: 12 dB squash).
                                   # The result lands 1-2 LU under `lufs`, which the operator accepts.
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(raw), "-af", chain(g) + ",aresample=48000,pan=stereo|c0=c0|c1=c0",
                    "-c:a", "pcm_s24le", str(out_wav)], check=True)
    pre = 20 * np.log10(np.abs(x).max() + 1e-12) + g    # peak if only the static gain were applied
    raw.unlink()
    return dict(gain_db=round(g, 2), lufs=round(integrated(out_wav), 2), peak_reduction_db=round(pre - (-1.5), 1))


# ---- 10/23 (C0115 listening test): questions from the camera mic, answers from the guest's lav ----------------
# The second lav was on nobody in the one-person clips (TX02 in C0115, TX01 in C0114: it heard the interviewer and the
# guest at the same faint level), so the questions exist only on the camera mic. Agreed by ear on C0115:
#   camera mic DELAYED to line up with the guest's lav (wireless latency, C0115 20.1 ms, same polarity) so the sum does
#   not comb-filter; camera EQ below; guest lav +3 dB; both at fixed gain, nothing ducked.
CAM_EQ = "highpass=f=90:poles=2,equalizer=f=250:t=o:w=1.5:g=3,equalizer=f=1600:t=o:w=1.0:g=-2,equalizer=f=4000:t=o:w=1.3:g=-6"
GUEST_LAV_DB = 3.0


def align_lag(cam, lav, spans, maxms=40.0):
    """Samples the camera mic must be DELAYED to line up with the lav (positive = camera early), and the polarity, from
    the band-passed cross-correlation over `spans` [(t0, t1)] of the guest talking (median over the spans)."""
    from scipy.signal import correlate
    sos = butter(4, [150, 4000], "bandpass", fs=SR, output="sos")
    m = int(maxms * SR / 1000); lags, sig = [], []
    for a, b in spans:
        x = sosfilt(sos, cam[int(a * SR):int(b * SR)]); y = sosfilt(sos, lav[int(a * SR):int(b * SR)])
        if len(x) < SR or len(y) < SR:
            continue
        c = correlate(x, y, "full", method="fft"); mid = len(y) - 1; w = c[mid - m:mid + m + 1]
        k = int(np.argmax(np.abs(w))); lags.append(m - k); sig.append(np.sign(w[k]))
    if not lags:
        return 0, 1.0
    return int(np.median(lags)), float(np.sign(np.sum(sig)) or 1.0)


def question_mask(cam, lavs, words, n=2400, reach_s=3.0, pad_s=0.3):
    """Per-frame mask of the interviewer's questions for a camera-mic ride (10/23 C0125). interviewer() finds them by
    level but closes early on a question's quiet tail and misses a soft
    lead-in (a one-word reply), so every span is widened to whole sentences from the transcript: back to the start of
    its sentence (plus a lead-in sentence of up to three words ending within 0.5 s) and on through the word that ends
    it (. ? !), each within reach_s. Rule of 10/23: never duck while a
    question is being asked."""
    m, _ = interviewer(cam, lavs, n=n, gap_s=2.5, pad_s=0.0)
    fs = SR / n
    ends = lambda x: x.get("word", x.get("text", "")).strip().endswith((".", "?", "!"))
    edges = np.flatnonzero(np.diff(np.r_[False, m, False].astype(int)))
    out = np.zeros_like(m)
    for s0, e0 in zip(edges[::2], edges[1::2]):
        a, b = s0 / fs, e0 / fs
        before = [x for x in words if a - reach_s <= x["start"] < a]
        for i in range(len(before) - 1, -1, -1):                  # back to the word after the previous sentence's end
            if ends(before[i]):
                break
            a = before[i]["start"]
        while True:                                               # plus a short lead-in sentence just before it
            prev = [x for x in words if x["end"] <= a + 0.05 and x["end"] > a - 0.5 and ends(x)]
            if not prev:
                break
            j = words.index(prev[-1]); k = j
            while k > 0 and not ends(words[k - 1]) and j - k < 3:
                k -= 1
            if j - k >= 3 or (k > 0 and not ends(words[k - 1])):
                break                                             # longer than three words: an answer, not a lead-in
            a = words[k]["start"]
        for x in (x for x in words if b - 0.5 <= x["end"] and x["start"] < b + reach_s):
            b = max(b, x["end"])                                  # on through the word that ends the sentence
            if ends(x):
                break
        out[max(int((a - pad_s) * fs), 0):int((b + pad_s) * fs) + 1] = True
    return out


def cam_lavs(cam, lavs, lag, polarity=1.0, duck_db=None, words=None, ride_ms=300.0):
    """Camera mic delayed by `lag` (polarity fixed), CAM_EQ, plus each lav of `lavs` [(signal, gain_db)] at its fixed
    gain; nothing ducked (10/23). C0113: both guests' lavs at unity.
    `duck_db` (C0125, under the walkway: reverb and background on the camera mic): the camera mic only, full on the
    questions (question_mask, needs `words`) and duck_db between them, slow zero-phase ramps; the lavs are never ducked."""
    import subprocess as sp
    c = np.concatenate([np.zeros(max(lag, 0)), cam[max(-lag, 0):]]) * polarity
    c = np.frombuffer(sp.run(["ffmpeg", "-v", "error", "-f", "f64le", "-ar", str(SR), "-ac", "1", "-i", "-", "-af", CAM_EQ,
                              "-f", "f64le", "-"], input=c.astype(np.float64).tobytes(), capture_output=True, check=True).stdout, np.float64)
    n = min([len(c)] + [len(x) for x, _ in lavs])
    c = c[:n]
    if duck_db is not None:
        m = question_mask(c, [x[:n] for x, _ in lavs], words)
        # raised-cosine ramps of ride_ms placed OUTSIDE the questions: full level on every frame of a question
        idx = np.arange(len(m)); on = np.flatnonzero(m)
        if len(on):
            k = np.searchsorted(on, idx).clip(1, len(on) - 1)
            dist = np.minimum(np.abs(idx - on[k - 1]), np.abs(on[k] - idx)) * 2400 / SR
        else:
            dist = np.full(len(m), 1e9)
        ride = 0.5 + 0.5 * np.cos(np.pi * np.clip(dist / (ride_ms / 1000), 0, 1))
        ride = np.interp(np.arange(n), (idx + 0.5) * 2400, ride)
        lo = 10 ** (duck_db / 20)
        c = c * (lo + (1 - lo) * ride)
    return c + sum(x[:n] * 10 ** (g / 20) for x, g in lavs)


def cam_guest(cam, lav, lag, polarity=1.0):
    """Camera mic delayed by `lag` samples (polarity fixed), EQ'd with CAM_EQ, plus the guest lav at GUEST_LAV_DB; unity
    otherwise. Returns mono float64 at SR."""
    import subprocess as sp
    c = np.concatenate([np.zeros(max(lag, 0)), cam[max(-lag, 0):]]) * polarity
    c = np.frombuffer(sp.run(["ffmpeg", "-v", "error", "-f", "f64le", "-ar", str(SR), "-ac", "1", "-i", "-", "-af", CAM_EQ,
                              "-f", "f64le", "-"], input=c.astype(np.float64).tobytes(), capture_output=True, check=True).stdout, np.float64)
    n = min(len(c), len(lav))
    return c[:n] + lav[:n] * 10 ** (GUEST_LAV_DB / 20)


def find_tone(x, lo=45.0, hi=95.0, prominence_db=15.0, max_width_hz=1.0):
    """A steady narrow tone in the low end (10/23 C0116: 68.25 Hz, +26 dB over its band, < 0.5 Hz wide, on every mic,
    a machine in the courtyard). 4 s FFT frames over the whole mix; the strongest bin in lo..hi counts when it stands
    `prominence_db` over the band median and its -6 dB width is under `max_width_hz`. Returns Hz or None."""
    n = SR * 4; f = np.fft.rfftfreq(n, 1 / SR); acc = np.zeros(n // 2 + 1); k = 0
    for i in range(0, len(x) - n, n):
        acc += np.abs(np.fft.rfft(x[i:i + n] * np.hanning(n))) ** 2; k += 1
    if not k:
        return None
    P = 10 * np.log10(acc / k + 1e-20); m = (f >= lo) & (f <= hi)
    i = int(np.argmax(P[m])); pk = float(f[m][i]); prom = float(P[m][i] - np.median(P[m]))
    half = f[m][P[m] > P[m][i] - 6]
    width = float(half.max() - half.min()) if len(half) else 99.0
    return pk if prom >= prominence_db and width <= max_width_hz else None


def notch_tone(x, tone):
    """Two 1.5 Hz notches at the tone and a 2 Hz notch at its second harmonic (the operator approved on C0116 by ear: tone
    -32 dB, harmonic -12 dB, voice bands within 0.2 dB). Static filters only, no noise reduction."""
    import subprocess as sp
    af = (f"bandreject=f={tone:.2f}:width_type=h:w=1.5,bandreject=f={tone:.2f}:width_type=h:w=1.5,"
          f"bandreject=f={2 * tone:.2f}:width_type=h:w=2")
    return np.frombuffer(sp.run(["ffmpeg", "-v", "error", "-f", "f64le", "-ar", str(SR), "-ac", "1", "-i", "-", "-af", af,
                                 "-f", "f64le", "-"], input=x.astype(np.float64).tobytes(), capture_output=True, check=True).stdout, np.float64)
