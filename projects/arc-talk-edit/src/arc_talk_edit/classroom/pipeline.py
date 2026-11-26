"""The classroom chain as cached stages: `arc-talk-edit run classroom <job>` (stages.PROFILES["classroom"]).

  classroom_track    colour track of the subject in the tight + wide cameras, and the windows where it is valid
  classroom_people   person detector: the wide camera over the program (who is on stage)
  classroom_pose     pose model (boxes + wrists): tight camera everywhere, wide camera where the colour track is not valid
  classroom_plan     shot choice, holds, fluid-head framing -> work/<ARC>/classroom/column_plan.json
  classroom_column   render the plan to <edit_root>/<ARC>_column.mov
  audio_repair       (arc_talk_edit.audio_repair) repaired + mastered program audio
Then, with Resolve open on the job's project: `arc-talk-edit classroom-build <job> --go` (sbs.py).

Each stage hashes only the job.yaml keys it reads, so e.g. editing the question list re-plans and re-renders but does
not re-run the detector.
"""
from __future__ import annotations
import json
from pathlib import Path

from ..stages import stage
from . import column, config, edit_root, framing, lut_path, questions, track, workdir, write_json


def _cams(job, roles):
    c = config(job)
    return [job.path(c["cameras"][r]["source"]) for r in roles]


def _base(job, c, roles):
    return {"clocks": job.offsets, "program": [job.program.get("in"), job.program.get("out"), job.program_clock],
            "cameras": {r: {k: c["cameras"][r][k] for k in ("source", "band")} for r in roles}}


def _load(job, name):
    return json.loads((workdir(job) / name).read_text())


@stage("classroom_track", inputs=lambda job: _cams(job, ("tight", "wide")), code=(track,),
       config=lambda job: (lambda c: {**_base(job, c, ("tight", "wide")), "track": c["track"], "subject": c["subject"],
                                      "min_h": [c["cameras"][r]["min_h"] for r in ("tight", "wide")]})(config(job)))
def stage_track(job, work: Path) -> dict:
    c = config(job)
    if not c["subject"].get("colour"):                       # nobody to colour-track: just the sample grid
        step = 1 / c["track"]["fps"]
        ts = [round(job.program["in"] + k * step, 2) for k in range(int((job.program["out"] - job.program["in"]) / step) + 1)]
        tr = {r: [[t, None, None, None, None, None] for t in ts] for r in ("tight", "wide")}
        write_json(workdir(job) / "track.json", {"track": tr, "valid": []})
        return {"samples": len(ts), "valid": [], "colour": None}
    tr = track.colour_track(job, c)
    valid = track.valid_windows(job, c, tr)
    write_json(workdir(job) / "track.json", {"track": tr, "valid": valid})
    return {"samples": len(tr["tight"]), "valid": valid, "valid_measured": track.colour_valid(tr, c),
            "found": {r: round(track.found(tr[r], c["cameras"][r]["min_h"]), 3) for r in tr}}


@stage("classroom_people", inputs=lambda job: _cams(job, ("wide",)), code=(track,),
       config=lambda job: (lambda c: {**_base(job, c, ("wide",)), "people": c["people"]})(config(job)))
def stage_people(job, work: Path) -> dict:
    """Everyone the wide camera sees, every 2 s over the program (group shots; the subject's box in wide shots)."""
    c = config(job)
    wide = track.people(job, c, "wide")
    write_json(workdir(job) / "people.json", {"wide": wide})
    return {"wide_samples": len(wide)}


@stage("classroom_pose", inputs=lambda job: [*_cams(job, ("tight", "wide")), workdir(job) / "track.json"], code=(track,),
       config=lambda job: (lambda c: {**_base(job, c, ("tight", "wide")), "pose": c["pose"], "track_fps": c["track"]["fps"],
                                      "pad_s": c["people"]["pad_s"], "valid": c["subject"].get("valid"),
                                      "remote": [[r["in"], r["out"]] for r in c.get("remote") or []]})(config(job)))
def stage_pose(job, work: Path) -> dict:
    """Wrists + boxes: tight camera everywhere (pose.fps where the colour track is valid, the track rate where it is
    not), wide camera only where it is not (to follow a person by continuity)."""
    c = config(job)
    valid = _load(job, "track.json")["valid"]
    inv = _minus(track.invalid_windows(job, valid, c["people"]["pad_s"]), [[r["in"], r["out"]] for r in c.get("remote") or []])
    fast = c["track"]["fps"]
    wide = track.pose(job, c, "wide", [[a, b, fast] for a, b in inv])
    if c["single_camera"]:                                   # one presenter camera: its pose serves both roles
        tight = wide
    else:
        tight_w = [[a, b, fast] for a, b in inv] + [[a, b, c["pose"]["fps"]] for a, b in valid]
        tight = track.pose(job, c, "tight", tight_w)
    write_json(workdir(job) / "pose.json", {"tight": tight, "wide": wide, "untracked": inv})
    return {"tight_samples": len(tight), "wide_samples": len(wide), "untracked": inv}


def _minus(wins: list, cut: list) -> list:
    """Windows `wins` with the windows `cut` removed (remote talks need no presenter tracking)."""
    out = []
    for a, b in wins:
        segs = [[a, b]]
        for x, y in cut:
            segs = [s for p, q in segs for s in ([[p, min(q, x)]] if p < x else []) + ([[max(p, y), q]] if q > y else [])]
        out += [s for s in segs if s[1] - s[0] > 0.5]
    return out


def _slides_cfg(job):
    c = config(job)
    return {"slides": c.get("slides"), "blank": c["blank"], "track_fps": c["track"]["fps"], "clocks": job.offsets,
            "program": [job.program.get("in"), job.program.get("out"), job.program_clock], "mode": c["layout"].get("mode")}


@stage("classroom_slides", inputs=lambda job: [job.path(config(job)["slides"])] if config(job).get("slides") else [],
       code=(track,), config=_slides_cfg)
def stage_slides(job, work: Path) -> dict:
    """The slide feed per track sample: [t, mean, std, blank] (96x54 grey). blank = the frame is flat (std < blank.std_max:
    black, an "Intentionally Blank" slide, "No source detected"). Only for layout.mode "mixed"."""
    c = config(job)
    if c["layout"].get("mode") != "mixed" or not c.get("slides"):
        write_json(workdir(job) / "slides.json", [])
        return {"rows": 0}
    rows = track.slide_stats(job, c)
    write_json(workdir(job) / "slides.json", rows)
    blank = sum(r[3] for r in rows) / max(1, len(rows))
    return {"rows": len(rows), "blank_share": round(blank, 3)}


def build_plan(job) -> tuple[list[dict], dict]:
    c = config(job)
    tk, pe, po = _load(job, "track.json"), _load(job, "people.json"), _load(job, "pose.json")
    sl = _load(job, "slides.json") if (workdir(job) / "slides.json").exists() else []
    qs = questions(job, c)
    frame = tuple(c.get("frame") or (1920, 1080))
    smp = framing.classify(c, tk["track"], pe["wide"], po, tk["valid"], qs, sl)
    runs = framing.plan(c, smp, job.program["in"], job.program["out"], job.f, frame, qs)
    return runs, c


def _plan_inputs(job):
    c = config(job)
    q = c["questions"].get("file")
    p = [workdir(job) / n for n in ("track.json", "people.json", "pose.json", "slides.json")]
    return p + ([Path(q).expanduser() if Path(q).expanduser().is_absolute() else Path(job.root) / q] if q else [])


@stage("classroom_plan", inputs=_plan_inputs, code=(framing,),
       config=lambda job: (lambda c: {k: c.get(k) for k in ("cameras", "questions", "qa", "hold_s", "head", "group", "person",
                                                             "hands", "focus", "track", "frame", "remote", "zoom", "layout", "blank", "slides")} | {"fps": str(job.fps), "program": job.program})(config(job)))
def stage_plan(job, work: Path) -> dict:
    runs, c = build_plan(job)
    js = [{**{k: v for k, v in r.items() if k not in ("x", "y")}, "source": c["cameras"][r["role"]]["source"],
           "x": [round(float(v), 1) for v in r["x"]], "y": [round(float(v), 1) for v in r["y"]]} for r in runs]
    write_json(workdir(job) / "column_plan.json", {"fps": job.f, "in": job.program["in"], "out": job.program["out"], "runs": js})
    s = framing.summary(js)
    expected = round(job.program["out"] * job.f) - round(job.program["in"] * job.f)
    s["frames_expected"] = expected; s["ok"] = s["frames"] == expected
    s["shots"] = [[r["in"], r["out"], r["shot"], r["source"], f"{r['w']}x{r['h']}"] for r in js]
    return s


def column_file(job) -> Path:
    """<edit_root>/<ARC>_column_<plan md5, 8>.mov: one file per framing plan, never replaced in place. An NLE that has
    the old file open keeps reading its cached index after a replace (JOB-0000: a Resolve verify mismatched right after
    an in-place re-render), and a timeline built from an earlier plan must keep its own picture. Old versions stay on
    disk until someone removes them (24 GB each on JOB-0000)."""
    import hashlib
    plan = workdir(job) / "column_plan.json"
    h = hashlib.md5(plan.read_bytes()).hexdigest()[:8] if plan.exists() else "noplan"
    return edit_root(job) / f"{job.arc}_column_{h}.mov"


def _column_inputs(job):
    c = config(job)
    roles = [r for r in ("tight", "wide", "audience", "zoom") if r in c["cameras"]]
    luts = [lut_path(job, c["cameras"][r]) for r in roles]
    zoom = [] if "zoom" in c["cameras"] else [job.path(r.get("source", c.get("zoom"))) for r in c.get("remote") or []]
    slides = [job.path(c["slides"])] if c.get("slides") else []
    slides += sorted({job.path(r["slides"]) for r in c.get("remote") or [] if r.get("slides")}, key=str)
    return [workdir(job) / "column_plan.json", *[job.path(c["cameras"][r]["source"]) for r in roles], *sorted(set(zoom)), *slides,
            *[p for p in luts if p]]


@stage("classroom_column", inputs=_column_inputs, code=(column,),
       config=lambda job: (lambda c: {"render": c["render"], "layout": c["layout"], "clocks": job.offsets, "zoom": c.get("zoom"),
                                      "luts": [c["cameras"][r]["lut"] for r in ("tight", "wide", "audience", "zoom") if r in c["cameras"]],
                                      "edit_root": job.raw.get("edit_root")})(config(job)))
def stage_column(job, work: Path) -> dict:
    c = config(job)
    plan = _load(job, "column_plan.json")
    luts = {r: lut_path(job, c["cameras"][r]) for r in ("tight", "wide", "audience", "zoom") if r in c["cameras"]}
    missing = [str(p) for p in luts.values() if p and not p.exists()]
    if missing:
        raise FileNotFoundError(f"camera LUTs missing: {missing}")
    res = column.render(job, c, plan["runs"], plan["fps"], column_file(job), luts)
    if not res["ok"]:
        raise RuntimeError(f"column render failed its frame check: {res}")
    return res
