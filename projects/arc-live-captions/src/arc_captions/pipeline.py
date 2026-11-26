#
#  Copyright (c) 2025-2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

import time
from pathlib import Path

import numpy as np

from .audio import AudioCapture
from .config import Config
from .corrector import NameCorrector
from .ingestion import YouTubeCaptions
from .transcriber import Transcriber, build_initial_prompt


def load_names(path: str) -> list[str]:
    p = Path(path)
    if not p.exists():
        print(f"[pipeline] names file not found: {p}")
        return []
    out = []
    for line in p.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line)
    return out


def run(config_path: str) -> None:
    cfg = Config.load(config_path)
    names = load_names(cfg.names_file)
    print(f"[pipeline] loaded {len(names)} names from {cfg.names_file}")

    initial_prompt = build_initial_prompt(names)
    if initial_prompt:
        print(f"[pipeline] whisper prompt: {initial_prompt[:120]}...")

    audio = AudioCapture(
        sample_rate=cfg.audio.sample_rate,
        device=cfg.audio.device,
        chunk_seconds=cfg.audio.chunk_seconds,
    )

    print(f"[pipeline] loading whisper {cfg.whisper.model_size} ({cfg.whisper.compute_type})...")
    transcriber = Transcriber(
        model_size=cfg.whisper.model_size,
        compute_type=cfg.whisper.compute_type,
        device=cfg.whisper.device,
        language=cfg.whisper.language,
        beam_size=cfg.whisper.beam_size,
        vad_filter=cfg.whisper.vad_filter,
        initial_prompt=initial_prompt,
    )

    corrector = None
    if cfg.corrector.enabled and names:
        corrector = NameCorrector(
            ollama_url=cfg.corrector.ollama_url,
            model=cfg.corrector.model,
            names=names,
            timeout_s=cfg.corrector.timeout_s,
        )
        print(f"[pipeline] corrector: {cfg.corrector.model} via {cfg.corrector.ollama_url}")

    ingestion = None
    if cfg.ingestion.enabled and cfg.ingestion.youtube_url:
        ingestion = YouTubeCaptions(cfg.ingestion.youtube_url)
        print("[pipeline] youtube ingestion enabled")
    else:
        print("[pipeline] youtube ingestion disabled (stdout only)")

    sr = cfg.audio.sample_rate
    min_samples = int(sr * cfg.streaming.min_buffer_seconds)
    max_samples = int(sr * cfg.streaming.max_buffer_seconds)

    audio.start()
    print("[pipeline] capturing. Ctrl+C to stop.")

    buffer = np.zeros(0, dtype=np.float32)

    try:
        while True:
            time.sleep(cfg.streaming.hop_seconds)
            new = audio.drain()
            if len(new) > 0:
                buffer = np.concatenate([buffer, new])

            if len(buffer) < min_samples:
                continue

            t0 = time.time()
            segments = transcriber.transcribe(buffer)
            elapsed = time.time() - t0

            if not segments:
                if len(buffer) > max_samples:
                    drop = len(buffer) - int(sr * 5.0)
                    buffer = buffer[drop:]
                continue

            if len(segments) > 1:
                committed = segments[:-1]
                trim_sample = int(segments[-1].start * sr)
                trim_sample = max(0, min(trim_sample, len(buffer)))
                _emit(committed, corrector, ingestion, elapsed)
                buffer = buffer[trim_sample:]
            else:
                # Single segment, might still be in progress. Force-commit if buffer overflowing.
                if len(buffer) > max_samples:
                    _emit(segments, corrector, ingestion, elapsed)
                    buffer = np.zeros(0, dtype=np.float32)

    except KeyboardInterrupt:
        print("\n[pipeline] stopping...")
    finally:
        audio.stop()
        if corrector:
            corrector.close()
        if ingestion:
            ingestion.close()


def _emit(segments, corrector, ingestion, whisper_elapsed: float) -> None:
    for seg in segments:
        line = seg.text.strip()
        if not line:
            continue
        final = corrector.correct(line) if corrector else line
        ts = time.strftime("%H:%M:%S")
        print(f"[{ts}] (whisper {whisper_elapsed:.2f}s) {final}")
        if ingestion:
            ingestion.send(final)
