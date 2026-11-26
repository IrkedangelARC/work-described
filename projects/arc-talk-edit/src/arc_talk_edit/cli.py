"""arc-talk-edit CLI. P0: `info` (load a job, check media, print clocks). Stages land in P1+."""
from __future__ import annotations
import argparse, json, sys
from pathlib import Path
from . import job as jobmod


def cmd_info(a) -> int:
    j = jobmod.load(a.job)
    media = Path(j.raw.get("media_root", "")).expanduser()
    print(f"{j.arc}  {j.title}  fps {j.fps} ({j.f:.5f})  root {j.root}")
    print(f"clocks (ref {j.ref}): {j.offsets}" + (f"  aja_rec {j.aja_rec}" if "aja" in j.offsets else ""))
    missing = 0
    for k, s in j.sources.items():
        p = j.path(k)
        ok = p.exists(); missing += not ok
        print(f"  {s.key:5s} {s.clock:4s} {'ok ' if ok else 'MISSING'} {s.role}  {p}")
    if j.program:
        keep = sum(b - a for a, b in j.keeps())
        print(f"program {j.program['in']} -> {j.program['out']} s ({j.program_clock} clock), {len(j.program.get('cuts', []))} cuts, {keep / 60:.2f} min kept")
    return 1 if missing else 0


def cmd_sync(a) -> int:
    from . import sync
    j = jobmod.load(a.job)
    work = Path(__file__).resolve().parents[1] / "work" / j.arc
    out = sync.run(j, work)
    bad = 0
    for r in out["pairs"]:
        e = r.get("error_ms")
        flag = "" if e is None else ("ok" if abs(e) <= a.tol_ms else "OFF"); bad += flag == "OFF"
        print(f"{r['source']:7s} offset {r['offset_s']:+.4f}s  drift {r['drift_ms'] if r['drift_ms'] is None else round(r['drift_ms'], 1)} ms"
              f"  expected {r.get('expected_s', float('nan')):+.4f}s  error {e if e is None else round(e, 2)} ms  {flag}")
    return 1 if bad else 0


def cmd_dropouts(a) -> int:
    from . import scans
    j = jobmod.load(a.job)
    out = scans.run_dropouts(j, Path(__file__).resolve().parents[1] / "work" / j.arc)
    g = j.raw["scans"]["dropouts"].get("golden", {})
    got = {"frames": out["frames"], "bad": len(out["bad"]), "clusters": len(out["clusters"])}
    same = not g or got == g
    gf = j.raw["scans"]["dropouts"].get("golden_file")
    if gf:
        import json
        ref = json.load(open(j.root / gf))
        exact = ref["bad"] == out["bad"]
        print("bad-frame list identical to", gf, ":", exact); same = same and exact
    print("dropouts", got, "golden", g, "MATCH" if same else "DIFFERENT")
    return 0 if same else 1


def cmd_pauses(a) -> int:
    from . import scans
    j = jobmod.load(a.job)
    got = scans.run_pauses(j); g = j.raw["scans"]["pauses"].get("golden")
    print("pauses", got, "golden", g, "MATCH" if not g or got == g else "DIFFERENT")
    return 0 if not g or got == g else 1


def cmd_run(a) -> int:
    from . import stages
    j = jobmod.load(a.job)
    stages.run(j, a.stage, start=a.from_, force=a.force)
    if a.build_stack:                       # one command to a built SYNC STACK (P1 done criterion)
        from . import stack
        out = stack.build(j, go=True)
        print("SYNC STACK:", out["timeline"], "built" if out.get("built") else "NOT built", out.get("problems") or "",
              "all items at expected frames" if out.get("all_at_expected") else "")
        return 0 if out.get("built") else 1
    return 0


def cmd_stack(a) -> int:
    from . import stack
    import json
    out = stack.build(jobmod.load(a.job), go=a.go)
    print(json.dumps(out, indent=1, default=str))
    return 0 if not out["problems"] else 1


def cmd_v1(a) -> int:
    from . import v1
    import json
    j = jobmod.load(a.job); cfg = j.raw["v1"]
    prog = json.load(open(a.program))
    pcs = v1.pieces(j, prog, cfg["keymap"])
    print(f"{len(pcs)} pieces from {a.program}")
    if not a.go:
        print("plan only (pass --go to build a NEW timeline)"); return 0
    out = v1.place(j, pcs, name=a.name, takes=cfg.get("takes"), colour=cfg.get("colour", "input_lut"),
                   program_audio=str(Path((j.raw.get("stack") or {}).get("program_audio", "")).expanduser()),
                   take_windows=cfg.get("take_windows"))
    print(json.dumps(out, indent=1)); return 0 if not out["mismatches"] else 1


def cmd_v1_relevel(a) -> int:
    from . import v1
    import json
    out = v1.relevel(jobmod.load(a.job), a.name, go=a.go)
    print(json.dumps(out, indent=1, default=str))
    return 0 if all(r.get("ok", True) for r in out["plan"]) else 1


def cmd_playground(a) -> int:
    from . import playground as pg
    import json
    cat = pg.catalog(pg.scan())
    work = Path(__file__).resolve().parents[1] / "work" / "PLAYGROUND"
    if a.retry:
        import sys as _s
        _s.path.append("/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules")
        import DaVinciResolveScript as drs
        p = drs.scriptapp("Resolve").GetProjectManager().GetCurrentProject()
        assert p.GetName() == pg.PROJECT, f"open {pg.PROJECT} first (current: {p.GetName()})"
        out = pg.retry(p, cat); drs.scriptapp("Resolve").GetProjectManager().SaveProject()
        short = {b: r for b, r in out.items() if r["imported"] != r["files"]}
        print(json.dumps({"bins_fixed": len(out), "still_short": short}, indent=1)); return 0
    if a.copy:
        out = pg.copy(pg.copy_plan(cat), work / "copy_manifest.json")
        print(json.dumps(out, indent=1)); return 0 if not out["bad"] else 1
    md = pg.write(cat, work)
    print(md.read_text())
    if not a.go:
        print("plan only (pass --go to create the Resolve project)"); return 0
    out = pg.build(cat)
    print(json.dumps(out, indent=1)); return 0 if not out["short"] else 1


def cmd_audio_crunch(a) -> int:
    """Upstream-clipping check: recorded feed vs a clean iso of the same voice (audio_qc)."""
    from . import audio_qc as Q
    t1 = a.to if a.to is not None else float(__import__("subprocess").run(["ffprobe", "-v", "error", "-show_entries",
        "format=duration", "-of", "csv=p=0", a.feed], capture_output=True, text=True).stdout) - 5
    r = Q.analyse(a.feed, a.iso, a.offset, a.from_, t1)
    if a.out:
        Path(a.out).parent.mkdir(parents=True, exist_ok=True); Path(a.out).write_text(json.dumps(r))
    print(r["verdict"] + (f"; seconds with clipped frames: {len(r['clipped_seconds'])}" if r.get("clipped_seconds") else ""))
    print("   offset vs iso level:", [(c[0], round(c[1], 1)) for c in r["curve"]])
    return 2 if r.get("kind") == "HARD CLIP" else 0


def cmd_grade_finish(a) -> int:
    from . import grade as G
    print(json.dumps(G.finish(a.src, a.t, tuple(a.box), a.out, a.chroma, a.title or Path(a.out).stem, a.wb_strength), indent=1)); return 0


def cmd_grade_backlight(a) -> int:
    from . import grade as G
    print(json.dumps(G.backlight(a.src, a.t, a.out_dir, a.key), indent=1)); return 0


def cmd_power_window(a) -> int:
    from . import power_window as P
    print(json.dumps(P.render(a.src, a.t, a.dur, a.key, a.out_dir), indent=1)); return 0


def cmd_classroom_build(a) -> int:
    """SBS timeline (slides | presenter column) from the classroom stages; plan unless --go; --verify renders checks."""
    from .classroom import sbs
    j = jobmod.load(a.job)
    out = sbs.build(j, go=a.go, name=a.name, raw_on=a.raw)
    print(json.dumps(out, indent=1, default=str))
    if out.get("problems"):
        return 1
    if not a.go and not a.verify:
        print("plan only (pass --go to build a NEW timeline)"); return 0
    if a.go and not out.get("ok"):
        return 1
    if a.verify:
        v = sbs.verify(j, name=a.name)
        print(json.dumps(v, indent=1)); return 0 if v["ok"] else 1
    return 0


def cmd_classroom_deliver(a) -> int:
    """Encode a classroom timeline: Resolve H.264 render + one AAC encode, gated on the final file's loudness and length."""
    from .classroom import deliver
    out = deliver.render(jobmod.load(a.job), a.name, a.out, a.kbps)
    print(json.dumps(out, indent=1)); return 0 if out.get("ok") else 1


def cmd_picture_sync(a) -> int:
    from . import picture_sync
    j = jobmod.load(a.job)
    keys = a.sources or [k for k in ((j.raw.get("scans") or {}).get("cameras") or []) if k != a.ref]
    bad = 0
    for r in picture_sync.run(j, a.ref, keys, a.at, a.dur):
        e = r["error_frames"]; flag = "?" if e is None else ("ok" if abs(e) <= a.tol_frames else "OFF"); bad += flag != "ok"
        print(f"{r['source']:7s} offset {r['offset_s']}s  spread {r['spread_s']}s  expected {r['expected_s']:+.4f}s  "
              f"error {e} fr  {flag}  " + " ".join(f"[{w['at']:.0f}s {w['offset_s']:+.3f} r={w['r']}]" for w in r["windows"]))
    return 1 if bad else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="arc-talk-edit")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("info", help="load a job.yaml, check media, print clocks"); p.add_argument("job"); p.set_defaults(fn=cmd_info)
    p = sub.add_parser("sync", help="audio xcorr every sync pair vs the reference; compare to job.yaml clocks")
    p.add_argument("job"); p.add_argument("--tol-ms", type=float, default=5.0); p.set_defaults(fn=cmd_sync)
    p = sub.add_parser("dropouts", help="screen-feed bars dropout scan; compare to job.yaml golden"); p.add_argument("job"); p.set_defaults(fn=cmd_dropouts)
    p = sub.add_parser("pauses", help="silencedetect long pauses; compare to job.yaml golden"); p.add_argument("job"); p.set_defaults(fn=cmd_pauses)
    p = sub.add_parser("run", help="run a stage, `all` (talk chain) or `classroom` (classroom-capture chain); skips unchanged"); p.add_argument("stage"); p.add_argument("job")
    p.add_argument("--from", dest="from_"); p.add_argument("--force", action="store_true")
    p.add_argument("--build-stack", action="store_true", help="after the stages, create the SYNC STACK timeline in Resolve")
    p.set_defaults(fn=cmd_run)
    p = sub.add_parser("stack", help="SYNC STACK plan (default) or build a NEW timeline with --go"); p.add_argument("job")
    p.add_argument("--go", action="store_true"); p.set_defaults(fn=cmd_stack)
    p = sub.add_parser("v1", help="program -> pieces (plan) or a NEW Take Selector timeline with --go"); p.add_argument("job")
    p.add_argument("--program", required=True); p.add_argument("--name", default="V1 (ARC Edit)"); p.add_argument("--go", action="store_true")
    p.set_defaults(fn=cmd_v1)
    p = sub.add_parser("v1-relevel", help="after take switches: level each camera item for its selected take (plan; --go applies)")
    p.add_argument("job"); p.add_argument("--name", default="V1 (ARC Edit)"); p.add_argument("--go", action="store_true")
    p.set_defaults(fn=cmd_v1_relevel)
    p = sub.add_parser("playground", help="catalog every show's media; --go creates the 'ARC Edit Playground' Resolve project")
    p.add_argument("--go", action="store_true")
    p.add_argument("--retry", action="store_true", help="import files a batch import dropped, one at a time, into their bins")
    p.add_argument("--copy", action="store_true", help="copy the useful Expansion archive media to the fast SSDs (md5-verified)")
    p.set_defaults(fn=cmd_playground)
    p = sub.add_parser("audio-crunch", help="find upstream clipping in a recorded feed vs a clean iso of the same voice "
                       "(CLEAN / COMPRESSION / LIMITER / HARD CLIP; exit 2 on HARD CLIP)")
    p.add_argument("feed"); p.add_argument("iso"); p.add_argument("--offset", type=float, required=True, help="iso time minus feed time (s)")
    p.add_argument("--from", dest="from_", type=float, default=0.0); p.add_argument("--to", type=float)
    p.add_argument("--out", help="write the full result JSON here"); p.set_defaults(fn=cmd_audio_crunch)
    p = sub.add_parser("grade-finish", help="measured finish LUT (33^3): WB from a NEUTRAL patch, black p0.5, S + shoulder, chroma trim")
    p.add_argument("src"); p.add_argument("t", type=float); p.add_argument("box", type=int, nargs=4, metavar=("X0", "Y0", "X1", "Y1"))
    p.add_argument("--out", required=True, help=".cube path"); p.add_argument("--chroma", type=float, default=0.93)
    p.add_argument("--wb-strength", type=float, default=1.0, help="0..1: how far to neutralise the patch (a wall lit by the screens: ~0.4)")
    p.add_argument("--title"); p.set_defaults(fn=cmd_grade_finish)
    p = sub.add_parser("grade-backlight", help="backlit/low-light global LUT + face power-window stills sheet")
    p.add_argument("src"); p.add_argument("t", type=float); p.add_argument("--key", required=True)
    p.add_argument("--out-dir", required=True); p.set_defaults(fn=cmd_grade_backlight)
    p = sub.add_parser("power-window", help="render global + tracked face power-window versions of a clip (ProRes HQ 59.94)")
    p.add_argument("src"); p.add_argument("t", type=float); p.add_argument("dur", type=float); p.add_argument("--key", required=True)
    p.add_argument("--out-dir", required=True); p.set_defaults(fn=cmd_power_window)
    p = sub.add_parser("classroom-build", help="classroom capture: SBS timeline (slides | presenter column) in Resolve from "
                       "`run classroom` outputs; plan unless --go")
    p.add_argument("job"); p.add_argument("--go", action="store_true"); p.add_argument("--name", default="V1 SBS (ARC Edit)")
    p.add_argument("--raw", action="store_true", help="raw recorder audio on, master muted (default: master on)")
    p.add_argument("--verify", action="store_true", help="render 1 s slices through Deliver and compare both regions with the sources")
    p.set_defaults(fn=cmd_classroom_build)
    p = sub.add_parser("classroom-deliver", help="encode a classroom timeline from Resolve (H.264 1080p native rate, AAC 320k); "
                       "gates loudness, true peak, frame count on the final file")
    p.add_argument("job"); p.add_argument("--name", default="V1 SBS (ARC Edit)", help="timeline"); p.add_argument("--out", required=True,
                   help="deliverable name, no extension (lands in <edit_root>/exports)")
    p.add_argument("--kbps", type=int, default=12000); p.set_defaults(fn=cmd_classroom_deliver)
    p = sub.add_parser("picture-sync", help="motion xcorr between cameras; compare to job.yaml clocks (cameras only: sync a "
                       "slide feed by its own audio)")
    p.add_argument("job"); p.add_argument("--ref", required=True); p.add_argument("sources", nargs="*")
    p.add_argument("--at", type=float, nargs="+", default=[1500.0, 3500.0, 5000.0]); p.add_argument("--dur", type=float, default=300.0)
    p.add_argument("--tol-frames", type=float, default=1.0); p.set_defaults(fn=cmd_picture_sync)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
