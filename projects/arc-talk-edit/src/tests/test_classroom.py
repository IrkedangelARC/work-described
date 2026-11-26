"""classroom + audio_repair + picture_sync pure logic on synthetic data (no drives, no Resolve, no plug-ins).
Run: python3 -m pytest tests/test_classroom.py   (or python3 tests/test_classroom.py)"""
from pathlib import Path
import sys, tempfile, time, shutil
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from arc_talk_edit import audio_repair as A, grade as G, job as J, picture_sync as PS, stages
from arc_talk_edit import classroom as C
from arc_talk_edit.classroom import background, column, framing as F, sbs, track as T

FPS = 30.0
CFG = C._merge(C.DEFAULTS, {
    "cameras": {"tight": C._merge(C.CAMERA_DEFAULTS, {"source": "T", "crop": [816, 918], "head": 0.12, "min_h": 0.07, "margin": 0.10,
                                                    "floor": [0.55, 1.01]}),
                "wide": C._merge(C.CAMERA_DEFAULTS, {"source": "W", "crop": [533, 600], "head": 0.07, "min_h": 0.05,
                                                   "floor": [0.58, 0.95], "x_max": 0.88}),
                "audience": C._merge(C.CAMERA_DEFAULTS, {"source": "A", "crop": [480, 540], "at": [1200, 270]})},
    "qa": [100.0, 200.0]})


# ---- the operator ---------------------------------------------------------------------------------------------------
def test_follow_stays_centred_on_a_walk():
    t = np.arange(0, 20, 1 / FPS)
    walk = 600 + 300 * np.clip((t - 5) / 6, 0, 1)                      # 50 px/s for 6 s
    cam = F.follow(walk, 816, FPS)
    mid = (t > 7) & (t < 10)
    assert np.abs(cam - walk)[mid].max() < 0.05 * 816, np.abs(cam - walk)[mid].max()   # centred during the move (lead ~ drag)
    assert abs(cam[-1] - 900) < 1 and abs(cam[0] - 600) < 1            # settles on him


def test_follow_no_overshoot_and_accel_cap():
    step = np.r_[np.full(150, 500.0), np.full(450, 1100.0)]            # he jumps 600 px (a cut in the track)
    cam = F.follow(step, 816, FPS, amax=0.9)
    assert cam.max() <= 1100.5                                         # critically damped: never passes him
    acc = np.abs(np.diff(cam, 2)) * FPS * FPS
    assert acc.max() <= 0.9 * 816 * 1.001, acc.max()                   # fluid-head cap (crop-widths / s^2)
    assert np.all(np.diff(cam) >= -1e-6)                               # and never moves away from him


def test_follow_ignores_sway():
    t = np.arange(0, 10, 1 / FPS)
    sway = 800 + 12 * np.sin(2 * np.pi * 2.0 * t)                      # 2 Hz gesture / weight shift, +-12 px
    cam = F.follow(sway, 816, FPS)
    assert np.ptp(cam[60:]) < 3.0, np.ptp(cam[60:])


# ---- shots and holds ------------------------------------------------------------------------------------------------
def _blob(cx, h=0.14, edge=False):
    return [cx, 0.45, 0.06, h, edge]


def _track(n, tight, wide):
    ts = [round(i * 0.5, 2) for i in range(n)]
    return {"tight": [[t, *(tight(t) or [None] * 5)] for t in ts], "wide": [[t, *(wide(t) or [None] * 5)] for t in ts]}


def test_classify_priorities():
    tr = _track(120, lambda t: _blob(0.5) if t < 30 else (_blob(0.95) if t < 40 else None), lambda t: _blob(0.6))
    two = [[0.2, 0.3, 0.3, 0.8, 0.99], [0.5, 0.3, 0.6, 0.8, 0.99]]     # two people on the floor, close: they fit
    far = [[0.1, 0.3, 0.2, 0.8, 0.99], [0.75, 0.3, 0.85, 0.8, 0.99]]   # host far right, presenter far left: they do not
    screen = [[0.2, 0.1, 0.3, 0.47, 0.99]]                             # a face on the projection: feet above the floor band
    pw = [[t, two if 20 <= t < 26 else far if 10 <= t < 16 else screen] for t in np.arange(0, 60, 2.0)]
    s = F.classify(CFG, tr, pw, {}, [[0.0, 60.0]], [{"in": 50.0, "out": 52.0}])
    at = {x["t"]: x["s"] for x in s}
    assert at[5.0] == "L"                                              # in the tight camera
    assert at[22.0] == "G"                                             # two people who fit one frame
    assert at[12.0] == "L"                                             # two who do not fit: stay on the subject (10/3)
    assert at[35.0] == "R"                                             # outside the tight margin -> wide
    assert at[45.0] == "R"                                             # tight lost him
    assert at[50.0] == "A" and at[49.5] == "A" and at[53.0] == "R"     # question window with pre / post pad
    assert at[8.0] == "L"                                              # the projected face is not a person on stage


def _person(cx, w=0.1, wrists=None):
    p = [cx - w / 2, 0.3, cx + w / 2, 0.85, 0.99]
    return p + (wrists or [0, 0, -1, 0, 0, -1])


def test_focus_follows_one_person_by_continuity():
    """No colour: the host speaks at the right, the presenter waits far left, the host leaves, then the presenter."""
    tr = _track(80, lambda t: None, lambda t: None)
    def wide(t):
        host = [_person(0.80)] if t < 20 else []                       # leaves at 20 s
        pres = [_person(0.25 if t < 24 else 0.5)]                      # walks to the centre at 24 s
        return host + pres
    def tight(t):
        return [_person(0.5, 0.2)] if t >= 24 else []                  # only the centre is in the tight camera
    pose = {"wide": [[t, wide(t)] for t in np.arange(0, 40, 0.5)], "tight": [[t, tight(t)] for t in np.arange(0, 40, 0.5)]}
    cfg = C._merge(CFG, {})
    cfg["cameras"]["wide"] = dict(cfg["cameras"]["wide"], x_max=1.0)
    s = F.classify(cfg, tr, [], pose, [], [])
    at = {x["t"]: x for x in s}
    assert at[10.0]["s"] == "P" and abs(F.centre(at[10.0]["fw"]) - 0.80) < 1e-6   # on the speaker, not a wide two-shot
    assert at[21.0]["s"] == "P" and abs(F.centre(at[21.0]["fw"]) - 0.80) < 1e-6   # he just left: hold his framing
    assert abs(F.centre(at[23.5]["fw"]) - 0.25) < 1e-6                 # re-acquired the remaining person
    assert at[30.0]["s"] == "PL" and at[30.0]["ft"] is not None        # whole in the tight camera -> tight


def test_single_camera_never_alternates_and_lectern_speaker_followed():
    """Room B: one presenter camera (tight = wide), a speaker behind the lectern (feet hidden: box ends at y 0.62)."""
    tr = _track(60, lambda t: None, lambda t: None)
    behind = [0.20, 0.25, 0.32, 0.62, 0.99, 0, 0, -1, 0, 0, -1]        # head at 0.25, box stops at the lectern top
    pose = {"wide": [[t, [behind]] for t in np.arange(0, 30, 0.5)], "tight": [[t, [behind]] for t in np.arange(0, 30, 0.5)]}
    cfg = C._merge(CFG, {}); cfg["single_camera"] = True
    cfg["cameras"]["wide"] = dict(cfg["cameras"]["wide"], floor=[0.80, 1.01])
    s = F.classify(cfg, tr, [], pose, [], [])
    assert {x["s"] for x in s} == {"P"}                                 # followed (not the stage fallback), one shot type


def test_hands_stay_in_frame():
    assert F.aim_with_reach(800, None, None, 816, 40) == 800           # reach unknown: centre the body
    assert F.aim_with_reach(800, 600, 1000, 816, 40) == 800            # both hands inside: stay centred on the body
    a = F.aim_with_reach(800, 700, 1300, 816, 40)                      # right hand at 1300: shift right just enough
    assert a + 408 >= 1300 + 40 - 1e-6 and a - 408 <= 700 - 40 + 1e-6 and a > 800
    assert F.aim_with_reach(800, 300, 1500, 816, 40) == 900            # reach wider than the frame: centre the reach
    # a run where he keeps pointing right: the frame shifts so the wrist stays inside on every frame
    W, H = 1920, 1080
    n = 60; tf = np.arange(n * 15) / FPS
    rule = lambda top, h: top - 0.12 * H - 0.08 * h
    pts = [(i * 0.5, 900.0, 480.0, 820.0, 1380.0, 430.0) for i in range(n)]    # body at 900, right wrist out at 1380
    r = F.subject_shot(CFG, "L", CFG["cameras"]["tight"], pts, rule, tf, W, H, FPS)
    x = np.asarray(r["x"])[60:]
    assert r["w"] == 816 and np.all(x <= 820 - 1) and np.all(x + r["w"] >= 1380 + 1)
    # arms spread wider than the camera's crop: the crop is sized up (same aspect) to hold the reach
    pts = [(i * 0.5, 900.0, 480.0, 470.0, 1330.0, 430.0) for i in range(n)]    # 860 px of reach
    r = F.subject_shot(CFG, "L", CFG["cameras"]["tight"], pts, rule, tf, W, H, FPS)
    x = np.asarray(r["x"])[60:]
    assert r["w"] > 860 and abs(r["w"] / r["h"] - 816 / 918) < 0.01 and r["h"] <= H
    assert np.all(x <= 470) and np.all(x + r["w"] >= 1330)


def test_classify_without_pose_falls_back_to_stage():
    tr = _track(40, lambda t: None, lambda t: None)
    s = F.classify(CFG, tr, [], {}, [], [])                            # no colour, nobody detected
    assert all(x["s"] == "G" for x in s)
    runs = F.plan(CFG, s, 0.0, 19.0, FPS, (1920, 1080), [])
    assert sum(len(r["x"]) for r in runs) == 570 and runs[0]["w"] == 960


def test_hold_absorbs_short_runs_keeps_questions():
    def run(s, n, q=False):
        return {"s": s, "n": [{"t": 0, "s": s, "q": q}] * n}
    out = F.hold([run("L", 40), run("R", 6), run("L", 40), run("A", 5, q=True), run("L", 40)], 8.0, 0.5)
    assert [(r["s"], len(r["n"])) for r in out] == [("L", 86), ("A", 5), ("L", 40)]
    out = F.hold([run("R", 4), run("L", 40)], 8.0, 0.5)               # a short first run joins the next
    assert [(r["s"], len(r["n"])) for r in out] == [("L", 44)]


def test_plan_is_contiguous_and_frame_exact():
    tr = _track(240, lambda t: _blob(0.5) if (t % 40) < 25 else None, lambda t: _blob(0.5 + 0.2 * np.sin(t / 7)))
    s = F.classify(CFG, tr, [], {}, [[0.0, 1e9]], [{"in": 60.0, "out": 64.0}])
    runs = F.plan(CFG, s, 3.5, 117.25, FPS, (1920, 1080), [{"in": 60.0, "out": 64.0}])
    assert runs[0]["in"] == 3.5 and all(abs(a["out"] - b["in"]) < 1e-6 for a, b in zip(runs, runs[1:]))
    assert sum(len(r["x"]) for r in runs) == round(117.25 * FPS) - round(3.5 * FPS)
    for r in runs:
        assert len(r["x"]) == len(r["y"]) and min(r["x"]) >= 0 and max(r["x"]) + r["w"] <= 1920 and r["y"][0] + r["h"] <= 1080
        assert r["shot"] == "A" or r["out"] - r["in"] >= 8.0 - 1e-6 or r is runs[-1]
    a = next(r for r in runs if r["shot"] == "A")
    assert (a["w"], a["h"], a["x"][0], a["y"][0]) == (480, 540, 1200.0, 270.0)
    moved = F.plan(CFG, s, 3.5, 117.25, FPS, (1920, 1080), [{"in": 60.0, "out": 64.0, "at": [1000, 270]}])
    assert next(r for r in moved if r["shot"] == "A")["x"][0] == 1000.0     # a question can carry its own framing


# ---- track ----------------------------------------------------------------------------------------------------------
def test_colour_blob_and_valid_windows():
    try:
        import cv2  # noqa: F401
    except ImportError:
        return
    img = np.full((216, 384, 3), 200, np.uint8)
    img[90:130, 180:205] = (20, 20, 200)                               # BGR red shirt inside the band
    img[10:40, 300:340] = (20, 20, 200)                                # red above the band (a slide): ignored
    b = T.colour_blob(img, {"hue": [161, 7], "sat_min": 110, "val_min": 50}, [0.30, 0.80])
    assert b is not None and abs(b[0] - 192.5 / 384) < 0.01 and abs(b[1] - 90 / 216) < 0.01 and not b[4]
    assert T.colour_blob(img, {"hue": [100, 130]}, [0.30, 0.80]) is None
    tr = _track(400, lambda t: _blob(0.5) if t >= 60 else None, lambda t: None)
    v = T.colour_valid(tr, CFG)
    assert len(v) == 1 and 50 <= v[0][0] <= 70 and v[0][1] >= 195
    j = type("Job", (), {"program": {"in": 0.0, "out": 200.0}})()
    assert T.invalid_windows(j, [[60.0, 200.0]], 13.0) == [[0.0, 73.0]]
    assert T.invalid_windows(j, [[0.0, 200.0]], 13.0) == []


def test_background_blob():
    try:
        import cv2  # noqa: F401
    except ImportError:
        return
    rng = np.random.default_rng(0)
    room = rng.integers(150, 160, (216, 384, 3)).astype(np.uint8)
    frames = np.stack([room.copy() for _ in range(9)])
    for i, f in enumerate(frames):                                     # a person in a different place each frame
        f[70:160, 30 + 35 * i:50 + 35 * i] = 40
    plate = background.plate(frames)
    assert np.abs(plate.astype(int) - room).max() <= 1                 # the median is the empty room
    b = background.blobs(frames[4], plate, [0.25, 0.85])
    assert len(b) == 1 and abs((b[0][0] + b[0][2]) / 2 - (30 + 35 * 4 + 10) / 384) < 0.02


# ---- render + Resolve math ------------------------------------------------------------------------------------------
def test_seek_and_spec():
    assert abs(column.seek(868.2382, 30) - (26047 - 0.5) / 30) < 1e-9  # nearest source frame, half a frame early
    assert column.seek(0.0, 30) == 0.0


def test_disk_guard():
    d = Path(tempfile.mkdtemp())
    try:
        try:
            column.disk_guard(d, 1e6, 0)                               # the temp dir is on the OS disk (on the office workstation)
            on_os = False
        except RuntimeError:
            on_os = True
        import os
        assert on_os == (os.stat(d).st_dev == os.stat("/").st_dev)
        try:
            column.disk_guard(d, 1e18, 0, allow_os_disk=True); raise AssertionError("no room, should refuse")
        except RuntimeError:
            pass
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_sbs_transform_matches_resolve_measurements():
    s = sbs.transform((1920, 1080), [0, 180, 1280, 720], (1920, 1080))       # verified by a Deliver render 10/3
    assert abs(s["ZoomX"] - 2 / 3) < 1e-9 and s["Pan"] == -320.0 and s["Tilt"] == 0.0
    c = sbs.transform((640, 720), [1280, 180, 640, 720], (1920, 1080))       # Pan 640 left it 320 px short; 1280 is flush
    assert abs(c["ZoomX"] - 2 / 3) < 1e-9 and c["Pan"] == 1280.0 and c["Tilt"] == 0.0
    try:
        sbs.transform((640, 720), [0, 0, 1280, 720], (1920, 1080)); raise AssertionError("aspect mismatch must raise")
    except ValueError:
        pass


def test_config_validation():
    y = Path(tempfile.mkdtemp()) / "job.yaml"
    y.write_text("arc: UNITCLASS\nclocks: {a: 0}\nsources: {S: {path: s.mp4, clock: a}, T: {path: t.mp4, clock: a}}\n"
                 "program: {in: 0, out: 10}\nclassroom:\n  slides: S\n  subject: {colour: {hue: [161, 7]}}\n"
                 "  cameras:\n    tight: {source: T, crop: [816, 918]}\n    wide: {source: T, crop: [533, 600]}\n"
                 "    audience: {source: T, crop: [480, 500]}\n")
    try:
        C.config(J.load(y)); raise AssertionError("wrong crop aspect must raise")
    except ValueError as e:
        assert "aspect" in str(e)
    y.write_text(y.read_text().replace("[480, 500]", "[480, 540]"))
    c = C.config(J.load(y))
    assert c["hold_s"] == 8.0 and c["cameras"]["wide"]["x_max"] == 1.0 and c["head"]["omega"] == 4.0


# ---- audio ----------------------------------------------------------------------------------------------------------
def test_splice_level_match_and_power():
    sr = A.SR; t = np.arange(4 * sr) / sr
    y = (0.2 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    other = (0.05 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)   # same programme, 12 dB lower
    out, g = A.splice(y, other, 1.0, 3.0, fade_s=0.25)
    assert abs(g - 4.0) < 0.01
    assert np.allclose(out[:int(0.7 * sr)], y[:int(0.7 * sr)]) and np.allclose(out[int(3.3 * sr):], y[int(3.3 * sr):])
    assert np.allclose(out[int(1.2 * sr):int(2.8 * sr)], other[int(1.2 * sr):int(2.8 * sr)] * g, atol=1e-5)


def test_process_empty_chain_is_identity():
    x = np.random.default_rng(1).normal(0, 0.1, 48000).astype(np.float32)
    assert np.array_equal(A.process(x, []), x)


def test_picture_sync_lag_sign():
    rng = np.random.default_rng(2); a = rng.normal(size=900)
    b = np.r_[a[7:], rng.normal(size=7)]                               # b sees every event 7 frames earlier
    L, r = PS.lag(a, b, 60)
    assert L == 7 and r > 0.9


def test_partial_wb():
    wb = (0.5, 0.55, 0.62)
    assert np.allclose(G.partial_wb(wb, 1.0), wb) and np.allclose(G.partial_wb(wb, 0.0), (0.55, 0.55, 0.55))
    r, g, b = G.partial_wb(wb, 0.4)
    assert wb[0] < r < g < b < wb[2]


# ---- stage runner: per-stage config hashing --------------------------------------------------------------------------
def test_stage_config_hash():
    calls = []
    tmp = Path(tempfile.mkdtemp()); y = tmp / "job.yaml"

    @stages.stage("unit_cfg", config=lambda job: job.raw.get("mine"))
    def _s(job, work):
        calls.append(1); return {}
    y.write_text("arc: UNITCFG\nclocks: {ref: 0}\nmine: {a: 1}\nother: 1\n")
    w = stages.workdir(J.load(y)); shutil.rmtree(w, ignore_errors=True)
    try:
        assert stages.run(J.load(y), "unit_cfg") == {"unit_cfg": "ran"}
        y.write_text("arc: UNITCFG\nclocks: {ref: 0}\nmine: {a: 1}\nother: 2\n")       # unrelated key: skipped
        assert stages.run(J.load(y), "unit_cfg") == {"unit_cfg": "skipped"}
        y.write_text("arc: UNITCFG\nclocks: {ref: 0}\nmine: {a: 2}\nother: 2\n")       # its own key: re-run
        assert stages.run(J.load(y), "unit_cfg") == {"unit_cfg": "ran"}
        assert len(calls) == 2
    finally:
        shutil.rmtree(w, ignore_errors=True); stages.REGISTRY.pop("unit_cfg", None)


if __name__ == "__main__":
    for k, v in list(globals().items()):
        if k.startswith("test_"):
            v(); print("ok", k)


def test_splice_match_window_levels_a_silent_program():
    """JOB-0000: the program channel is silent inside the splice; the gain comes from a window where both carry the voice."""
    n = A.SR * 6; rng = np.random.default_rng(3)
    voice = rng.standard_normal(n).astype(np.float32)
    y = 0.5 * voice; y[A.SR * 1:A.SR * 3] = 0.0                      # program silent 1-3 s
    other = 0.1 * voice                                              # lav at a different level
    out, g = A.splice(y, other, 1.0, 3.0, fade_s=0.05, match=(4.0, 6.0))
    assert abs(g - 5.0) < 0.05                                       # 0.5 / 0.1
    assert abs(A.rms(out[int(A.SR * 1.5):int(A.SR * 2.5)]) - A.rms(y[A.SR * 4:])) < 0.02


def test_align_shifts_other_clock():
    o = np.arange(100, dtype=np.float32)
    a = A.align(o, 10 / A.SR, 50)                                    # this clock's zero = sample 10 of o
    assert a[0] == 10 and a[49] == 59
    b = A.align(o, -5 / A.SR, 20)                                    # o starts 5 samples after this clock's zero
    assert b[4] == 0 and b[5] == 0 and b[6] == 1


def test_remote_window_slides_override():
    """JOB-0000: inside a remote window that names its own slides, the sbs composite takes that source; elsewhere the
    lectern slides."""
    cfg = C._merge(CFG, {"slides": "S", "layout": {"mode": "mixed", "column": [0, 0, 1920, 1080],
                                                   "sbs": {"slides": [0, 180, 1280, 720], "column": [1280, 180, 640, 720]}}})
    cfg["cameras"]["zoom"] = C._merge(C.CAMERA_DEFAULTS, {"source": "Z", "crop": [1920, 1080], "at": [0, 0],
                                                         "crop_sbs": [960, 1080], "at_sbs": [480, 0]})
    rw = {"in": 10.0, "out": 20.0, "slides": "ZS"}
    zrun = {"s": "Z", "lay": "sbs", "n": [{"t": 10.0 + k * 0.5, "remote": rw} for k in range(20)]}
    p = F.plan_run(cfg, zrun, 10.0, 20.0, 30.0, (1920, 1080), [])
    assert p["composite"]["panel_source"] == "ZS"
    zrun2 = {"s": "Z", "lay": "sbs", "n": [{"t": 10.0 + k * 0.5, "remote": {"in": 10.0, "out": 20.0}} for k in range(20)]}
    assert F.plan_run(cfg, zrun2, 10.0, 20.0, 30.0, (1920, 1080), [])["composite"]["panel_source"] == "S"


def test_layout_full_windows_force_full_frame():
    cfg = C._merge(CFG, {"layout": {"mode": "mixed", "full": [[20.0, 30.0]]}})
    slides = [[t * 0.5, 100.0, 30.0, False] for t in range(100)]          # a slide on screen the whole time
    times = [t * 0.5 for t in range(100)]
    lay = F.layout_flags(cfg, slides, times)
    assert lay[10.0] == "sbs" and lay[25.0] == "full" and lay[30.0] == "sbs"
