"""ARC Edit Playground: one Resolve project holding media from every ARC show/job, as a proof-of-concept workspace.

scan()    -> every video/audio file on the mounted media drives (read-only walk)
catalog() -> pure: bins (show / recorder folder), duplicates folded to one copy, exclusions listed with the reason
build()   -> creates the Resolve project (never reuses or edits another project) and imports by reference, no copies.
CLI: `arc-talk-edit playground [--go]` (plan by default). Catalog: work/PLAYGROUND/catalog.json + catalog.md.
"""
from __future__ import annotations
import json
import os
from collections import defaultdict
from pathlib import Path

PROJECT = "ARC Edit Playground"
EXT = {".mov", ".mp4", ".mxf", ".wav", ".mts", ".m4v", ".braw"}
# drive order = which copy wins when a file exists twice (working drives first, archives last)
DRIVES = ["Work A", "Work B", "Fast SSD", "Card", "DRIVE", "Archive B"]
PRUNE = {"CacheClip", "Resolve", "Davinci Projects", ".Spotlight-V100", ".Trashes", ".fseventsd"}
# path fragment -> reason (personal media and app test material stay out unless the operator adds them back)
EXCLUDE = {"/Personal": "personal", "/Music/": "personal", "Test Show": "app test", "/sample capture/": "app test",
           "/Desktop/": "desktop backup"}
MIN_BYTES = 5_000_000
# known jobs: media root -> label (job.yaml media_root)
JOBS = {"Work A/talk-a": "Talk A", "Work B/talk-b": "Talk B", "Work B/talk-b_masters": "Talk B/masters",
        "Card/AHSQ": "Talk A/SQ card", "Fast SSD/Lecture FINAL.mov": "Lecture/final"}


def scan(drives=DRIVES) -> list[dict]:
    out = []
    for d in drives:
        top = Path("/Volumes") / d
        if not top.is_dir():
            continue
        for dp, dns, fns in os.walk(top):
            dns[:] = [n for n in dns if n not in PRUNE and not n.startswith(".")]
            for fn in fns:
                if fn.startswith("._") or Path(fn).suffix.lower() not in EXT:
                    continue
                p = Path(dp) / fn
                try:
                    out.append({"path": str(p), "size": p.stat().st_size})
                except OSError:
                    pass
    return out


def bin_of(path: str) -> str:
    rel = path.split("/Volumes/", 1)[1]
    drive, _, rest = rel.partition("/")
    if rest.startswith("ARC Edit Playground/"):        # fast copy: bin it like its DRIVE original
        rel = "DRIVE/" + rest.split("/", 1)[1]
    for root, label in JOBS.items():
        if rel == root or rel.startswith(root + "/"):
            sub = rel[len(root) + 1:].split("/")[:-1]
            return "/".join([label] + sub[:1])
    parts = rel.split("/")[1:-1]                      # drop the drive and the file name
    for skip in ("Archive", "Archive Processed", "Drive Downloads", "Archive Dump"):
        if parts and parts[0] == skip:
            parts = parts[1:]
    if not parts:
        return "Loose files"
    return "/".join(parts[:2])


def catalog(files: list[dict]) -> dict:
    rank = {d: i for i, d in enumerate(DRIVES)}
    drive = lambda p: p.split("/")[2]
    best, excluded = {}, []
    for f in sorted(files, key=lambda f: rank.get(drive(f["path"]), 99)):
        why = next((r for frag, r in EXCLUDE.items() if frag in f["path"]), None)
        if not why and f["size"] < MIN_BYTES:
            why = "under 5 MB"
        if why:
            excluded.append({**f, "why": why}); continue
        k = (Path(f["path"]).name, f["size"])
        if k in best:
            excluded.append({**f, "why": f"duplicate of {best[k]['path']}"}); continue
        best[k] = f
    bins = defaultdict(list)
    for f in best.values():
        bins[bin_of(f["path"])].append(f["path"])
    return {"project": PROJECT, "bins": {k: sorted(v) for k, v in sorted(bins.items())}, "excluded": excluded,
            "files": len(best), "bytes": sum(f["size"] for f in best.values())}


def write(cat: dict, work: Path) -> Path:
    work.mkdir(parents=True, exist_ok=True)
    (work / "catalog.json").write_text(json.dumps(cat, indent=1))
    why = defaultdict(lambda: [0, 0])
    for x in cat["excluded"]:
        k = "duplicate" if x["why"].startswith("duplicate") else x["why"]
        why[k][0] += 1; why[k][1] += x["size"]
    L = [f"# {PROJECT} catalog", "", f"{cat['files']} files, {cat['bytes'] / 1e12:.2f} TB, {len(cat['bins'])} bins "
         "(linked in place, nothing copied).", "", "| Bin | Files |", "|---|---|"]
    L += [f"| {k} | {len(v)} |" for k, v in cat["bins"].items()]
    L += ["", "## Excluded (add back by editing EXCLUDE in arc_talk_edit/playground.py)", "", "| Reason | Files | GB |", "|---|---|---|"]
    L += [f"| {k} | {n} | {b / 1e9:.1f} |" for k, (n, b) in sorted(why.items())]
    (work / "catalog.md").write_text("\n".join(L) + "\n")
    return work / "catalog.md"


def retry(p, cat: dict, folder=None) -> dict:
    """Import every catalog file missing from the pool ONE AT A TIME into its bin. A batch ImportMedia silently drops
    capture-device files named like HDMI-A_Jul14_08-57-06.mp4 (sequence-style digits; 28 of them 10/1); alone they import.
    Files that still fail are reported (e.g. 'moov atom not found' = unfinalised recording)."""
    mp = p.GetMediaPool(); root = mp.GetRootFolder()
    have, by_name = {}, {}

    def walk(f, path):
        by_name[path] = f
        for c in f.GetClipList() or []:
            have[c.GetClipProperty("File Path")] = (c, path)
        for sub in f.GetSubFolderList() or []:
            walk(sub, f"{path}/{sub.GetName()}".lstrip("/"))
    walk(root, "")
    if folder is None:
        def folder(path):
            if path in by_name:
                return by_name[path]
            parent, _, name = path.rpartition("/")
            by_name[path] = mp.AddSubFolder(folder(parent), name)
            return by_name[path]
    res = {}
    for b, paths in cat["bins"].items():
        miss = [x for x in paths if x not in have or have[x][1] != b]
        if not miss:
            continue
        fo = folder(b); ok = 0
        for x in miss:
            if x in have:                                   # imported earlier into the wrong bin
                ok += bool(mp.MoveClips([have[x][0]], fo)); continue
            mp.SetCurrentFolder(fo)
            ok += bool(mp.ImportMedia([x]))
        res[b] = {"files": len(paths), "imported": len(paths) - len(miss) + ok}
    return res


def build(cat: dict) -> dict:
    """Create the playground project and import every bin by reference. Saves the open project first; refuses to touch an
    existing project of the same name (re-run imports only into a fresh project)."""
    import sys
    sys.path.append("/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules")
    import DaVinciResolveScript as drs
    pm = drs.scriptapp("Resolve").GetProjectManager()
    prev = pm.GetCurrentProject().GetName()
    assert PROJECT not in (pm.GetProjectListInCurrentFolder() or []), f"{PROJECT} exists; not touching it"
    pm.SaveProject()
    p = pm.CreateProject(PROJECT)
    assert p, "CreateProject failed"
    p.SetSetting("timelineFrameRate", "59.94")
    mp = p.GetMediaPool(); root = mp.GetRootFolder()
    folders, res = {"": root}, {}

    def folder(path: str):
        if path in folders:
            return folders[path]
        parent, _, name = path.rpartition("/")
        folders[path] = mp.AddSubFolder(folder(parent), name)
        return folders[path]
    for b, paths in cat["bins"].items():
        mp.SetCurrentFolder(folder(b))
        got = mp.ImportMedia(paths) or []
        res[b] = {"files": len(paths), "imported": len(got)}
    res = {**res, **retry(p, cat, folder)}
    pm.SaveProject()
    return {"project": PROJECT, "previous_project": prev, "bins": len(res),
            "imported": sum(r["imported"] for r in res.values()), "files": cat["files"],
            "short": {b: r for b, r in res.items() if r["imported"] != r["files"]}}


# ---- fast copies (10/1: copy any useful media to a faster drive) ----------------------------------------
# DRIVE is a USB HDD; copies go to the PCIe SSDs under "<drive>/ARC Edit Playground/<path inside DRIVE>".
# The archive stays read-only and authoritative; catalog() prefers these copies (same name + size, faster drive first).
COPY_ROOT = "ARC Edit Playground"
COPY_TO = {   # catalog bin -> destination drive; anything not listed stays on DRIVE only
    "Talk C": "Fast SSD", "Talk C/Multitracks": "Fast SSD",
    **{b: "Work A" for b in ["Lecture B", "Lecture B/Multitrack", "Workshop", "Loose files"]},
}
SMALL_BIN = 20e9                       # every other bin under this goes to Work A too
SKIP = ("Audio Master .mov", "/test.mov", "draft V1.mov", "draft V2.mov")


def copy_plan(cat: dict) -> list[dict]:
    plan = []
    for b, paths in cat["bins"].items():
        src = [p for p in paths if p.startswith("/Volumes/DRIVE/") and not p.endswith(SKIP)]
        size = sum(os.path.getsize(p) for p in src)
        drive = COPY_TO.get(b) or ("Work A" if src and size < SMALL_BIN else None)
        for p in src if drive else []:
            plan.append({"bin": b, "src": p, "dst": f"/Volumes/{drive}/{COPY_ROOT}/{p.split('/Volumes/DRIVE/', 1)[1]}",
                         "size": os.path.getsize(p)})
    return plan


def copy(plan: list[dict], manifest: Path, chunk: int = 64 << 20) -> dict:
    """Stream-copy with md5 of the source read, then md5 the written copy; resumable via the manifest (skips verified)."""
    import hashlib, shutil
    done = json.loads(manifest.read_text()) if manifest.exists() else {}
    for i, x in enumerate(plan, 1):
        if done.get(x["dst"], {}).get("ok") and os.path.exists(x["dst"]) and os.path.getsize(x["dst"]) == x["size"]:
            continue
        free = shutil.disk_usage(Path(x["dst"]).parts[0] + "/".join(Path(x["dst"]).parts[1:3])).free
        if free - x["size"] < 100e9:                     # keep >= 100 GB free on the target
            done[x["dst"]] = {"ok": False, "why": "target would drop under 100 GB free"}; continue
        Path(x["dst"]).parent.mkdir(parents=True, exist_ok=True)
        tmp = x["dst"] + ".part"; h = hashlib.md5()
        with open(x["src"], "rb") as a, open(tmp, "wb") as b:
            while (buf := a.read(chunk)):
                h.update(buf); b.write(buf)
        h2 = hashlib.md5()
        with open(tmp, "rb") as b:
            while (buf := b.read(chunk)):
                h2.update(buf)
        ok = h.hexdigest() == h2.hexdigest() and os.path.getsize(tmp) == x["size"]
        if ok:
            os.replace(tmp, x["dst"]); shutil.copystat(x["src"], x["dst"])
        done[x["dst"]] = {"src": x["src"], "size": x["size"], "md5": h.hexdigest(), "ok": ok}
        manifest.write_text(json.dumps(done, indent=1))
        print(f"[{i}/{len(plan)}] {'OK ' if ok else 'BAD'} {x['size'] / 1e9:6.1f} GB {x['dst']}", flush=True)
    return {"files": len(plan), "ok": sum(v.get("ok", False) for v in done.values()), "bad": [k for k, v in done.items() if not v.get("ok")]}
