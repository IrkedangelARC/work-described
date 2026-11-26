#
#  Copyright (c) 2025-2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

import threading
from typing import Optional

import numpy as np
import sounddevice as sd


class AudioCapture:
    def __init__(self, sample_rate: int = 16000, device: Optional[int] = None, chunk_seconds: float = 0.5):
        self.sample_rate = sample_rate
        self.device = device
        self.blocksize = int(sample_rate * chunk_seconds)
        self._chunks: list[np.ndarray] = []
        self._lock = threading.Lock()
        self._stream: Optional[sd.InputStream] = None

    def _callback(self, indata, frames, time_info, status):
        if status:
            print(f"[audio] status: {status}")
        with self._lock:
            self._chunks.append(indata[:, 0].copy().astype(np.float32))

    def start(self) -> None:
        self._stream = sd.InputStream(
            samplerate=self.sample_rate,
            channels=1,
            dtype="float32",
            device=self.device,
            blocksize=self.blocksize,
            callback=self._callback,
        )
        self._stream.start()

    def stop(self) -> None:
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None

    def drain(self) -> np.ndarray:
        with self._lock:
            if not self._chunks:
                return np.zeros(0, dtype=np.float32)
            out = np.concatenate(self._chunks)
            self._chunks = []
        return out
