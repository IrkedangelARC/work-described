"""Classroom capture edit (first job: JOB-0000, a classroom talk, 2026-10-03; docs/CLASSROOM.md).

A classroom recorder (Epiphan Pearl) gives fixed cameras, an audience multi-up and a clean laptop feed, with no operator.
This package makes the operated-looking side-by-side from that: slides beside a "presenter column" that picks the best
camera per moment, frames the presenter like a fluid-head operator, widens for people on stage and cuts to the audience
for questions.

  track.py     where the presenter is (colour track) and who is on stage (person detector), cached per job
  framing.py   pure: shot choice per sample, minimum holds, fluid-head follow, per-frame crop plan
  column.py    render the plan (ffmpeg crop + LUT) to one ProRes column file, verified frame-exact, resumable
  sbs.py       Resolve: slides | column timeline with program + raw audio; settings and placement verified
  pipeline.py  the stages (`arc-talk-edit run classroom <job>`)

Everything is configured under `classroom:` in the job.yaml; DEFAULTS below are the values the operator approved on JOB-0000.
"""
from __future__ import annotations
import copy
from pathlib import Path

DEFAULTS = {
    "layout": {"slides": [0, 180, 1280, 720], "column": [1280, 180, 640, 720]},   # timeline px x, y, w, h (layout A, 10/3)
    "track": {"fps": 2.0, "size": [384, 216], "min_area": 25},
    "people": {"fps": 0.5, "size": [960, 540], "score": 0.7, "workers": 5, "pad_s": 13.0},
    "pose": {"fps": 1.0, "size": [960, 540], "score": 0.8, "workers": 5},      # fps where the colour track is valid
    "hands": {"margin": 0.05, "fit": 0.95, "max_scale": 1.3},                 # keep wrists inside the crop (10/3 notes)
    "focus": {"max_step": 0.12, "lost_s": 2.0, "match": 0.15, "hold_s": 30.0, "cut_s": 4.0},  # follow one person by continuity (no
                                                                               # colour); hold the last framing 30 s when
                                                                               # he leaves the frame
    "questions": {"pre_s": 0.7, "post_s": 0.8},
    "blank": {"std_max": 6.0, "min_s": 8.0},       # mixed layout: a slide frame this flat is "blank" (measured per job)
    "hold_s": 8.0,                                       # LESSONS L39: no shot under 8 s (question cutaways excepted)
    "head": {"sigma_s": 0.5, "lead_s": 0.25, "omega": 4.0, "amax": 0.9},   # fluid head (10/3, 2 review notes)
    "group": {"pad_w": 1.25, "pad_h": 1.18, "min_h": 600, "headroom": 0.08, "empty": [600, 0, 960, 1080],
              "max_span": 0.6},                           # a group shot only when everyone fits: outer edges this far
                                                          # apart at most (frame-width fraction). JOB-0000: a 5-person
                                                          # demo stands 0.43 wide (max 0.57) and fits the widest
                                                          # crop; host far right + presenter far left is 0.66 and does not
    "person": {"headroom": 0.06, "min_h": 0.4},          # whole person in the tight camera (no colour track)
    "render": {"prores_profile": 2, "workers": 6, "keep_pieces": False, "margin_gb": 20},
}
CAMERA_DEFAULTS = {"band": [0.0, 1.0], "head": 0.10, "headroom": 0.08, "min_h": 0.05, "margin": 0.05,
                   "floor": [0.0, 1.0], "x_max": 1.0, "lut": None}


def _merge(base: dict, over: dict) -> dict:
    out = copy.deepcopy(base)
    for k, v in (over or {}).items():
        out[k] = _merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def config(job) -> dict:
    """The job's `classroom:` section over DEFAULTS, validated. Raises ValueError naming what is missing.

    Two layouts: "sbs" (Room A: slides | presenter column; needs `slides`) and "full" (Room B: the presenter shot fills the
    frame, layout.column = the whole frame, no slides). Either may have `remote` windows: a talk given over Zoom, shown as
    the Zoom feed beside a room shot (layout.remote). Without `subject.colour` everything is followed by the pose model;
    without `cameras.tight` the wide camera is the only presenter camera (Room B: both rear cameras frame the same shot)."""
    raw = job.raw.get("classroom")
    if not raw:
        raise ValueError(f"{job.arc}: no `classroom:` section in the job.yaml (see docs/CLASSROOM.md)")
    c = _merge(DEFAULTS, raw)
    cams = c.get("cameras") or {}
    if "tight" not in cams and "wide" in cams:
        cams["tight"] = copy.deepcopy(cams["wide"])
    if "zoom" in cams:                                      # a Zoom feed used as a camera (remote speakers)
        cams["zoom"] = _merge(CAMERA_DEFAULTS, cams["zoom"])
        if cams["zoom"].get("source") not in job.sources:
            raise ValueError(f"classroom.cameras.zoom.source {cams['zoom'].get('source')!r} is not a job source")
    for role in ("tight", "wide", "audience"):
        if role not in cams:
            raise ValueError(f"classroom.cameras.{role} missing")
        cams[role] = _merge(CAMERA_DEFAULTS, cams[role])
        if cams[role].get("source") not in job.sources:
            raise ValueError(f"classroom.cameras.{role}.source {cams[role].get('source')!r} is not a job source")
        if "crop" not in cams[role]:
            raise ValueError(f"classroom.cameras.{role}.crop [w, h] missing")
    c["single_camera"] = cams["tight"]["source"] == cams["wide"]["source"]
    if c.get("slides") is not None and c["slides"] not in job.sources:
        raise ValueError(f"classroom.slides {c.get('slides')!r} is not a job source")
    if c["layout"].get("mode") == "mixed":
        c["layout"]["slides"] = None                         # the slides are inside the program picture, not a track
    elif c["layout"].get("slides") and not c.get("slides"):
        c["layout"]["slides"] = None if raw.get("layout", {}).get("slides") is None else c["layout"]["slides"]
        if c["layout"]["slides"]:
            raise ValueError("layout.slides is set but classroom.slides (the source) is not")
    c["subject"] = c.get("subject") or {}
    if job.program.get("in") is None or job.program.get("out") is None:
        raise ValueError("program.in / program.out missing: the classroom chain plans the program window")
    cw, ch = c["layout"]["column"][2:]
    for role in ("tight", "wide", "audience"):
        w, h = cams[role]["crop"]
        if abs(w / h - cw / ch) > 0.01:
            raise ValueError(f"classroom.cameras.{role}.crop {w}x{h} is not the column aspect {cw}:{ch}")
    if c["layout"].get("mode") == "mixed":                    # slides | presenter while there are slides, full otherwise
        sb = c["layout"].get("sbs") or {}
        if not c.get("slides") or "slides" not in sb or "column" not in sb:
            raise ValueError("layout.mode mixed needs classroom.slides and layout.sbs {slides: [x,y,w,h], column: [x,y,w,h]}")
        sw, sh = sb["column"][2:]
        for role in ("tight", "wide", "audience") + (("zoom",) if "zoom" in cams else ()):
            if "crop_sbs" not in cams[role]:
                raise ValueError(f"classroom.cameras.{role}.crop_sbs [w, h] missing (mixed layout)")
            w, h = cams[role]["crop_sbs"]
            if abs(w / h - sw / sh) > 0.01:
                raise ValueError(f"classroom.cameras.{role}.crop_sbs {w}x{h} is not the side-by-side column aspect {sw}:{sh}")
    for r in c.get("remote") or []:
        if "zoom" in cams:
            continue                                         # the Zoom feed is a camera: no composite layout needed
        if r.get("source", c.get("zoom")) not in job.sources:
            raise ValueError(f"classroom.remote window {r} has no Zoom source (remote[].source or classroom.zoom)")
        lr = c["layout"].get("remote")
        if not lr or "zoom" not in lr or "room" not in lr or "room_crop" not in lr:
            raise ValueError("layout.remote {zoom: [x,y,w,h], room: [x,y,w,h], room_crop: [w,h], room_at: [x,y]} missing")
    return c


def workdir(job) -> Path:
    from .. import stages
    w = stages.workdir(job) / "classroom"
    w.mkdir(parents=True, exist_ok=True)
    return w


def edit_root(job) -> Path:
    """Where big renders go (job.yaml `edit_root`): a media drive, never the OS disk (10/2)."""
    r = job.raw.get("edit_root")
    if not r:
        raise ValueError(f"{job.arc}: `edit_root:` missing in the job.yaml (render target on a media drive)")
    return Path(r).expanduser()


def lut_path(job, cam: dict) -> Path | None:
    if not cam.get("lut"):
        return None
    p = Path(cam["lut"]).expanduser()
    return p if p.is_absolute() else Path(job.root) / p


def questions(job, c: dict) -> list[dict]:
    """Question windows on the program clock: classroom.questions.file (JSON list of {in, out}) or .list inline."""
    import json
    q = c["questions"]
    if q.get("file"):
        p = Path(q["file"]).expanduser()
        return json.loads((p if p.is_absolute() else Path(job.root) / p).read_text())
    return list(q.get("list") or [])


def write_json(path: Path, obj) -> bool:
    """Write obj as JSON only when the content changed (keeps the mtime, so downstream stages stay cached)."""
    import json
    txt = json.dumps(obj)
    if path.exists() and path.read_text() == txt:
        return False
    path.write_text(txt)
    return True
