"""Render the presenter column from a framing plan: one ProRes file, frame-exact, resumable.

Per run: ffmpeg seeks to the run's first frame on that camera's clock (the nearest source frame: -ss half a frame early,
accurate seek), pans the crop per frame with sendcmd, applies the camera's measured LUT, scales (lanczos) to the column
size, writes bt709 limited-range ProRes. Every piece is checked for its exact frame count; pieces whose spec is unchanged
are reused on a re-run (a sidecar holds the spec hash); the pieces are joined by stream copy into a temp file, counted
again, renamed into place, and then verify_mapping() checks that column frames show the source frames the plan says.
Pieces are removed after a verified join (JOB-0000: 24 GB of pieces on a 98 % full drive).

Refuses to render onto the OS disk or without room for pieces + join + a margin (10/2: the OS drive must not fill).
"""
from __future__ import annotations
import hashlib, json, os, shutil, subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

BYTES_PER_PIXEL_FRAME = {0: 0.08, 1: 0.18, 2: 0.36, 3: 0.54}     # ProRes Proxy / LT / 422 / HQ. MEASURED: 422 0.358 (Room A
                                                                 # 640x720), Proxy 0.0757 (Room B 1080p); LT and HQ estimated


def frame_count(path) -> int:
    r = subprocess.run(["ffprobe", "-v", "error", "-count_packets", "-select_streams", "v:0", "-show_entries",
                        "stream=nb_read_packets", "-of", "csv=p=0", str(path)], capture_output=True, text=True).stdout.strip()
    return int(r) if r.isdigit() else -1


def disk_guard(target: Path, need_bytes: float, margin_gb: float, allow_os_disk: bool = False) -> dict:
    target.mkdir(parents=True, exist_ok=True)
    if not allow_os_disk and os.stat(target).st_dev == os.stat("/").st_dev:
        raise RuntimeError(f"{target} is on the OS disk: renders go to a media drive (set edit_root)")
    free = shutil.disk_usage(target).free
    if free < need_bytes + margin_gb * 1e9:
        raise RuntimeError(f"{target}: {free / 1e9:.0f} GB free, need {need_bytes / 1e9:.0f} GB + {margin_gb} GB margin")
    return {"free_gb": round(free / 1e9, 1), "need_gb": round(need_bytes / 1e9, 1)}


def seek(t_src: float, fps: float) -> float:
    """-ss that lands on the source frame nearest t_src (accurate seek keeps the first frame with pts >= -ss)."""
    return max(0.0, (round(t_src * fps) - 0.5) / fps)


def run_spec(job, c: dict, run: dict, fps: float, luts: dict) -> dict:
    cam = c["cameras"][run["role"]]; src = job.sources[cam["source"]]
    lut = luts.get(run["role"])
    return {"src": str(job.path(cam["source"])), "ss": round(seek(job.convert(run["in"], job.program_clock, src.clock), fps), 5),
            "n": len(run["x"]), "w": run["w"], "h": run["h"], "out": list(c["layout"]["column"][2:]), "fps": fps,
            "lut": str(lut) if lut else None, "lut_md5": hashlib.md5(Path(lut).read_bytes()).hexdigest() if lut else None,
            "profile": c["render"]["prores_profile"],
            "xy": [[int(round(x)), int(round(y))] for x, y in zip(run["x"], run["y"])],
            "composite": _composite(job, run, fps)}


def _composite(job, run: dict, fps: float):
    """Two-panel composite spec (a Zoom talk: Zoom | room; slides: slides | presenter): the panel source seeked to the
    run's start on its own clock, the panel rectangle and the subject (camera crop) rectangle in the program frame."""
    cp = run.get("composite")
    if not cp:
        return None
    z = cp["panel_source"]
    return {"src": str(job.path(z)), "ss": round(seek(job.convert(run["in"], job.program_clock, job.sources[z].clock), fps), 5),
            "panel": cp["panel"], "subject": cp["subject"]}


def render_piece(spec: dict, out: Path) -> int:
    """Render one run; returns its frame count (reuses a finished piece with the same spec)."""
    h = hashlib.md5(json.dumps(spec, sort_keys=True).encode()).hexdigest()
    side = out.with_suffix(".json")
    if out.exists() and side.exists() and json.loads(side.read_text()).get("spec_md5") == h and frame_count(out) == spec["n"]:
        return spec["n"]
    side.unlink(missing_ok=True)
    cmd = out.with_suffix(".cmd")
    lines, last = [], None
    for k, xy in enumerate(spec["xy"]):                             # frame k has pts k / fps exactly (setpts below);
        if xy != last:                                              # each command is timed half a frame before its frame
            lines.append(f"{max(0.0, (k - 0.5) / spec['fps']):.5f} crop@c x {xy[0]}, crop@c y {xy[1]};"); last = xy
    cmd.write_text("\n".join(lines) + "\n")
    ow, oh = spec["out"]
    cp = spec.get("composite")
    if cp:                                                          # panel (Zoom / slides) + subject crop on black
        (zx, zy, zw, zh), (rx, ry, rw, rh) = cp["panel"], cp["subject"]
        fc = (f"[0:v]setpts=N/({spec['fps']}*TB),setparams=range=pc:color_primaries=bt709:color_trc=bt709:colorspace=bt709,"
              f"sendcmd=f='{cmd}',crop@c=w={spec['w']}:h={spec['h']}:x={spec['xy'][0][0]}:y={spec['xy'][0][1]}:exact=1,format=rgb24,"
              + (f"lut3d=file='{spec['lut']}'," if spec["lut"] else "")
              + f"scale={rw}:{rh}:flags=lanczos[room];"
              f"[1:v]setpts=N/({spec['fps']}*TB),setparams=range=pc:color_primaries=bt709:color_trc=bt709:colorspace=bt709,"
              f"format=rgb24,scale={zw}:{zh}:flags=lanczos[zoom];"
              f"color=c=black:s={ow}x{oh}:r={spec['fps']},format=rgb24[bg];[bg][zoom]overlay={zx}:{zy}:shortest=1[a];"
              f"[a][room]overlay={rx}:{ry}:shortest=1,scale=out_color_matrix=bt709:out_range=tv,format=yuv422p10le[v]")
        r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{spec['ss']:.5f}", "-i", spec["src"], "-ss", f"{cp['ss']:.5f}",
                            "-i", cp["src"], "-filter_complex", fc, "-map", "[v]", "-frames:v", str(spec["n"]), "-an",
                            "-r", str(spec["fps"]), "-c:v", "prores_ks", "-profile:v", str(spec["profile"]), "-vendor", "apl0",
                            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv",
                            str(out)], capture_output=True, text=True)
        got = frame_count(out) if r.returncode == 0 else -1
        if got == spec["n"]:
            side.write_text(json.dumps({"spec_md5": h, "frames": got}))
        cmd.unlink(missing_ok=True)
        return got
    # setpts renumbers the frames after the seek: without it the half-frame seek offset reaches the encoder's
    # constant-frame-rate sync, which dropped or doubled the first frame of a piece (found 10/3: shots 1-2 frames off)
    vf = (f"setpts=N/({spec['fps']}*TB),setparams=range=pc:color_primaries=bt709:color_trc=bt709:colorspace=bt709,"
          f"sendcmd=f='{cmd}',crop@c=w={spec['w']}:h={spec['h']}:x={spec['xy'][0][0]}:y={spec['xy'][0][1]}:exact=1,format=rgb24,"
          + (f"lut3d=file='{spec['lut']}'," if spec["lut"] else "")
          + f"scale={ow}:{oh}:flags=lanczos:out_color_matrix=bt709:out_range=tv,format=yuv422p10le")
    r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{spec['ss']:.5f}", "-i", spec["src"], "-frames:v", str(spec["n"]),
                        "-vf", vf, "-an", "-r", str(spec["fps"]), "-c:v", "prores_ks", "-profile:v", str(spec["profile"]),
                        "-vendor", "apl0", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                        "-color_range", "tv", str(out)], capture_output=True, text=True)
    got = frame_count(out) if r.returncode == 0 else -1
    if got == spec["n"]:
        side.write_text(json.dumps({"spec_md5": h, "frames": got}))
    cmd.unlink(missing_ok=True)
    return got


def _grey(path, ss: float, n: int, vf: str) -> "np.ndarray":
    import numpy as np
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{ss:.5f}", "-i", str(path), "-frames:v", str(n), "-vf",
                          vf + ",scale=160:180,format=gray", "-fps_mode", "passthrough", "-f", "rawvideo", "-"],
                         capture_output=True).stdout                # passthrough: no frame-rate sync (it doubles the first frame)
    x = np.frombuffer(raw, np.uint8).reshape(-1, 180 * 160).astype("float32")
    return x - x.mean(1, keepdims=True)


def verify_mapping(job, c: dict, runs: list[dict], fps: float, out_file: Path, max_runs: int = 16) -> dict:
    """Does column frame k show the source frame the plan says? For up to max_runs runs (spread over the program) two
    frames of the run (the first and the middle, else further points across it when those are static) are correlated
    with that camera's frames n-2..n+2 at the planned crop.
    A frame counts only when it can tell neighbours apart (motion); returns {checked, exact, off: [...]}."""
    import numpy as np
    step = max(1, len(runs) // max_runs)
    pos = 0; starts = []
    for r in runs:
        starts.append(pos); pos += len(r["x"])
    checked, exact, off, flat = 0, 0, [], 0
    for i in range(0, len(runs), step):
        r = runs[i]
        # a composite (slides | presenter, Zoom | room) holds the camera crop in its subject rectangle: compare that.
        # Skipping composites left a mixed layout (every run a composite) with nothing checked (Room B V2, 10/4)
        cp = r.get("composite")
        out_vf = "crop={2}:{3}:{0}:{1}".format(*cp["subject"]) if cp else "null"
        cam = c["cameras"][r["role"]]; src = job.sources[cam["source"]]
        n0 = round(job.convert(r["in"], job.program_clock, src.clock) * fps)
        n_r = len(r["x"]); got_here = 0                          # first + middle frame; when those are static (a long
        for j in dict.fromkeys([0, n_r // 2] + [int(n_r * q) for q in (0.125, 0.25, 0.375, 0.625, 0.75, 0.875)]):
            if got_here >= 2:                                      #   lectern run, JOB-0000 S1/S3: 0 checked) try more
                break                                              #   points across the run until two can be told apart
            crop = f"crop={r['w']}:{r['h']}:{int(round(r['x'][j]))}:{int(round(r['y'][j]))}"
            ref = _grey(job.path(cam["source"]), seek((n0 + j - 2) / fps, fps), 5, crop)
            got = _grey(out_file, seek((starts[i] + j) / fps, fps), 1, out_vf)
            if len(ref) < 5 or len(got) < 1:
                off.append({"run": i, "frame": j, "error": "decode"}); continue
            cc = [float((got[0] * q).sum() / (np.sqrt((got[0] ** 2).sum() * (q ** 2).sum()) + 1e-9)) for q in ref]
            best = int(np.argmax(cc))
            if cc[best] - sorted(cc)[-2] < 0.002:                    # static shot: neighbours look the same
                flat += 1; continue
            checked += 1; got_here += 1
            if best == 2:
                exact += 1
            else:
                off.append({"run": i, "shot": r["shot"], "frame": j, "source_frames_off": best - 2})
    return {"checked": checked, "exact": exact, "static_skipped": flat, "off": off, "ok": not off and checked > 0}


def render(job, c: dict, runs: list[dict], fps: float, out_file: Path, luts: dict, allow_os_disk: bool = False) -> dict:
    """runs -> out_file. Returns {file, frames, expected, ok, pieces_reused, bad}; raises on disk problems."""
    rc = c["render"]; ow, oh = c["layout"]["column"][2:]
    total = sum(len(r["x"]) for r in runs)
    est = total * ow * oh * BYTES_PER_PIXEL_FRAME.get(rc["prores_profile"], 0.4)
    pieces = out_file.parent / (out_file.stem + "_pieces")
    guard = disk_guard(pieces, 2 * est, rc["margin_gb"], allow_os_disk)
    specs = [run_spec(job, c, r, fps, luts) for r in runs]
    paths = [pieces / f"run_{i:04d}.mov" for i in range(len(runs))]
    stale = {p.name for p in pieces.glob("run_*.mov")} - {p.name for p in paths}
    for name in stale:
        (pieces / name).unlink()
    before = sum(p.exists() for p in paths)
    from .track import run_chunks
    got = run_chunks(lambda sp: render_piece(*sp), list(zip(specs, paths)), rc["workers"], "column render: shots", media=False)
    bad = [{"run": i, "expected": s["n"], "got": g} for i, (s, g) in enumerate(zip(specs, got)) if g != s["n"]]
    res = {"file": str(out_file), "expected": total, "runs": len(runs), "pieces_present_before": before, "bad": bad, **guard}
    if bad:
        return {**res, "ok": False, "frames": None}
    lst = pieces / "concat.txt"
    lst.write_text("".join("file '" + str(p).replace("'", "'\\''") + "'\n" for p in paths))
    tmp = out_file.with_name(out_file.stem + ".partial" + out_file.suffix)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(lst), "-c", "copy", str(tmp)], check=True)
    frames = frame_count(tmp)
    if frames != total:
        tmp.unlink(missing_ok=True)
        return {**res, "ok": False, "frames": frames}
    tmp.replace(out_file)
    mapping = verify_mapping(job, c, runs, fps, out_file)
    if mapping["ok"] and not rc["keep_pieces"]:
        shutil.rmtree(pieces, ignore_errors=True)
    return {**res, "ok": mapping["ok"], "frames": frames, "mapping": mapping, "size_gb": round(out_file.stat().st_size / 1e9, 2)}
