"""Deliverable loudness: measure, or bring a rendered file to the ARC spec (-14 LUFS integrated, <= -1 dBTP).
A straight Resolve render is NOT loudness-processed (ARC shipped two files at ~-27 LUFS that way). Run this on
every deliverable before upload.

Usage:
  python3 tools/loudness.py measure FILE
  python3 tools/loudness.py deliver RENDER.mp4 [--out FINAL.mp4]
    picture is copied untouched; audio gets a gentle compressor, gain to -14 LUFS and a 4x-oversampled limiter
    (no noise reduction, no expander). Output defaults to RENDER_-14LUFS.mp4. Never overwrites."""
import argparse
import os
import subprocess
import sys
import tempfile

TARGET, WINDOW, PEAK_MAX = -14.0, (-15.5, -13.0), -1.0
COMP = "acompressor=threshold=-26dB:ratio=2:attack=10:release=200:knee=6:makeup=1:detection=rms"
LIMIT = "aresample=192000,alimiter=limit=0.7499:attack=3:release=80:level=disabled:asc=1,aresample=48000"


def measure(f):
    o = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", f, "-vn", "-af", "ebur128=peak=true",
                        "-f", "null", "-"], capture_output=True, text=True).stderr
    if "Summary:" not in o:
        sys.exit(f"ERROR: ffmpeg could not measure {f}:\n{o[-800:]}")
    s = o.split("Summary:")[-1]
    return float(s.split(" I:")[1].split("LUFS")[0]), float(s.split("Peak:")[-1].split("dBFS")[0])


def report(f):
    I, tp = measure(f)
    good = WINDOW[0] <= I <= WINDOW[1] and tp <= PEAK_MAX
    print(f"{os.path.basename(f)}: {I:.1f} LUFS integrated, {tp:.1f} dBTP true peak -> {'IN SPEC' if good else 'OUT OF SPEC'}"
          f" (spec {TARGET} LUFS, window {WINDOW[0]}..{WINDOW[1]}, peak <= {PEAK_MAX})")
    return good


ap = argparse.ArgumentParser()
ap.add_argument("mode", choices=["measure", "deliver"])
ap.add_argument("file")
ap.add_argument("--out")
a = ap.parse_args()

if a.mode == "measure":
    sys.exit(0 if report(a.file) else 2)

out = a.out or os.path.splitext(a.file)[0] + "_-14LUFS.mp4"
if os.path.exists(out):
    sys.exit(f"ERROR: {out} exists; not overwriting")
with tempfile.TemporaryDirectory() as tmp:
    comp = f"{tmp}/comp.wav"
    subprocess.run(["ffmpeg", "-v", "error", "-i", a.file, "-vn", "-af", COMP, "-c:a", "pcm_s24le", comp], check=True)
    gain = TARGET - measure(comp)[0]
    for attempt in range(2):  # the limiter can take a few tenths off; one correction pass
        fin = f"{tmp}/final{attempt}.wav"
        subprocess.run(["ffmpeg", "-v", "error", "-i", comp, "-af", f"volume={gain:.2f}dB,{LIMIT}", "-c:a", "pcm_s24le",
                        fin], check=True)
        I, tp = measure(fin)
        if abs(I - TARGET) <= 0.5:
            break
        gain += TARGET - I
    subprocess.run(["ffmpeg", "-v", "error", "-i", a.file, "-i", fin, "-map", "0:v:0?", "-map", "1:a", "-c:v", "copy",
                    "-c:a", "aac", "-b:a", "320k", "-ar", "48000", "-movflags", "+faststart", out], check=True)
print(f"gain {gain:+.1f} dB after compression -> {out}")
sys.exit(0 if report(out) else 2)
