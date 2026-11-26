"""ingest stage (P1.2): probe every source and measure every audio channel. Read-only on media.

Implements LESSONS L1 (measure channels, never trust labels), L2 (recorder clocks: creation date vs show date),
L3 (recorder from make/model tags), L4 (clean-aperture crop -> decode with -apply_cropping none), L5 (untagged colour).
"""
from __future__ import annotations
import datetime as dt, json, subprocess
from pathlib import Path
import numpy as np
from .stages import stage

DEAD_DB, QUIET_DB = -80.0, -50.0
WINDOW_S, POINTS = 20.0, (0.1, 0.5, 0.9)


def source_paths(job) -> list[Path]:
    return [job.path(k) for k in job.sources]


def probe(path: Path) -> dict:
    o = subprocess.run(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(path)],
                       capture_output=True, text=True)
    return json.loads(o.stdout or "{}")


def recorder(fmt_tags: dict, v: dict | None) -> str:
    t = {k.lower(): v for k, v in fmt_tags.items()}
    make = t.get("make") or t.get("com.apple.proapps.image.{tiff}.make") or t.get("make-eng") or ""
    model = t.get("com.apple.proapps.image.{tiff}.model") or t.get("model") or ""
    enc = t.get("encoder") or (v or {}).get("tags", {}).get("encoder", "")
    derived = " [derived: re-written by ffmpeg, tags may be inherited]" if str(t.get("encoder", "")).startswith("Lavf") else ""
    if make or model:
        return f"{make} {model}".strip() + derived
    return f"unknown ({enc})" if enc else "unknown"


def channel_rms(path: Path, streams: list[dict], dur: float) -> list[dict]:
    """RMS dBFS of every channel of every audio stream at POINTS of the file (one ffmpeg decode per point)."""
    if not streams:
        return []
    chans = [(s["index"], c) for s in streams for c in range(int(s.get("channels") or 1))]
    n_in = len(streams)
    graph = ("".join(f"[0:a:{i}]" for i in range(n_in)) + f"amerge=inputs={n_in}[a]") if n_in > 1 else None
    rows = {k: [] for k in chans}
    for frac in POINTS:
        t = max(0.0, min(dur - WINDOW_S, dur * frac)) if dur else 0.0
        cmd = ["ffmpeg", "-v", "error", "-ss", f"{t:.2f}", "-t", f"{WINDOW_S}", "-i", str(path)]
        cmd += (["-filter_complex", graph, "-map", "[a]"] if graph else ["-map", "0:a:0"])
        cmd += ["-ac", str(len(chans)), "-ar", "16000", "-f", "f32le", "-"]
        raw = subprocess.run(cmd, capture_output=True).stdout
        x = np.frombuffer(raw, np.float32)
        if x.size < len(chans):
            for k in chans: rows[k].append(None)
            continue
        x = x[: x.size // len(chans) * len(chans)].reshape(-1, len(chans))
        r = 20 * np.log10(np.sqrt((x.astype(np.float64) ** 2).mean(0)) + 1e-12)
        for k, v in zip(chans, r):
            rows[k].append(round(float(v), 1))
    out = []
    for (si, c), vals in rows.items():
        live = [v for v in vals if v is not None]
        peak = max(live) if live else None
        state = "unread" if peak is None else "dead" if peak < DEAD_DB else "quiet" if peak < QUIET_DB else "live"
        out.append({"stream": si, "channel": c, "rms_db": vals, "state": state})
    return out


def probe_source(key: str, path: Path, show_date: dt.date | None) -> dict:
    if not path.exists():
        return {"source": key, "path": str(path), "missing": True}
    pr = probe(path); fmt = pr.get("format", {}); tags = fmt.get("tags", {})
    vs = next((s for s in pr.get("streams", []) if s.get("codec_type") == "video"), None)
    aus = [s for s in pr.get("streams", []) if s.get("codec_type") == "audio"]
    dur = float(fmt.get("duration") or 0)
    r = {"source": key, "path": str(path), "size": int(fmt.get("size") or 0), "duration_s": round(dur, 3),
         "recorder": recorder(tags, vs), "timecode": tags.get("timecode") or next(
             (s.get("tags", {}).get("timecode") for s in pr.get("streams", []) if s.get("tags", {}).get("timecode")), None),
         "creation_time": tags.get("creation_time"), "flags": []}
    if vs:
        crop = next((d for d in vs.get("side_data_list", []) if d.get("side_data_type") == "Frame Cropping"), None)
        r["video"] = {k: vs.get(k) for k in ("codec_name", "width", "height", "r_frame_rate", "pix_fmt", "field_order",
                                             "color_primaries", "color_transfer", "color_space")}
        if crop:
            r["video"]["clean_aperture_crop"] = {k: crop[k] for k in ("crop_left", "crop_right", "crop_top", "crop_bottom")}
            r["flags"].append("clean-aperture crop: decode with -apply_cropping none (L4)")
        if not vs.get("color_primaries") or vs.get("color_primaries") in ("unknown", "reserved"):
            r["flags"].append("colour primaries untagged (L5): tag before Resolve / analysis")
    if r["creation_time"] and show_date:
        try:
            cd = dt.date.fromisoformat(r["creation_time"][:10])
            if abs((cd - show_date).days) > 2:
                r["flags"].append(f"recorder clock untrusted: file date {cd} vs show {show_date} (L2)")
        except ValueError:
            pass
    r["audio"] = channel_rms(path, aus, dur)
    if aus and not any(c["state"] == "live" for c in r["audio"]):
        r["flags"].append("NO live audio channel (L1)")
    return r


def report(rows: list[dict]) -> str:
    L = ["| Source | Recorder | Video | Dur | Audio live/dead | Flags |", "|---|---|---|---|---|---|"]
    for r in rows:
        if r.get("missing"):
            L.append(f"| {r['source']} | MISSING | | | | {r['path']} |"); continue
        v = r.get("video") or {}
        vid = f"{v.get('codec_name','')} {v.get('width','')}x{v.get('height','')} {v.get('r_frame_rate','')}" if v else "audio only"
        live = [f"{c['stream']}.{c['channel']}" for c in r["audio"] if c["state"] == "live"]
        dead = sum(c["state"] == "dead" for c in r["audio"]); quiet = sum(c["state"] == "quiet" for c in r["audio"])
        a = (f"live {', '.join(live) or 'none'}; quiet {quiet}; dead {dead}" if r["audio"] else "no audio streams")
        L.append(f"| {r['source']} | {r['recorder']} | {vid} | {r['duration_s'] / 60:.1f} min | {a} | {'; '.join(r['flags'])} |")
    return "\n".join(L) + "\n"


@stage("ingest", inputs=source_paths)
def run(job, work: Path) -> dict:
    sd = job.raw.get("date")
    show = dt.date.fromisoformat(str(sd)) if sd else None
    rows = [probe_source(k, job.path(k), show) for k in job.sources]
    (work / "ingest.md").write_text(f"# Ingest report {job.arc}\n\n" + report(rows))
    return {"sources": rows}
