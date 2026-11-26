#!/usr/bin/env python3
"""
arc_transcribe.py — Standardized batch transcription for float32 WAV folders.

Pipeline per .WAV file:
  1. ffmpeg loudnorm (EBU R128, I=-16 LUFS, TP=-1.5 dBTP, LRA=11)  →  <name>.mp3
  2. faster-whisper large-v3 (CPU int8, VAD on, no context feedback) → <name>.srt
  3. Pause-aware paragraph reflow                                    → <name>.txt

Outputs land next to the source WAV unless --out is given.
Existing outputs are skipped (idempotent). Use --force to re-process.

Recipe is the config proven on a 2026-05-06 job.

Usage:
  ./arc_transcribe.py /path/to/folder
  ./arc_transcribe.py /path/to/folder --out /path/to/transcripts
  ./arc_transcribe.py file.wav                       # single file works too
  ./arc_transcribe.py /path --mp3-only               # skip transcription
  ./arc_transcribe.py /path --transcribe-only        # skip MP3 (assumes mp3 exists)
  ./arc_transcribe.py /path --force                  # overwrite existing outputs
  ./arc_transcribe.py /path --language es            # non-English

Requires: ffmpeg on PATH, faster-whisper installed.
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

# ---- Loudness target (EBU R128, broadcast / podcast standard) ----
LOUDNORM_I = -16        # integrated LUFS target
LOUDNORM_TP = -1.5      # true peak ceiling, dBTP
LOUDNORM_LRA = 11       # loudness range target

# ---- MP3 encode ----
MP3_BITRATE = "192k"
MP3_SAMPLE_RATE = 44100

# ---- Whisper ----
WHISPER_MODEL = "large-v3"
WHISPER_DEVICE = "cpu"
WHISPER_COMPUTE = "int8"

# ---- Paragraph reflow (matches clean_transcript.py from an earlier job) ----
PAUSE_THRESHOLD = 0.8
LONG_PAUSE = 2.0
MIN_LEN_FOR_BREAK = 200
SOFT_CAP = 500
HARD_CAP = 800
RUNAWAY_CAP = 1500
SENT_END = re.compile(r"[.!?][\"')\]]?\s*$")


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def find_wavs(target: Path) -> list[Path]:
    if target.is_file():
        return [target] if target.suffix.lower() == ".wav" else []
    return sorted(p for p in target.iterdir() if p.is_file() and p.suffix.lower() == ".wav")


def ffmpeg_loudnorm_to_mp3(src: Path, dst: Path) -> None:
    """Single-pass loudnorm → MP3. Single pass is fine for speech archive use."""
    af = f"loudnorm=I={LOUDNORM_I}:LRA={LOUDNORM_LRA}:TP={LOUDNORM_TP}"
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "warning", "-y",
        "-i", str(src),
        "-af", af,
        "-ar", str(MP3_SAMPLE_RATE),
        "-c:a", "libmp3lame",
        "-b:a", MP3_BITRATE,
        str(dst),
    ]
    subprocess.run(cmd, check=True)


def fmt_srt_ts(seconds: float) -> str:
    ms = int((seconds % 1) * 1000)
    s = int(seconds) % 60
    m = (int(seconds) // 60) % 60
    h = int(seconds) // 3600
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def transcribe(audio: Path, srt_out: Path, language: str) -> None:
    from faster_whisper import WhisperModel

    log(f"Loading {WHISPER_MODEL} ({WHISPER_DEVICE}/{WHISPER_COMPUTE})…")
    model = WhisperModel(WHISPER_MODEL, device=WHISPER_DEVICE, compute_type=WHISPER_COMPUTE)

    log(f"Transcribing {audio.name}…")
    t0 = time.time()
    segments, info = model.transcribe(
        str(audio),
        language=language,
        beam_size=5,
        vad_filter=True,
        vad_parameters=dict(min_silence_duration_ms=500, threshold=0.5),
        condition_on_previous_text=False,  # PREVENTS LOOP HALLUCINATION
        temperature=[0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
        compression_ratio_threshold=2.4,
        log_prob_threshold=-1.0,
        no_speech_threshold=0.6,
        word_timestamps=False,
    )
    log(f"  duration={info.duration:.1f}s, lang={info.language} ({info.language_probability:.2f})")

    srt_lines: list[str] = []
    n = 0
    last_print = time.time()
    for seg in segments:
        n += 1
        srt_lines.append(f"{n}\n{fmt_srt_ts(seg.start)} --> {fmt_srt_ts(seg.end)}\n{seg.text.strip()}\n")
        if time.time() - last_print > 30:
            elapsed = time.time() - t0
            pct = (seg.end / info.duration) * 100 if info.duration else 0
            rt = seg.end / elapsed if elapsed > 0 else 0
            log(f"  seg {n} @ {seg.end:.0f}s/{info.duration:.0f}s ({pct:.1f}%), {rt:.1f}x realtime")
            last_print = time.time()

    elapsed = time.time() - t0
    rt = info.duration / elapsed if elapsed > 0 else 0
    log(f"  done: {n} segments, {elapsed:.0f}s wall ({rt:.1f}x realtime)")
    srt_out.write_text("\n".join(srt_lines), encoding="utf-8")


def parse_srt_segments(srt_path: Path) -> list[tuple[float, float, str]]:
    def parse_ts(ts: str) -> float:
        h, m, s_ms = ts.split(":")
        s, ms = s_ms.split(",")
        return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000.0

    blocks = re.split(r"\n\s*\n", srt_path.read_text(encoding="utf-8").strip())
    segs: list[tuple[float, float, str]] = []
    for b in blocks:
        lines = b.strip().splitlines()
        if len(lines) < 3:
            continue
        m = re.match(r"([\d:,]+) --> ([\d:,]+)", lines[1])
        if not m:
            continue
        text = " ".join(line.strip() for line in lines[2:]).strip()
        if text:
            segs.append((parse_ts(m.group(1)), parse_ts(m.group(2)), text))
    return segs


def reflow_to_paragraphs(segs: list[tuple[float, float, str]]) -> list[str]:
    paragraphs: list[str] = []
    buf: list[str] = []
    buf_chars = 0
    for i, (_start, end, text) in enumerate(segs):
        buf.append(text)
        buf_chars += len(text) + 1
        if i + 1 >= len(segs):
            break
        next_start = segs[i + 1][0]
        gap = next_start - end
        ends_sentence = bool(SENT_END.search(text))

        should_break = False
        if gap >= LONG_PAUSE:
            should_break = True
        elif buf_chars >= HARD_CAP and ends_sentence:
            should_break = True
        elif buf_chars >= HARD_CAP and gap >= 0.3:
            should_break = True
        elif buf_chars >= RUNAWAY_CAP:
            should_break = True
        elif buf_chars >= SOFT_CAP and gap >= 0.3 and ends_sentence:
            should_break = True
        elif buf_chars >= MIN_LEN_FOR_BREAK and gap >= PAUSE_THRESHOLD and ends_sentence:
            should_break = True

        if should_break:
            paragraphs.append(" ".join(buf))
            buf, buf_chars = [], 0

    if buf:
        paragraphs.append(" ".join(buf))

    return [re.sub(r"\s+", " ", p).strip() for p in paragraphs]


def write_paragraph_txt(srt_path: Path, txt_out: Path, source_name: str) -> None:
    segs = parse_srt_segments(srt_path)
    paragraphs = reflow_to_paragraphs(segs)
    header = (
        f"Source: {source_name}\n"
        f"Engine: faster-whisper {WHISPER_MODEL}, Silero VAD, condition_on_previous_text=False\n"
        f"Loudness: EBU R128 (I={LOUDNORM_I} LUFS, TP={LOUDNORM_TP} dBTP, LRA={LOUDNORM_LRA})\n"
        f"Paragraphs: audio-pause-aware (driven by source-audio silences, not arbitrary length).\n\n"
    )
    txt_out.write_text(header + "\n\n".join(paragraphs) + "\n", encoding="utf-8")
    sizes = [len(p) for p in paragraphs] or [0]
    log(f"  wrote {txt_out.name} — {len(paragraphs)} paragraphs, avg {sum(sizes)//len(sizes)} chars")


def process_one(
    src: Path, out_dir: Path, *, mp3_only: bool, transcribe_only: bool,
    force: bool, language: str,
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    mp3 = out_dir / (src.stem + ".mp3")
    srt = out_dir / (src.stem + ".srt")
    txt = out_dir / (src.stem + ".txt")

    log(f"=== {src.name} ===")

    if not transcribe_only:
        if mp3.exists() and not force:
            log(f"  mp3 exists, skipping (use --force to overwrite): {mp3.name}")
        else:
            log(f"  ffmpeg loudnorm → {mp3.name}")
            ffmpeg_loudnorm_to_mp3(src, mp3)

    if mp3_only:
        return

    if not mp3.exists():
        raise FileNotFoundError(f"MP3 missing for transcription: {mp3}")

    if srt.exists() and txt.exists() and not force:
        log(f"  transcript exists, skipping (use --force to overwrite): {srt.name}")
        return

    transcribe(mp3, srt, language=language)
    write_paragraph_txt(srt, txt, src.name)


def main() -> int:
    ap = argparse.ArgumentParser(description="Standardized batch transcription for float32 WAV folders.")
    ap.add_argument("path", type=Path, help="Folder of .WAV files (or a single .WAV)")
    ap.add_argument("--out", type=Path, default=None,
                    help="Output directory (default: alongside source files)")
    ap.add_argument("--language", default="en", help="Whisper language code (default: en)")
    ap.add_argument("--mp3-only", action="store_true", help="Run loudnorm/MP3 step only")
    ap.add_argument("--transcribe-only", action="store_true", help="Skip MP3 step (MP3 must already exist)")
    ap.add_argument("--force", action="store_true", help="Overwrite existing outputs")
    args = ap.parse_args()

    if args.mp3_only and args.transcribe_only:
        print("error: --mp3-only and --transcribe-only are mutually exclusive", file=sys.stderr)
        return 2

    if shutil.which("ffmpeg") is None:
        print("error: ffmpeg not found on PATH", file=sys.stderr)
        return 2

    if not args.path.exists():
        print(f"error: path does not exist: {args.path}", file=sys.stderr)
        return 2

    wavs = find_wavs(args.path)
    if not wavs:
        print(f"error: no .WAV files found in {args.path}", file=sys.stderr)
        return 2

    log(f"Found {len(wavs)} WAV file(s)")
    for w in wavs:
        out_dir = args.out if args.out else w.parent
        try:
            process_one(
                w, out_dir,
                mp3_only=args.mp3_only,
                transcribe_only=args.transcribe_only,
                force=args.force,
                language=args.language,
            )
        except subprocess.CalledProcessError as e:
            log(f"  FFMPEG FAILED on {w.name}: {e}")
        except Exception as e:
            log(f"  FAILED on {w.name}: {e}")

    log("All done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
