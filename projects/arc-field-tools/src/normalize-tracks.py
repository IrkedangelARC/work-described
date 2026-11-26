#!/usr/bin/env python3
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""
RMS-normalize multitrack WAV files.
Boosts under-recorded tracks based on average loudness (RMS), not peak.
Applies a hard limiter at -1 dBFS to prevent clipping.
Does not alter timing, length, sample rate, or channel count.

Usage:
    # Preview first 5 minutes of each track before full conversion
    python3 normalize-tracks.py /path/to/wavs --preview

    # Full conversion (default target RMS: -18 dBFS)
    python3 normalize-tracks.py /path/to/wavs

    # Custom target RMS and ceiling
    python3 normalize-tracks.py /path/to/wavs -t -14 --ceiling -0.5
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import soundfile as sf


def db_to_linear(db: float) -> float:
    return 10 ** (db / 20)


def linear_to_db(linear: float) -> float:
    if linear <= 0:
        return -np.inf
    return 20 * np.log10(linear)


def compute_rms_db(audio: np.ndarray) -> float:
    rms = np.sqrt(np.mean(audio ** 2))
    return linear_to_db(rms)


def rms_normalize(audio: np.ndarray, target_rms_db: float, ceiling_db: float) -> tuple[np.ndarray, dict]:
    current_rms = np.sqrt(np.mean(audio ** 2))
    current_rms_db = linear_to_db(current_rms)
    current_peak_db = linear_to_db(np.max(np.abs(audio)))

    if current_rms <= 0:
        return audio, {"gain_db": 0, "peak_before": current_peak_db,
                       "peak_after": current_peak_db, "rms_before": current_rms_db,
                       "rms_after": current_rms_db, "clipped_samples": 0}

    gain_db = target_rms_db - current_rms_db
    gain_linear = db_to_linear(gain_db)

    boosted = audio * gain_linear

    ceiling_linear = db_to_linear(ceiling_db)
    clipped = np.count_nonzero(np.abs(boosted) > ceiling_linear)
    boosted = np.clip(boosted, -ceiling_linear, ceiling_linear)

    stats = {
        "gain_db": gain_db,
        "peak_before": current_peak_db,
        "peak_after": linear_to_db(np.max(np.abs(boosted))),
        "rms_before": current_rms_db,
        "rms_after": compute_rms_db(boosted),
        "clipped_samples": clipped,
    }
    return boosted, stats


def process_file(wav: Path, output_dir: Path, target_rms_db: float,
                 ceiling_db: float, preview_seconds: int | None, info: sf.SoundFile):
    samplerate = info.samplerate
    subtype = info.subtype

    if preview_seconds:
        stop = samplerate * preview_seconds
        audio, _ = sf.read(wav, dtype="float64", stop=stop)
    else:
        audio, _ = sf.read(wav, dtype="float64")

    normalized, stats = rms_normalize(audio, target_rms_db, ceiling_db)

    if preview_seconds:
        dest = output_dir / f"{wav.stem}_preview{wav.suffix}"
    else:
        dest = output_dir / wav.name

    sf.write(dest, normalized, samplerate, subtype=subtype)

    samples = audio.shape[0]
    channels = audio.shape[1] if audio.ndim > 1 else 1
    duration_min = samples / samplerate / 60
    clip_pct = (stats["clipped_samples"] / samples) * 100

    print(f"  {wav.name:<20} "
          f"RMS: {stats['rms_before']:>+6.1f} -> {stats['rms_after']:>+5.1f} dBFS  "
          f"Peak: {stats['peak_before']:>+6.1f} -> {stats['peak_after']:>+5.1f} dBFS  "
          f"Gain: {stats['gain_db']:>+5.1f} dB  "
          f"Clip: {clip_pct:.2f}%  "
          f"{channels}ch {duration_min:.1f}min")


def process_folder(input_dir: Path, output_dir: Path, target_rms_db: float,
                   ceiling_db: float, preview_seconds: int | None):
    wav_files = sorted(f for f in input_dir.glob("*.wav") if not f.name.startswith("._"))
    wav_files += sorted(f for f in input_dir.glob("*.WAV") if not f.name.startswith("._"))
    if not wav_files:
        print(f"No WAV files found in {input_dir}")
        sys.exit(1)

    output_dir.mkdir(parents=True, exist_ok=True)

    mode = f"PREVIEW ({preview_seconds // 60}min sample)" if preview_seconds else "FULL"
    print(f"Mode:        {mode}")
    print(f"Files:       {len(wav_files)}")
    print(f"Target RMS:  {target_rms_db} dBFS")
    print(f"Ceiling:     {ceiling_db} dBFS")
    print(f"Output:      {output_dir}")
    print("-" * 110)

    for wav in wav_files:
        info = sf.info(wav)
        process_file(wav, output_dir, target_rms_db, ceiling_db, preview_seconds, info)

    print("-" * 110)
    if preview_seconds:
        print(f"Preview complete. Check files in {output_dir}")
        print(f"If levels look good, run again without --preview for full conversion.")
    else:
        print("Done. All files retain original length, sample rate, and channel count.")


def main():
    parser = argparse.ArgumentParser(
        description="RMS-normalize multitrack WAV files with limiter."
    )
    parser.add_argument("input", type=Path, help="Folder containing WAV files")
    parser.add_argument(
        "-t", "--target", type=float, default=-18.0,
        help="Target RMS in dBFS (default: -18.0, broadcast standard)"
    )
    parser.add_argument(
        "--ceiling", type=float, default=-1.0,
        help="Hard limiter ceiling in dBFS (default: -1.0)"
    )
    parser.add_argument(
        "-o", "--output", type=Path, default=None,
        help="Output folder (default: <input>_normalized)"
    )
    parser.add_argument(
        "--preview", action="store_true",
        help="Output only a 5-minute sample of each file for review"
    )
    parser.add_argument(
        "--preview-length", type=int, default=300,
        help="Preview length in seconds (default: 300 = 5 min)"
    )
    args = parser.parse_args()

    if not args.input.is_dir():
        print(f"Error: {args.input} is not a directory")
        sys.exit(1)

    output_dir = args.output or Path(f"{args.input}_normalized")
    preview_sec = args.preview_length if args.preview else None
    process_folder(args.input, output_dir, args.target, args.ceiling, preview_sec)


if __name__ == "__main__":
    main()
