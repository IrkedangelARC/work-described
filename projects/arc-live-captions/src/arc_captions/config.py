#
#  Copyright (c) 2025-2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional
import yaml

# Model names resolve from a shared model registry (single source of truth):
#   /path/to/model-registry/models.yaml
import sys as _sys
_MODEL_REGISTRY = "/path/to/model-registry"
if _MODEL_REGISTRY not in _sys.path:
    _sys.path.insert(0, _MODEL_REGISTRY)
from model_registry import resolve_safe as _model, resolve_host_safe as _host



@dataclass
class AudioConfig:
    device: Optional[int] = None
    sample_rate: int = 16000
    chunk_seconds: float = 0.5


@dataclass
class WhisperConfig:
    model_size: str = "large-v3"
    compute_type: str = "int8"
    device: str = "cpu"
    language: str = "en"
    beam_size: int = 5
    vad_filter: bool = True


@dataclass
class StreamingConfig:
    hop_seconds: float = 1.5
    max_buffer_seconds: float = 30.0
    min_buffer_seconds: float = 3.0


@dataclass
class CorrectorConfig:
    enabled: bool = True
    ollama_url: str = field(default_factory=_host)
    model: str = field(default_factory=lambda: _model("structured"))
    timeout_s: float = 2.0


@dataclass
class IngestionConfig:
    enabled: bool = False
    youtube_url: str = ""


@dataclass
class Config:
    names_file: str = "names/event_names.txt"
    audio: AudioConfig = field(default_factory=AudioConfig)
    whisper: WhisperConfig = field(default_factory=WhisperConfig)
    streaming: StreamingConfig = field(default_factory=StreamingConfig)
    corrector: CorrectorConfig = field(default_factory=CorrectorConfig)
    ingestion: IngestionConfig = field(default_factory=IngestionConfig)

    @classmethod
    def load(cls, path: str) -> "Config":
        with open(Path(path)) as f:
            data = yaml.safe_load(f) or {}
        return cls(
            names_file=data.get("names_file", cls.names_file),
            audio=AudioConfig(**data.get("audio", {})),
            whisper=WhisperConfig(**data.get("whisper", {})),
            streaming=StreamingConfig(**data.get("streaming", {})),
            corrector=CorrectorConfig(**data.get("corrector", {})),
            ingestion=IngestionConfig(**data.get("ingestion", {})),
        )
