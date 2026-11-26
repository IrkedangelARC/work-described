"""V1 builder (P2.4). Part 1, pure: program shots -> timeline pieces (port of JOB-0000 build_v1.py piece logic, unchanged).

Pieces = {trk: 1 screen | 2 camera/PiP | "A1" program audio, key: source key, rec: record frame, s/e: source frames}.
Frames: reference frame = round(t_ref * fps); a source on another clock = reference frame - its integer frame offset
(LESSONS L14, never round its time separately). Screen runs extend `ext` frames under neighbouring camera pieces (inside
the keep) so dissolves never show black. Part 2 (placement with Take Selector) needs the operator's go per job.
"""
from __future__ import annotations


def pieces(job, program: dict, keymap: dict, ext: int = 16) -> list[dict]:
    """keymap: program state/cam key -> job source key (e.g. AUD -> AJA4, SCREEN -> AJA3, PIP -> PIP)."""
    f = job.f; pc = job.program_clock; ref = job.ref
    fr = lambda t: round(job.convert(t, pc, ref) * f)
    rm = sorted((x["in"], x["out"], x["id"]) for x in program["remove"])
    keeps, t = [], program["program_in"]
    for a, b, _ in rm:
        keeps.append((t, a)); t = b
    keeps.append((t, program["program_out"]))
    K = [(fr(a), fr(b)) for a, b in keeps]
    R0, c = [], 0
    for a, b in K:
        R0.append(c); c += b - a
    rec = lambda F: next(r + F - a for (a, b), r in zip(K, R0) if a <= F <= b)
    out = []

    def put(trk, prog_key, A, B, sh, ki):
        src = keymap.get(prog_key, prog_key)
        off = round(job.convert(0.0, job.sources[src].clock, ref) * f)    # source frame 0 on the reference
        out.append({"trk": trk, "key": prog_key, "source": src, "rec": rec(A), "s": A - off, "e": B - off,
                    "state": sh["state"], "zoom_rect": sh.get("zoom_rect"), "pip": sh.get("pip"), "keep": ki})
    shots = program["shots"]
    for i, sh in enumerate(shots):
        A0, B0 = fr(sh["in"]), fr(sh["out"])
        for ki, (ka, kb) in enumerate(K):
            A, B = max(A0, ka), min(B0, kb)
            if B <= A:
                continue
            if sh["state"] == "SCREEN":
                a2 = A - ext if (A == A0 and A - ext >= ka and (i == 0 or shots[i - 1]["state"] != "SCREEN")) else A
                b2 = B + ext if (B == B0 and B + ext <= kb and (i + 1 == len(shots) or shots[i + 1]["state"] != "SCREEN")) else B
                put(1, "SCREEN", a2, b2, sh, ki)
                if sh.get("pip"):
                    put(2, "PIP", A, B, sh, ki)
            else:
                put(2, sh.get("cam") or sh["state"], A, B, sh, ki)
    for ki, (ka, kb) in enumerate(K):
        out.append({"trk": "A1", "key": "PROGRAM", "source": "PROGRAM", "rec": R0[ki], "s": ka, "e": kb,
                    "state": None, "zoom_rect": None, "pip": None, "keep": ki})
    return out


# Join durations in frames (docs/defaults.yaml `joins`, JOB-0000 build_v1.py); job.yaml v1.joins overrides any key.
JOINS = {"tech_cut": 12, "framing_change": 15, "pip_corner": 20, "camera_pip": 15, "camera_camera": 0,
         "fade_over_screen": 15, "audio_xfade": 4}


def joins(pcs: list[dict], J: dict | None = None) -> list[dict]:
    """Pure: transitions for adjacent pieces. Returns ops {i: piece index, op: dissolve|fades|xfade, ...}.
    dissolve = Cross Dissolve at the end of piece i into the abutting next piece on its track (centred);
    fades = V2 piece against screen-only / program ends; xfade = audio crossfade at each tech-cut join."""
    J = {**JOINS, **(J or {})}
    total = max(x["rec"] + x["e"] - x["s"] for x in pcs)
    ln = lambda x: x["e"] - x["s"]

    def d(a, b):
        if a["keep"] != b["keep"]:
            return J["tech_cut"]
        if a["trk"] == 1:
            return J["framing_change"] if a["zoom_rect"] != b["zoom_rect"] else 0
        if a["key"] == "PIP" and b["key"] == "PIP":
            return J["pip_corner"] if a["pip"] != b["pip"] else 0
        if "PIP" in (a["key"], b["key"]):
            return J["camera_pip"]
        return J["camera_camera"]
    ops = []
    for trk in (1, 2):
        row = sorted((i for i, x in enumerate(pcs) if x["trk"] == trk), key=lambda i: pcs[i]["rec"])
        for n, i in enumerate(row):
            x = pcs[i]
            nxt = row[n + 1] if n + 1 < len(row) and pcs[row[n + 1]]["rec"] == x["rec"] + ln(x) else None
            prv = row[n - 1] if n and pcs[row[n - 1]]["rec"] + ln(pcs[row[n - 1]]) == x["rec"] else None
            if nxt is not None and (dd := d(x, pcs[nxt])):
                ops.append({"i": i, "op": "dissolve", "frames": dd})
            if trk == 2:
                fin = J["fade_over_screen"] if (prv is None and x["rec"] > 0) else 0
                fout = J["fade_over_screen"] if (nxt is None and x["rec"] + ln(x) < total) else 0
                if fin or fout:
                    ops.append({"i": i, "op": "fades", "in": fin, "out": fout})
    aud = sorted((i for i, x in enumerate(pcs) if x["trk"] == "A1"), key=lambda i: pcs[i]["rec"])
    ops += [{"i": i, "op": "xfade", "frames": J["audio_xfade"]} for i in aud[:-1]]
    return ops


# ---- Part 2: placement with Take Selector (creates a NEW timeline; needs the operator's go per job) ---------------------------
PIPZ, MARGIN = 1 / 3, 16
LUT_ROOT = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT"


def place(job, pcs: list[dict], name: str = "V1 (ARC Edit)", takes: list[str] | None = None, colour: str = "input_lut",
          program_audio: str | None = None, crop=(16, 9, 1888, 1062), take_windows: dict | None = None) -> dict:
    """Append pieces into a new timeline; every camera piece gets every synced angle in `takes` as Take Selector takes
    (the engine's choice stays take 1, selected). take_windows {source: [from_s, to_s|None]} (reference clock): a source is
    added as a take only to pieces wholly inside its window (e.g. a feed that is graphics before a time). colour: 'input_lut' (follows takes; new jobs) or 'item_lut' (node 1 LUT,
    for projects whose pool clips already carry node LUTs elsewhere: avoids a double grade). Restores the open timeline."""
    import sys
    sys.path.append("/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules")
    import DaVinciResolveScript as drs
    r = drs.scriptapp("Resolve"); p = r.GetProjectManager().GetCurrentProject(); mp = p.GetMediaPool(); root = mp.GetRootFolder()
    names = [p.GetTimelineByIndex(i).GetName() for i in range(1, p.GetTimelineCount() + 1)]
    assert name not in names, f"{name} exists; not overwriting"
    prev = p.GetCurrentTimeline(); p.RefreshLUTList()
    f = job.f; ref = job.ref
    paths = {x["source"]: (str(job.path(x["source"])) if x["source"] != "PROGRAM" else str(program_audio)) for x in pcs}
    for k in takes or []:
        paths[k] = str(job.path(k))
    have = {}
    def walk(fo):
        for c in fo.GetClipList() or []:
            have.setdefault(c.GetClipProperty("File Path"), c)
        for sub in fo.GetSubFolderList() or []:
            walk(sub)
    walk(root)
    todo = sorted({v for v in paths.values() if v not in have})
    if todo:
        fo = next((s for s in root.GetSubFolderList() if s.GetName() == "ARC Edit sources"), None) or mp.AddSubFolder(root, "ARC Edit sources")
        mp.SetCurrentFolder(fo)
        for c in mp.ImportMedia(todo) or []:
            have[c.GetClipProperty("File Path")] = c
    item = lambda src: have[paths[src]]
    lut_of = lambda src: (f"{job.raw.get('lut_dir', '')}/{job.sources[src].lut}" if job.sources.get(src) and job.sources[src].lut else None)
    if colour == "input_lut":
        for src in {x["source"] for x in pcs if x["trk"] == 2} | set(takes or []):
            if lut_of(src):
                item(src).SetClipProperty("Input LUT", lut_of(src).rsplit(".cube", 1)[0])
    mp.SetCurrentFolder(root)
    tl = mp.CreateEmptyTimeline(name); p.SetCurrentTimeline(tl)
    while tl.GetTrackCount("video") < 2:
        tl.AddTrack("video")
    tl.SetTrackName("video", 1, "SCREEN"); tl.SetTrackName("video", 2, "CAMERA / PIP"); tl.SetTrackName("audio", 1, "PROGRAM")
    T0 = tl.GetStartFrame()
    rate = lambda src: float(item(src).GetClipProperty("FPS") or 0) or f
    off_s = lambda src: job.convert(0.0, job.sources[src].clock, ref)          # source t=0 on the reference clock (s)
    mixed = any(abs(rate(x["source"]) - f) > 0.01 for x in pcs if x["trk"] != "A1") or any(abs(rate(k) - f) > 0.01 for k in takes or [])
    got = {}
    if not mixed:                                                 # every source at the timeline rate: one batch (golden path)
        infos = [{"mediaPoolItem": item(x["source"]), "mediaType": 2 if x["trk"] == "A1" else 1,
                  "trackIndex": 1 if x["trk"] == "A1" else x["trk"], "startFrame": x["s"], "endFrame": x["e"], "recordFrame": T0 + x["rec"]}
                 for x in pcs]
        placed = mp.AppendToTimeline(infos) or []
        for kind, n in (("video", 2), ("audio", 1)):
            for i in range(1, n + 1):
                for it in tl.GetItemListInTrack(kind, i) or []:
                    if it.GetType() != "transition":
                        got[(kind, i, it.GetStart() - T0)] = it
        for x in pcs:
            x["A"] = x["s"] + round(off_s(x["source"]) * f) if x["source"] in job.sources else None
    else:
        # Mixed frame rates (JOB-0000 Pearl 30 fps in a 59.94 timeline, probe 10/3): AppendToTimeline takes start/end in the
        # CLIP's frames and rounds the timeline duration (300 src frames -> 599, not 600), so a batch leaves 1-frame gaps.
        # Camera pieces go in one at a time; each starts where the previous one ACTUALLY ended and its source point is
        # recomputed from that record position, so sync holds and nothing gaps.
        placed = mp.AppendToTimeline([{"mediaPoolItem": item(x["source"]), "mediaType": 2, "trackIndex": 1, "startFrame": x["s"],
                                       "endFrame": x["e"], "recordFrame": T0 + x["rec"]} for x in pcs if x["trk"] == "A1"]) or []
        for it in tl.GetItemListInTrack("audio", 1) or []:
            got[("audio", 1, it.GetStart() - T0)] = it
        cur = None
        for x in sorted((x for x in pcs if x["trk"] != "A1"), key=lambda x: x["rec"]):
            src = x["source"]; rec = x["rec"] if cur is None else cur
            A = x["s"] + round(off_s(src) * f) + (rec - x["rec"])             # reference frame at the actual record position
            B = x["e"] + round(off_s(src) * f)                                 # nominal end (reference frame)
            r_ = rate(src)
            if abs(r_ - f) <= 0.01:
                sf_, ef_ = A - round(off_s(src) * f), B - round(off_s(src) * f)
            else:
                sf_, ef_ = round((A / f - off_s(src)) * r_), round((B / f - off_s(src)) * r_)
            res = mp.AppendToTimeline([{"mediaPoolItem": item(src), "mediaType": 1, "trackIndex": x["trk"],
                                        "startFrame": sf_, "endFrame": ef_, "recordFrame": T0 + rec}]) or []
            it = res[0] if res else None
            placed += res
            if it:
                got[("video", x["trk"], x["rec"])] = it                       # keyed by the PLANNED rec for the loop below
                x["A"], x["rec_actual"], x["dur_actual"] = A, it.GetStart() - T0, it.GetDuration()
                cur = it.GetEnd() - T0
    bad, ntake, nlut, nskip = 0, 0, 0, 0
    corner = {"TL": (-1, 1), "TR": (1, 1), "BL": (-1, -1), "BR": (1, -1)}
    for x in pcs:
        it = got.get(("audio", 1, x["rec"]) if x["trk"] == "A1" else ("video", x["trk"], x["rec"]))
        x["item"] = it
        if not it:
            bad += 1; continue
        if not mixed and (it.GetLeftOffset() != x["s"] or it.GetDuration() != x["e"] - x["s"]):
            bad += 1; continue
        if mixed and x["trk"] != "A1" and abs(x["dur_actual"] - (x["e"] - x["s"] - (x["rec_actual"] - x["rec"]))) > 2:
            bad += 1; continue
        if x["key"] == "SCREEN" and x["zoom_rect"]:
            r_ = x["zoom_rect"]; cl, ct, cw, ch = crop             # decode-space rect -> full raster (AJA clean aperture, L4)
            x0, x1 = [cl + v * cw / 960 for v in (r_[0], r_[2])]; y0, y1 = [ct + v * ch / 540 for v in (r_[1], r_[3])]
            z = 1920 / (x1 - x0); cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
            it.SetProperty({"ZoomX": z, "ZoomY": z, "Pan": (960 - cx) * z, "Tilt": (cy - 540) * z})
        elif x["key"] == "PIP" and x["pip"]:
            sx, sy = corner[x["pip"]]
            px, py = 960 - MARGIN - 240, 540 - MARGIN - 180          # 480x360 PiP, 16 px from the corner
            it.SetProperty({"ZoomX": PIPZ, "ZoomY": PIPZ, "Pan": sx * px / 0.75, "Tilt": float(sy * py)})   # 4:3 Pan = px / 0.75 (L61)
        if x["trk"] == 2 and x["key"] != "PIP" and job.sources.get(x["source"]) and job.sources[x["source"]].level():
            it.SetProperty(job.sources[x["source"]].level())
        if colour == "item_lut" and x["trk"] != "A1" and lut_of(x["source"]):
            nlut += bool(it.SetLUT(1, f"{LUT_ROOT}/{lut_of(x['source'])}"))
        if x["trk"] == 2 and x["key"] != "PIP" and takes:
            A = x["A"]                                                     # reference frame of the piece (as placed)
            dur = x.get("dur_actual", x["e"] - x["s"])
            t0, t1 = A / f, (A + dur) / f
            for k in takes:
                if k == x["source"]:
                    continue
                w = (take_windows or {}).get(k)
                if w and (t0 < w[0] or (w[1] is not None and t1 > w[1])):
                    nskip += 1
                    continue
                rk = rate(k)
                if abs(rk - f) <= 0.01:
                    s = A - round(off_s(k) * f); e_ = s + dur
                else:                                                      # other-rate take: frames in the take's own rate
                    s = round((A / f - off_s(k)) * rk); e_ = s + round(dur / f * rk)
                if s >= 0:
                    ntake += bool(it.AddTake(item(k), s, e_))
            it.SelectTakeByIndex(1)
    nj = {"dissolve": 0, "fades": 0, "xfade": 0}
    for o in joins(pcs, job.raw.get("v1", {}).get("joins")):      # after takes: transitions and takes coexist (probe 10/1)
        it = pcs[o["i"]].get("item")
        if not it:
            continue
        if o["op"] == "fades":
            ok = it.SetFades({"FadeIn": o["in"], "FadeOut": o["out"]})
        else:
            ok = it.AddTransition({"type": "Cross Dissolve", "category": "simple", "position": "end", "alignment": "center",
                                   "duration": o["frames"]} if o["op"] == "dissolve" else
                                  {"type": "Cross Fade +3 dB", "category": "audio", "position": "end", "alignment": "center",
                                   "duration": o["frames"]})
        nj[o["op"]] += bool(ok)
    for ki, x in enumerate(sorted([x for x in pcs if x["trk"] == "A1"], key=lambda x: x["rec"])[1:]):
        tl.AddMarker(x["rec"], "Blue", "TECH CUT", "keep join", 1)
    if prev:
        p.SetCurrentTimeline(prev)
    return {"timeline": name, "placed": len(placed), "pieces": len(pcs), "mismatches": bad, "takes_added": ntake, "takes_outside_window": nskip,
            "item_luts": nlut, "colour": colour, "joins": nj,
            "note": "transforms belong to the item, not the take: after switching takes run `cli v1-relevel`"}


def relevel(job, name: str, go: bool = False) -> dict:
    """After take switches: give each camera item the level transform of its SELECTED take's source (job.yaml rotation).
    Only items still carrying a builder default (identity, or another source's level transform) are changed; anything
    else is the operator's hand transform and is reported, never overwritten. Only timelines named '... (ARC Edit)'. Plan unless go."""
    import sys
    sys.path.append("/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules")
    import DaVinciResolveScript as drs
    assert "(ARC Edit)" in name, "relevel only touches builder timelines named '... (ARC Edit)'"
    p = drs.scriptapp("Resolve").GetProjectManager().GetCurrentProject()
    tl = next((p.GetTimelineByIndex(i) for i in range(1, p.GetTimelineCount() + 1) if p.GetTimelineByIndex(i).GetName() == name), None)
    assert tl, f"no timeline {name}"
    by_path = {str(job.path(k)): k for k in job.sources}
    keys = ("RotationAngle", "ZoomX", "ZoomY", "Pan", "Tilt")
    ident = {"RotationAngle": 0.0, "ZoomX": 1.0, "ZoomY": 1.0, "Pan": 0.0, "Tilt": 0.0}
    full = lambda d: {**ident, **d}
    defaults = [ident] + [full(s.level()) for s in job.sources.values() if s.level()]
    same = lambda a, b: all(abs(float(a[k]) - float(b[k])) < 1e-3 for k in keys)
    plan, hand = [], []
    for it in tl.GetItemListInTrack("video", 2) or []:
        if it.GetType() == "transition" or it.GetTakesCount() < 2:
            continue
        tk = it.GetTakeByIndex(it.GetSelectedTakeIndex()) or {}
        mpi = tk.get("mediaPoolItem")
        src = by_path.get(mpi.GetClipProperty("File Path")) if mpi else None
        if not src:
            continue
        cur = {k: it.GetProperty(k) for k in keys}
        want = full(job.sources[src].level())
        if same(cur, want):
            continue
        row = {"start": it.GetStart(), "take": src, "from": cur, "to": want}
        (plan if any(same(cur, d) for d in defaults) else hand).append(row)
    if go:
        for row in plan:
            it = next(i for i in tl.GetItemListInTrack("video", 2) if i.GetType() != "transition" and i.GetStart() == row["start"])
            row["ok"] = bool(it.SetProperty(row["to"]))
    return {"timeline": name, "changes": len(plan), "applied": go, "hand_transforms_kept": hand, "plan": plan}
