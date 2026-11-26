#
#  Copyright (c) 2025-2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

from typing import Optional

import numpy as np
from faster_whisper import WhisperModel


class Transcriber:
    def __init__(
        self,
        model_size: str = "large-v3",
        compute_type: str = "int8",
        device: str = "cpu",
        language: str = "en",
        beam_size: int = 5,
        vad_filter: bool = True,
        initial_prompt: Optional[str] = None,
    ):
        self.model = WhisperModel(model_size, device=device, compute_type=compute_type)
        self.language = language
        self.beam_size = beam_size
        self.vad_filter = vad_filter
        self.initial_prompt = initial_prompt

    def transcribe(self, audio: np.ndarray) -> list:
        segments, _ = self.model.transcribe(
            audio,
            language=self.language,
            beam_size=self.beam_size,
            vad_filter=self.vad_filter,
            initial_prompt=self.initial_prompt,
            condition_on_previous_text=False,
        )
        return list(segments)


def build_initial_prompt(names: list[str], max_chars: int = 800) -> Optional[str]:
    if not names:
        return None
    header = "Graduation ceremony. Names and terms include: "
    out = header
    for name in names:
        candidate = out + name + ", "
        if len(candidate) > max_chars:
            break
        out = candidate
    return out.rstrip(", ")
