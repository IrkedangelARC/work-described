"""Encode a classroom timeline for delivery (LESSONS D2: "just encode the damn thing in davinci", native rate, H.264 .mp4).

  1. Resolve Deliver: the whole timeline, H.264 High 1080p at the job's frame rate, 12 Mbps, audio as 24-bit PCM, into
     <edit_root>/exports/<name>.resolve_raw.mov (kept: the picture is never encoded twice).
  2. ffmpeg: picture copied, audio encoded ONCE to AAC 320k with AudioToolbox (aac_at keeps the true peak; ffmpeg's aac
     overshot ~1.2 dB on JOB-0000), +faststart -> <name>.mp4.
  3. Gates on the FINAL file: loudness inside the delivery window and true peak under the limit (a Resolve render alone has
     skipped the loudness chain before: always measure the file that ships), frame count = the timeline's, audio and
     picture the same length.
The timeline's audio is used as rendered (track A1 = the audio_repair master, already at the delivery loudness), so a
hand edit of the timeline is honoured; nothing else is reprocessed here. Exception: classroom.end.fade_s fades the sound out
over the timeline's last fade_s at the AAC encode (Resolve's SetFades does not apply to audio items; the picture fade is on the
timeline). Refuses to overwrite an existing deliverable.
"""
from __future__ import annotations
import json, subprocess, time
from pathlib import Path

from . import config, edit_root
from .column import disk_guard, frame_count
from .sbs import _resolve, check_project, tail

GATE = {"lufs": [-15.5, -13.0], "true_peak_max": -1.0}       # docs/defaults.yaml deliver.*


def loudness(path) -> tuple[float, float]:
    r = subprocess.run(["ffmpeg", "-v", "info", "-nostats", "-i", str(path), "-vn", "-af", "ebur128=peak=true", "-f", "null", "-"],
                       capture_output=True, text=True).stderr
    tail = r[r.rfind("Summary:"):]
    return float(tail.split("I:")[1].split("LUFS")[0]), float(tail.split("Peak:")[1].split("dBFS")[0])


def duration(path, stream: str) -> float:
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", stream, "-show_entries", "stream=duration", "-of", "csv=p=0",
                        str(path)], capture_output=True, text=True).stdout.strip()
    return float(r) if r else -1.0


def render(job, timeline: str, name: str, kbps: int = 12000, progress=print) -> dict:
    c = config(job)
    out = edit_root(job) / "exports"
    final, raw = out / f"{name}.mp4", out / f"{name}.resolve_raw.mov"
    if final.exists():
        raise FileExistsError(f"{final} exists; not overwriting (pick a new name or remove it)")
    r = _resolve(); p = r.GetProjectManager().GetCurrentProject()
    probs = check_project(p, job, c)
    tl = next((p.GetTimelineByIndex(i) for i in range(1, p.GetTimelineCount() + 1) if p.GetTimelineByIndex(i).GetName() == timeline), None)
    if tl is None:
        probs.append(f"no timeline '{timeline}'")
    if p.IsRenderingInProgress():
        probs.append("Resolve is already rendering")
    if probs:
        return {"ok": False, "problems": probs}
    n = tl.GetEndFrame() - tl.GetStartFrame()
    disk_guard(out, 2.2 * n / job.f * kbps * 125, 5)
    if not raw.exists():
        page = r.GetCurrentPage()
        p.SetCurrentTimeline(tl); r.OpenPage("deliver")
        p.SetCurrentRenderFormatAndCodec("mov", "H264")
        ok = p.SetRenderSettings({"SelectAllFrames": True, "TargetDir": str(out), "CustomName": raw.stem, "ExportVideo": True,
                                  "ExportAudio": True, "FormatWidth": 1920, "FormatHeight": 1080, "FrameRate": float(job.fps),
                                  "VideoQuality": kbps, "AudioCodec": "lpcm", "AudioSampleRate": 48000, "AudioBitDepth": 24})
        jid = p.AddRenderJob()
        t0 = time.time(); p.StartRendering([jid])
        while p.IsRenderingInProgress():
            time.sleep(30)
            progress(f"render {(time.time() - t0) / 60:.1f} min {p.GetRenderJobStatus(jid).get('CompletionPercentage')}%")
        st = p.GetRenderJobStatus(jid); p.DeleteRenderJob(jid)
        if page:
            r.OpenPage(page)
        if st.get("JobStatus") != "Complete" or not raw.exists():
            return {"ok": False, "problems": [f"Resolve render {st} (settings accepted: {ok})"]}
    tmp = out / f"{name}.partial.mp4"
    fade_s = tail(job)[1]
    af = ["-af", f"afade=t=out:st={n / job.f - fade_s:.3f}:d={fade_s:.3f}"] if fade_s else []
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(raw), "-map", "0:v:0", "-map", "0:a:0", "-c:v", "copy", *af, "-c:a", "aac_at",
                    "-b:a", "320k", "-ar", "48000", "-movflags", "+faststart", str(tmp)], check=True)
    I, tp = loudness(tmp)
    frames = frame_count(tmp)
    dv, da = duration(tmp, "v:0"), duration(tmp, "a:0")
    res = {"file": str(final), "raw": str(raw), "timeline": timeline, "frames": frames, "frames_expected": n,
           "video_s": round(dv, 3), "audio_s": round(da, 3), "lufs": I, "true_peak": tp, "size_gb": round(tmp.stat().st_size / 1e9, 2)}
    problems = []
    if frames != n:
        problems.append(f"frame count {frames} != timeline {n}")
    if abs(dv - da) > 0.05:
        problems.append(f"audio {da:.3f} s vs picture {dv:.3f} s")
    if not (GATE["lufs"][0] <= I <= GATE["lufs"][1]):
        problems.append(f"loudness {I} LUFS outside {GATE['lufs']}")
    if tp > GATE["true_peak_max"]:
        problems.append(f"true peak {tp} dBTP over {GATE['true_peak_max']}")
    res["problems"] = problems; res["ok"] = not problems
    if problems:
        tmp.rename(out / f"{name}.FAILED-GATE.mp4")
    else:
        tmp.rename(final)
    (out / f"{name}.deliver.json").write_text(json.dumps(res, indent=1))
    return res
