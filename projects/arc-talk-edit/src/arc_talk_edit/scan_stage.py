"""scans stage (P1.5): every scan the job's footage needs, one report (work/<ARC>/scans.md).

Per camera (video sources whose role is not screen/PiP, or `scans.cameras`): 2 s motion bins over the program window
-> whips (> WHIP, LESSONS L40), face presence every `face_step_s` (L41 face >= 75%). Plus, when configured in job.yaml
`scans:`: dropouts (L7), screen map (L41/L47), long pauses (L37). Times are reported in the program clock.
"""
from __future__ import annotations
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import numpy as np
from .stages import stage
from . import scans, screen


def _cameras(job) -> list[str]:
    cfg = (job.raw.get("scans") or {}).get("cameras")
    if cfg:
        return cfg
    skip = ("screen", "pip", "not used")
    return [k for k, s in job.sources.items() if not any(w in (s.role or "").lower() for w in skip)
            and Path(s.path).suffix.lower() in (".mov", ".mp4", ".mxf")]


def _inputs(job):
    return [job.path(k) for k in job.sources]


def _fmt(t: float) -> str:
    m, s = divmod(t, 60); h, m = divmod(m, 60)
    return f"{int(h)}:{int(m):02d}:{s:05.2f}"


@stage("scans", inputs=_inputs)
def run(job, work: Path) -> dict:
    cfg = job.raw.get("scans") or {}
    media = Path(job.raw.get("media_root", "")).expanduser()
    pc = job.program_clock
    p_in, p_out = job.program.get("in"), job.program.get("out")
    out, rep = {"cameras": {}}, [f"# Scan report {job.arc}", ""]
    step = cfg.get("face_step_s", 4.0)
    rep += [f"## Cameras (program window; times on the {pc} clock)", "",
            "| Camera | Whip bins > %.0f | First whips | Face present |" % scans.WHIP, "|---|---|---|---|"]
    for cam in _cameras(job):
        src = job.sources[cam]; path = job.path(cam)
        if not path.exists() or p_in is None:
            continue
        a = job.convert(p_in, pc, src.clock); b = job.convert(p_out, pc, src.clock)
        bins = scans.whip_bins(path, max(0.0, a), b - a)
        whips = [round(p_in + 2 * i, 1) for i, v in enumerate(bins) if v > scans.WHIP]
        ts = np.arange(p_in, p_out, step)
        with ThreadPoolExecutor(12) as ex:
            faces = list(ex.map(lambda t: scans.face_at(path, job.convert(float(t), pc, src.clock)), ts))
        pres = sum(f is not None for f in faces) / max(1, len(faces))
        out["cameras"][cam] = {"whip_bins": [round(v, 2) for v in bins], "whips_at": whips,
                               "faces": [[round(float(t), 2), *(f or (None, None, None))] for t, f in zip(ts, faces)],
                               "face_presence": round(pres, 3)}
        rep.append(f"| {cam} | {len(whips)} | {', '.join(_fmt(t) for t in whips[:6])}{' ...' if len(whips) > 6 else ''} | {pres:.0%} |")
    if "dropouts" in cfg:
        d = scans.run_dropouts(job, work)
        out["dropouts"] = {"frames": d["frames"], "bad": len(d["bad"]), "clusters": d["clusters"]}
        rep += ["", f"## Screen dropouts: {len(d['bad'])} bad frames in {len(d['clusters'])} clusters (repair before editing, L7)"]
    if "screen" in cfg:
        sc = dict(cfg["screen"]); src = job.sources[sc.pop("source")]
        gray = Path(sc.pop("cache")) if sc.get("cache") else screen.decode(job.path(cfg["screen"]["source"]), work / "screen_2fps.gray")
        segs = screen.screen_map(gray, **{k: (tuple(v) if isinstance(v, list) else v) for k, v in sc.items()})
        out["screen"] = segs
        rep += ["", f"## Screen map: {len(segs)} content segments; zoom median {np.median([s.get('zoom') or 1 for s in segs]):.2f}"]
    if "pauses" in cfg:
        out["pauses"] = scans.run_pauses(job)
        rep += ["", f"## Long pauses: {out['pauses']['long']} (>= {cfg['pauses'].get('pause_min_s', 2.5)} s), {out['pauses']['long_total_s']} s"]
    (work / "scans.md").write_text("\n".join(rep) + "\n")
    return out
