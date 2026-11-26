#!/usr/bin/env python3
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Click parity: PowerPoint versus ARC Presenter on the same clicks.

    tools/parity_test.py DECK.pptx DECK.arcdeck [--tag NAME] [--fps 4] [--skip-pp] [--skip-pr]

Measured mode. Both apps get the extended display in turn:
  1. PowerPoint pass: windowed show parked on the extended display, driven
     click by click by script (AppleScript `go to next slide` fires clicks),
     waiting for the screen to go quiet after each click; the screen is
     sampled at ~fps by region screenshot; every click is timestamped.
  2. Presenter pass: deck opened over the control API (localhost:8760),
     program output assigned to the same display, `/first`, then `/next` at
     the moment PowerPoint LEFT each slide (Presenter has no per-click
     builds yet, phase 7a/7b); sampled the same way; `/state` logged.
  3. Comparison per click, aligned on each slide's entry time in both
     passes: settled frame similarity, motion after the click in each app,
     verdict. Writes docs/parity/<tag>/parity.md, one paired image per click,
     and a side-by-side MP4 of the whole run.

Needs: PowerPoint, ARC Presenter (/Applications), a second display, ffmpeg,
Pillow + numpy, pdftoppm not required.
"""
import argparse, glob, json, os, re, shutil, subprocess, sys, threading, time, zipfile, urllib.request, urllib.parse
from PIL import Image
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.dirname(HERE)
PRESENTER = "http://localhost:8760"

# ----------------------------------------------------------------- helpers
def osa(script):
    r = subprocess.run(["osascript", "-e", "with timeout of 20 seconds\n" + script + "\nend timeout"], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError(r.stderr.strip()[:200])
    return r.stdout.strip()

def screens():
    out = subprocess.run(["swift", "-e", 'import AppKit; let m = NSScreen.screens[0].frame.height; for s in NSScreen.screens { print(s.localizedName, "|", Int(s.frame.minX), "|", Int(m - s.frame.maxY), "|", Int(s.frame.width), "|", Int(s.frame.height), "|", s.backingScaleFactor) }'],
                         capture_output=True, text=True, timeout=180).stdout
    rows = []
    for line in out.strip().splitlines():
        p = [x.strip() for x in line.split("|")]
        rows.append({"name": p[0], "x": int(p[1]), "y": int(p[2]), "w": int(p[3]), "h": int(p[4]), "scale": float(p[5])})
    return rows

def deck_facts(pptx):
    """clicks per slide, hidden, auto-advance seconds, looping, movie seconds (ffprobe)."""
    z = zipfile.ZipFile(pptx); names = z.namelist()
    nums = sorted(int(re.search(r"slide(\d+)\.xml$", n).group(1)) for n in names if re.match(r"ppt/slides/slide\d+\.xml$", n))
    durations = {}
    tmp = os.path.join("/tmp", "parity-media"); shutil.rmtree(tmp, ignore_errors=True); os.makedirs(tmp)
    for n in names:
        if n.startswith("ppt/media/") and n.rsplit(".", 1)[-1].lower() in ("mp4", "mov", "m4v", "avi", "wmv", "gif"):
            z.extract(n, tmp)
            r = subprocess.run(["ffprobe", "-v", "quiet", "-show_entries", "format=duration", "-of", "csv=p=0", os.path.join(tmp, n)], capture_output=True, text=True).stdout.strip()
            try: durations[n.split("/")[-1].lower()] = float(r)
            except ValueError: pass
    facts = {}
    for n in nums:
        x = z.read(f"ppt/slides/slide{n}.xml").decode("utf8", "ignore")
        rp = f"ppt/slides/_rels/slide{n}.xml.rels"; rels = z.read(rp).decode("utf8", "ignore") if rp in names else ""
        t = re.search(r"<p:timing>.*</p:timing>", x, re.S); tm = t.group(0) if t else ""
        main = tm.split('nodeType="mainSeq"')[1].split("</p:seq>")[0] if 'nodeType="mainSeq"' in tm else ""
        clicks = main.count('nodeType="clickEffect"')
        hidden = bool(re.search(r'<p:sld[^>]*\sshow="0"', x[:4000]))
        adv = re.search(r'<p:transition[^>]*\sadvTm="(\d+)"', x)
        loop = bool(re.search(r'<p:cMediaNode[^>]*>\s*<p:cTn[^>]*repeatCount="indefinite"', x))
        media = [m.lower() for m in re.findall(r'Target="[^"]*/media/([^"/]+)"', rels)]
        movie = max([durations.get(m, 0) for m in media] + [0])
        facts[n] = {"clicks": clicks, "hidden": hidden, "auto": float(adv.group(1)) / 1000 if adv else None, "loop": loop, "movie": movie}
    return facts

class Sampler(threading.Thread):
    """Region screenshots at ~fps into a dir; frames.json lists (t, file)."""
    def __init__(self, region, outdir, fps):
        super().__init__(daemon=True); self.region = region; self.outdir = outdir; self.period = 1.0 / fps; self.frames = []; self.stop_flag = False
        os.makedirs(outdir, exist_ok=True)
    def run(self):
        i = 0
        while not self.stop_flag:
            t0 = time.time(); f = os.path.join(self.outdir, f"f{i:06d}.jpg")
            subprocess.run(["screencapture", "-x", "-t", "jpg", "-R", self.region, f], capture_output=True)
            self.frames.append((t0, f)); i += 1
            d = self.period - (time.time() - t0)
            if d > 0: time.sleep(d)
    def stop(self):
        self.stop_flag = True; self.join(timeout=5); json.dump(self.frames, open(os.path.join(self.outdir, "frames.json"), "w"))
    def latest_fp(self):
        if not self.frames: return None
        try: return fingerprint(self.frames[-1][1])
        except Exception: return None

def fingerprint(path, crop=None):
    im = Image.open(path).convert("L")
    if crop: im = im.crop(crop)
    return np.asarray(im.resize((160, 90)), dtype=np.float32) / 255.0

def wait_quiet(sampler, quiet_s=1.0, max_s=30.0, crop=None):
    """Return seconds until the screen stopped changing (or max_s)."""
    t0 = time.time(); last = None; quiet_since = None
    while time.time() - t0 < max_s:
        time.sleep(0.25)
        if not sampler.frames: continue
        try: fp = fingerprint(sampler.frames[-1][1], crop)
        except Exception: continue
        if last is not None and float(np.abs(fp - last).mean()) < 0.003:
            if quiet_since is None: quiet_since = time.time()
            if time.time() - quiet_since >= quiet_s: return round(time.time() - t0, 2)
        else:
            quiet_since = None
        last = fp
    return round(time.time() - t0, 2)

# ------------------------------------------------------------ PowerPoint pass
def powerpoint_pass(pptx, facts, screen, outdir, fps):
    name = os.path.basename(pptx); stem = os.path.splitext(name)[0]
    osa(f'tell application "Microsoft PowerPoint"\nactivate\nopen POSIX file "{pptx}"\nend tell'); time.sleep(3)
    osa('tell application "Microsoft PowerPoint"\nset s to slide show settings of active presentation\nset show type of s to slide show type window\nset starting slide of s to 1\nset ending slide of s to (count slides of active presentation)\nrun slide show s\nend tell')
    for _ in range(40):
        try:
            if int(osa('tell application "Microsoft PowerPoint" to current show position of slide show view of slide show window 1')) > 0: break
        except Exception: pass
        time.sleep(0.25)
    # park the show window centred on the target display
    size = osa('tell application "System Events" to tell process "Microsoft PowerPoint" to get size of (first window whose name begins with "PowerPoint Slide Show")')
    w, h = [int(float(v)) for v in size.split(",")]
    x = screen["x"] + max(0, (screen["w"] - w) // 2); y = screen["y"] + max(0, (screen["h"] - h) // 2)
    osa(f'tell application "System Events" to tell process "Microsoft PowerPoint" to set position of (first window whose name begins with "PowerPoint Slide Show") to {{{x}, {y}}}')
    time.sleep(0.5)
    pos = osa('tell application "System Events" to tell process "Microsoft PowerPoint" to get position of (first window whose name begins with "PowerPoint Slide Show")')
    px, py = [int(float(v)) for v in pos.split(",")]
    title = 28
    region = f"{px},{py + title},{w},{h - title}"
    sampler = Sampler(region, os.path.join(outdir, "pp"), fps); sampler.start(); time.sleep(1.0)
    events = []   # {slide, click (0 = entry), t, kind}
    def position():
        try: return int(osa('tell application "Microsoft PowerPoint" to current show position of slide show view of slide show window 1'))
        except Exception: return 0
    slide = position(); t_entry = time.time(); events.append({"slide": slide, "click": 0, "t": t_entry, "kind": "entry", "settle": wait_quiet(sampler, 1.0, 10)})
    total = max(facts)
    while True:
        f = facts.get(slide, {"clicks": 0, "auto": None, "loop": False, "movie": 0})
        # builds / movie clicks on this slide
        for k in range(1, f["clicks"] + 1):
            osa('tell application "Microsoft PowerPoint" to go to next slide of slide show view of slide show window 1')
            t = time.time()
            cap = (f["movie"] + 3) if f["movie"] else 8
            if f["loop"] and f["movie"]: cap = f["movie"] + 2
            s = wait_quiet(sampler, 1.0, min(cap, 400))
            events.append({"slide": slide, "click": k, "t": t, "kind": "click", "settle": s})
            print(f"  PP slide {slide} click {k}: quiet after {s} s", flush=True)
        if f["auto"] is not None or (f["movie"] and f["clicks"] == 0):
            # movie on entry / automatic advance: wait it out
            cap = (f["movie"] + 3) if f["movie"] else 8
            if f["loop"]: cap = f["movie"] + 2
            s = wait_quiet(sampler, 1.0, min(cap, 400))
            events.append({"slide": slide, "click": 0, "t": time.time(), "kind": "wait", "settle": s})
        # leave the slide
        before = slide
        if f["auto"] is not None and position() != before:
            slide = position(); t = time.time(); kind = "auto"
        else:
            osa('tell application "Microsoft PowerPoint" to go to next slide of slide show view of slide show window 1'); t = time.time()
            for _ in range(30):
                p = position()
                if p != before and p != 0: break
                time.sleep(0.1)
            slide = p; kind = "advance"
        if slide == 0 or slide > total or slide == before:
            events.append({"slide": before, "click": 0, "t": t, "kind": "end"}); break
        s = wait_quiet(sampler, 1.0, 12)
        events.append({"slide": slide, "click": 0, "t": t, "kind": "entry", "from": before, "how": kind, "settle": s})
        print(f"  PP entered slide {slide} ({kind}), settled {s} s", flush=True)
    time.sleep(1); sampler.stop()
    try: osa('tell application "Microsoft PowerPoint"\nexit slide show slide show view of slide show window 1\nclose active presentation saving no\nend tell')
    except Exception as e: print("  PP close:", str(e)[:80])
    json.dump(events, open(os.path.join(outdir, "pp_events.json"), "w"), indent=1)
    json.dump({"region": region, "w": w, "h": h - title}, open(os.path.join(outdir, "pp_region.json"), "w"))
    return events

# ------------------------------------------------------------- Presenter pass
def api(method, route, **q):
    url = PRESENTER + route + ("?" + urllib.parse.urlencode(q) if q else "")
    req = urllib.request.Request(url, method=method)
    with urllib.request.urlopen(req, timeout=10) as r: return r.read().decode()

def presenter_pass(arcdeck, pp_events, screen, outdir, fps):
    if not subprocess.run(["pgrep", "-x", "ARC Presenter"], capture_output=True).stdout.strip():
        subprocess.run(["open", "-a", "ARC Presenter"]); time.sleep(6)
    for _ in range(30):
        try: api("GET", "/state"); break
        except Exception: time.sleep(1)
    disp = json.loads(api("GET", "/displays"))
    target = next((d for d in disp["displays"] if d["name"] == screen["name"]), None) or next((d for d in disp["displays"] if not d["builtIn"] and d["index"] != 1), None)
    api("POST", "/assign", program=target["name"] if target else "2")
    api("POST", "/outputs", open="1"); time.sleep(1.5)
    api("POST", "/open", path=os.path.abspath(arcdeck)); time.sleep(3)
    deck_name = os.path.splitext(os.path.basename(arcdeck.rstrip("/")))[0]
    # /open returns before the deck is listed (a reload swaps it in later):
    # find it in /state by name, retrying, then /select by 1-based index.
    idx = None
    for _ in range(20):
        decks = json.loads(api("GET", "/state")).get("decks", [])
        for i, d in enumerate(decks, 1):
            if d["name"].lower().startswith(deck_name.lower()): idx = i; break
        if idx: break
        time.sleep(0.5)
    if not idx: raise SystemExit(f"Presenter never listed {deck_name}: {decks}")
    api("POST", "/select", deck=str(idx)); time.sleep(0.5)      # needs Presenter with /select (2026-09-11)
    api("POST", "/take"); time.sleep(1); api("POST", "/first"); time.sleep(1.5)
    st = json.loads(api("GET", "/state")); print("  Presenter state:", st.get("liveDeck"), "slide", st.get("slide"), "/", st.get("totalSlides"), flush=True)
    region = f"{screen['x']},{screen['y']},{screen['w']},{screen['h']}"
    sampler = Sampler(region, os.path.join(outdir, "pr"), fps); sampler.start(); time.sleep(1.0)
    events = []; t0 = time.time()
    # Every PowerPoint click is replayed at the same offset: build clicks,
    # movie clicks and the click that leaves a slide (Presenter 2.5 plays
    # one segment per click from a manifest v2 deck). Slides PowerPoint left
    # by itself (auto-advance, movie end) get no click here either.
    clicks = [e for e in pp_events if e["kind"] in ("entry", "click")]; pp_t0 = clicks[0]["t"]
    events.append({"slide": clicks[0]["slide"], "click": 0, "t": time.time(), "kind": "entry", "state": st, "settle": wait_quiet(sampler, 1.0, 10)})
    for e in clicks[1:]:
        if e["kind"] == "entry" and e.get("how") == "auto": continue
        due = t0 + (e["t"] - pp_t0)
        while time.time() < due: time.sleep(0.05)
        api("POST", "/next"); t = time.time()
        s = wait_quiet(sampler, 1.0, 12)
        try: st = json.loads(api("GET", "/state"))
        except Exception: st = {}
        events.append({"slide": e["slide"], "click": e.get("click", 0), "t": t, "kind": e["kind"], "how": e.get("how"), "state": st, "settle": s})
        print(f"  Presenter {e['kind']} slide {e['slide']} click {e.get('click', 0)} (state slide {st.get('slide')} seg {st.get('segment')}), settled {s} s", flush=True)
    time.sleep(1); sampler.stop()
    try: api("POST", "/outputs", open="0")
    except Exception: pass
    json.dump(events, open(os.path.join(outdir, "pr_events.json"), "w"), indent=1)
    json.dump({"region": region, "w": screen["w"], "h": screen["h"]}, open(os.path.join(outdir, "pr_region.json"), "w"))
    return events

# ---------------------------------------------------------------- comparison
def frame_at(frames, t):
    best = None
    for ft, f in frames:
        if ft <= t: best = f
        else: break
    return best or (frames[0][1] if frames else None)

def content_crop(path):
    """Bounding box of the 16:9 content inside letterbox bars. Both apps
    show bars (PowerPoint's window is 1920x1094, Presenter letterboxes
    into 1920x1280); measured on a bright frame, then applied to all."""
    a = np.asarray(Image.open(path).convert("L"))
    rows = np.where(a.max(axis=1) > 24)[0]; cols = np.where(a.max(axis=0) > 24)[0]
    if len(rows) < 50 or len(cols) < 50: return None
    return (int(cols.min()), int(rows.min()), int(cols.max()) + 1, int(rows.max()) + 1)

def bright_frame(frames):
    """A frame with plenty of content, for measuring the letterbox."""
    best, score = None, -1
    for _, f in frames[:: max(1, len(frames) // 40)]:
        try: a = np.asarray(Image.open(f).convert("L").resize((64, 36)), dtype=np.float32)
        except Exception: continue
        sc = float((a > 24).mean())
        if sc > score: best, score = f, sc
    return best

def motion_window(frames, t_start, t_end, crop=None):
    """Seconds of visible change inside [t_start, t_end]."""
    prev = None; moving = 0.0; last_t = None
    for ft, f in frames:
        if ft < t_start or ft > t_end: continue
        try: fp = fingerprint(f, crop)
        except Exception: continue
        if prev is not None and float(np.abs(fp - prev).mean()) >= 0.004 and last_t is not None: moving += ft - last_t
        prev = fp; last_t = ft
    return round(moving, 2)

def compare(outdir, pp_events, pr_events, tag):
    ppf = json.load(open(os.path.join(outdir, "pp", "frames.json"))); prf = json.load(open(os.path.join(outdir, "pr", "frames.json")))
    pr_crop = content_crop(bright_frame(prf)) if prf else None
    pp_crop = content_crop(bright_frame(ppf)) if ppf else None
    pp_entries = {e["slide"]: e["t"] for e in pp_events if e["kind"] == "entry"}
    pr_entries = {e["slide"]: e["t"] for e in pr_events if e["kind"] == "entry"}
    pr_state = {e["slide"]: e.get("state", {}) for e in pr_events if e["kind"] == "entry"}
    rows = []; pairs_dir = os.path.join(outdir, "pairs"); os.makedirs(pairs_dir, exist_ok=True); n = 0
    # Presenter 2.5 replays every click, so a click row aligns on ITS replay
    # (slide, click); a run from an older Presenter (entries only) falls back
    # to the slide's entry plus PowerPoint's offset.
    pr_by = {(e["slide"], e.get("click", 0), e["kind"]): e for e in pr_events if e["kind"] in ("entry", "click")}
    for e in pp_events:
        if e["kind"] not in ("entry", "click"): continue
        s = e["slide"]
        if s not in pr_entries: continue
        off = e["t"] - pp_entries[s]; settle = e.get("settle", 1.0)
        replay = pr_by.get((s, e.get("click", 0), e["kind"]))
        t_pr0 = replay["t"] if replay else pr_entries[s] + off
        t_pp = e["t"] + settle + 0.3; t_pr = t_pr0 + settle + 0.3
        fpp = frame_at(ppf, t_pp); fpr = frame_at(prf, t_pr)
        if not fpp or not fpr: continue
        a = fingerprint(fpp, pp_crop); b = fingerprint(fpr, pr_crop)
        sim = 1.0 - float(np.abs(a - b).mean())
        m_pp = motion_window(ppf, e["t"], e["t"] + settle + 0.3, pp_crop)
        m_pr = motion_window(prf, t_pr0, t_pr0 + settle + 0.3, pr_crop)
        st = (replay or {}).get("state") or pr_state.get(s, {}); slide_ok = (st.get("slide") in (s, s - 1, None))   # Presenter pages skip hidden slides
        if e["kind"] == "click" and not replay:
            verdict = "NO CLICK IN PRESENTER (pre-segments)" if m_pp > 0.4 else "MATCH (instant build)"
            if sim < 0.90: verdict += ", STATE DIFFERS"
        else:
            verdict = "MATCH" if sim >= 0.90 else "STATE DIFFERS"
            if (m_pp > 0.4) != (m_pr > 0.4): verdict += ", MOTION IN ONE APP ONLY"
            elif m_pp > 0.4 and abs(m_pp - m_pr) > 2.0: verdict += ", TIMING OFF"
        n += 1
        # paired image
        A = Image.open(fpp).convert("RGB")
        if pp_crop: A = A.crop(pp_crop)
        A = A.resize((640, 360)); B = Image.open(fpr).convert("RGB")
        if pr_crop: B = B.crop(pr_crop)
        B = B.resize((640, 360)); pair = Image.new("RGB", (1300, 360), "black"); pair.paste(A, (0, 0)); pair.paste(B, (660, 0))
        pf = os.path.join(pairs_dir, f"{n:03d}_s{s:02d}_c{e['click']}.png"); pair.save(pf)
        rows.append({"n": n, "slide": s, "click": e["click"], "kind": e["kind"], "how": e.get("how", ""), "similarity": round(sim, 3),
                     "ppMotionS": m_pp, "prMotionS": m_pr, "prSlide": st.get("slide"), "verdict": verdict, "pair": os.path.relpath(pf, REPO)})
    md = [f"# Click parity: {tag}", "", f"PowerPoint pass: {len([e for e in pp_events if e['kind']=='click'])} clicks over {len(pp_entries)} slides. Presenter pass replayed every click (Presenter 2.5 segments; older runs replayed slide exits only).", "",
          "| # | Slide | Click | Similarity | PP motion s | Presenter motion s | Presenter slide | Verdict |", "|---|---|---|---|---|---|---|---|"]
    for r in rows:
        md.append(f"| {r['n']} | {r['slide']} | {r['click'] or ('entry ' + (r['how'] or ''))} | {r['similarity']:.3f} | {r['ppMotionS']} | {r['prMotionS']} | {r['prSlide']} | {r['verdict']} |")
    match = sum(r["verdict"].startswith("MATCH") for r in rows)
    md += ["", f"**{match} of {len(rows)} events MATCH.** Paired images in docs/parity/{tag}/pairs/.", ""]
    docs = os.path.join(REPO, "docs", "parity", tag); os.makedirs(docs, exist_ok=True)
    open(os.path.join(docs, "parity.md"), "w").write("\n".join(md)); json.dump(rows, open(os.path.join(docs, "parity.json"), "w"), indent=1)
    if os.path.isdir(pairs_dir) and not os.path.exists(os.path.join(docs, "pairs")): shutil.copytree(pairs_dir, os.path.join(docs, "pairs"))
    return rows, match

def side_by_side_video(outdir, pp_events, pr_events, tag, fps):
    """Whole run, PowerPoint left / Presenter right, aligned per slide entry."""
    ppf = json.load(open(os.path.join(outdir, "pp", "frames.json"))); prf = json.load(open(os.path.join(outdir, "pr", "frames.json")))
    pr_crop = content_crop(bright_frame(prf)) if prf else None
    pp_crop = content_crop(bright_frame(ppf)) if ppf else None
    pp_entries = [(e["slide"], e["t"]) for e in pp_events if e["kind"] == "entry"]; pr_entries = {e["slide"]: e["t"] for e in pr_events if e["kind"] == "entry"}
    seq_dir = os.path.join(outdir, "sbs"); shutil.rmtree(seq_dir, ignore_errors=True); os.makedirs(seq_dir); i = 0
    for idx, (s, t0) in enumerate(pp_entries):
        t1 = pp_entries[idx + 1][1] if idx + 1 < len(pp_entries) else ppf[-1][0]
        if s not in pr_entries: continue
        t = t0
        while t < t1:
            a = Image.open(frame_at(ppf, t)).convert("RGB")
            if pp_crop: a = a.crop(pp_crop)
            a = a.resize((960, 540)); b = Image.open(frame_at(prf, pr_entries[s] + (t - t0))).convert("RGB")
            if pr_crop: b = b.crop(pr_crop)
            b = b.resize((960, 540)); out = Image.new("RGB", (1930, 560), "black"); out.paste(a, (0, 20)); out.paste(b, (970, 20))
            out.save(os.path.join(seq_dir, f"{i:06d}.jpg"), quality=85); i += 1; t += 1.0 / fps
    mp4 = os.path.join(REPO, "docs", "parity", tag, f"side_by_side_{tag}.mp4")
    subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-framerate", str(fps), "-i", os.path.join(seq_dir, "%06d.jpg"), "-c:v", "libx264", "-pix_fmt", "yuv420p", mp4], check=False)
    return mp4

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("pptx"); ap.add_argument("arcdeck"); ap.add_argument("--tag", default=time.strftime("parity_%Y-%m-%d_%H%M"))
    ap.add_argument("--fps", type=float, default=4); ap.add_argument("--skip-pp", action="store_true"); ap.add_argument("--skip-pr", action="store_true")
    ap.add_argument("--work", default=os.path.expanduser("/Volumes/DRIVE/ARC Test Media/ARC Capture Suite/parity"))
    a = ap.parse_args()
    outdir = os.path.join(a.work, a.tag); os.makedirs(outdir, exist_ok=True)
    scr = screens(); ext = next((s for s in scr if s is not scr[0]), None)
    if not ext: sys.exit("needs a second display")
    print(f"target display: {ext['name']} {ext['w']}x{ext['h']} at {ext['x']},{ext['y']}", flush=True)
    facts = deck_facts(os.path.abspath(a.pptx)); print(f"deck: {len(facts)} slides, {sum(f['clicks'] for f in facts.values())} clicks, movies on {[n for n,f in facts.items() if f['movie']]}", flush=True)
    if a.skip_pp: pp = json.load(open(os.path.join(outdir, "pp_events.json")))
    else: print("== PowerPoint pass", flush=True); pp = powerpoint_pass(os.path.abspath(a.pptx), facts, ext, outdir, a.fps)
    if a.skip_pr: pr = json.load(open(os.path.join(outdir, "pr_events.json")))
    else: print("== Presenter pass", flush=True); pr = presenter_pass(a.arcdeck, pp, ext, outdir, a.fps)
    print("== comparing", flush=True); rows, match = compare(outdir, pp, pr, a.tag)
    mp4 = side_by_side_video(outdir, pp, pr, a.tag, a.fps)
    print(f"== {match}/{len(rows)} events MATCH; report docs/parity/{a.tag}/parity.md; video {os.path.relpath(mp4, REPO)}", flush=True)

if __name__ == "__main__":
    main()
