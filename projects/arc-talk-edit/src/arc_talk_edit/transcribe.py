"""transcribe stage (P1.4): word-timed transcript + pause truth from the audio (LESSONS L17, L18, L23).

Recipe = the one JOB-0000 used (transcripts/words/mlx.log): mlx_whisper, mlx-community/whisper-large-v3-turbo,
word_timestamps, temperature 0, condition_on_previous_text False. Audio = the job's `transcribe:` channel, else the sync
reference channel (16 kHz mono, shared cache with the sync stage). 2 h timeout. Pauses from ffmpeg silencedetect.
"""
from __future__ import annotations
import json, shutil, subprocess
from pathlib import Path
from .stages import stage
from .sync import extract
from .scans import silences

MODEL = "mlx-community/whisper-large-v3-turbo"


def _spec(job, work: Path) -> dict:
    if job.raw.get("transcribe"):
        return job.raw["transcribe"]
    s = json.loads((work / "sync.json").read_text())["ref"]
    return {"source": s["source"], "stream": s.get("stream", 0), "channel": s.get("channel", 0)}


def _inputs(job):
    return [job.path(k) for k in job.sources]


@stage("transcribe", inputs=_inputs)
def run(job, work: Path) -> dict:
    sp = _spec(job, work)
    media = Path(job.raw.get("media_root", "")).expanduser()
    src = job.sources[sp["source"]]
    wav = extract(job.path(sp["source"]), work / "audio" / f"{sp['source']}_a{sp.get('stream', 0)}c{sp.get('channel', 0)}.16k.wav",
                  sp.get("stream", 0), sp.get("channel", 0))
    out_dir = work / "transcript"; out_dir.mkdir(exist_ok=True)
    exe = shutil.which("mlx_whisper") or str(Path.home() / "Library/Python/3.13/bin/mlx_whisper")
    cmd = [exe, str(wav), "--model", MODEL, "--output-dir", str(out_dir), "--output-name", "words",
           "--output-format", "json", "--word-timestamps", "True", "--temperature", "0",
           "--condition-on-previous-text", "False", "--verbose", "False"]
    if job.raw.get("language"):
        cmd += ["--language", job.raw["language"]]
    with open(out_dir / "mlx.log", "w") as log:
        subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=7200, check=True)
    words = json.loads((out_dir / "words.json").read_text())
    nwords = sum(len(sg.get("words", [])) for sg in words.get("segments", []))
    sil = silences(wav)
    (out_dir / "silences.json").write_text(json.dumps(sil))
    return {"audio": sp, "clock": src.clock, "model": MODEL, "segments": len(words.get("segments", [])), "words": nwords,
            "language": words.get("language"), "silences": len(sil), "files": [str(out_dir / "words.json"), str(out_dir / "silences.json")]}
