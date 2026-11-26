#!/usr/bin/env python3
"""Rebuild a presentation from an ARC Slide Log session and the deck file.

Usage: rebuild_show.py SESSION_DIR DECK.pptx OUT_DIR [--keys REPORT.txt]

Steps: render the deck's slides (LibreOffice -> PDF -> PNG), pull every proxy frame with its time, match each
frame to a slide, derive the cut list (slide, time), lay the rendered slides out on that timeline with the
proxy's sound, and write a timing report comparing cuts to the logged clicks (and to the keystroke report
from the drive script when given).
"""
import json, os, subprocess, sys, glob, re, datetime, shutil
import numpy as np
from PIL import Image

def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(cmd)}\n{r.stderr[-2000:]}")
    return r.stdout

def audio_lead_trim(path):
    """Seconds to drop from the front of a sound file so its first sample is the session's. AAC carries an
    encoder delay of 2112 samples; a cleanly closed file marks it and decoders drop it (ffprobe start_time > 0),
    the fragments a crash or a kill leaves do not (start_time 0), so every sample decodes 2112 late (measured:
    132 ms at 16 kHz). Opus marks its pre-skip in the header always."""
    out = run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name,sample_rate,start_time",
               "-of", "default=nw=1", path])
    info = dict(l.split("=", 1) for l in out.split() if "=" in l)
    if info.get("codec_name") == "aac" and abs(float(info.get("start_time") or 0)) < 0.001:
        return 2112 / float(info["sample_rate"])
    return 0.0

def render_slides(deck, out):
    pdfdir = os.path.join(out, "render"); os.makedirs(pdfdir, exist_ok=True)
    pdf = os.path.join(pdfdir, os.path.splitext(os.path.basename(deck))[0] + ".pdf")
    if not os.path.exists(pdf):
        run(["soffice", "--headless", "--convert-to", "pdf", "--outdir", pdfdir, deck])
    pngs = sorted(glob.glob(os.path.join(pdfdir, "slide-*.png")))
    if not pngs:
        run(["pdftoppm", "-r", "96", "-png", "-scale-to-x", "1920", "-scale-to-y", "-1", pdf, os.path.join(pdfdir, "slide")])
        pngs = sorted(glob.glob(os.path.join(pdfdir, "slide-*.png")))
    # Every slide on a 1920x1080 black canvas, as the show put it on the screen.
    for p in pngs:
        im = Image.open(p)
        if im.size != (1920, 1080):
            canvas = Image.new("RGB", (1920, 1080))
            im = im.convert("RGB"); im.thumbnail((1920, 1080))
            canvas.paste(im, ((1920 - im.width) // 2, (1080 - im.height) // 2)); canvas.save(p)
    return pngs

def proxy_frames(session, out, proxy):
    pts = [float(x) for x in run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "packet=pts_time",
                                  "-of", "csv=p=0", proxy]).split()]
    fdir = os.path.join(out, "proxy-frames"); os.makedirs(fdir, exist_ok=True)
    if len(glob.glob(os.path.join(fdir, "*.png"))) != len(pts):
        for f in glob.glob(os.path.join(fdir, "*.png")): os.remove(f)
        run(["ffmpeg", "-v", "error", "-y", "-i", proxy, "-vsync", "passthrough", os.path.join(fdir, "f-%04d.png")])
    frames = sorted(glob.glob(os.path.join(fdir, "f-*.png")))
    assert len(frames) == len(pts), f"{len(frames)} frames vs {len(pts)} packets"
    return list(zip(pts, frames))

def content_box(frames, slides):
    """Where the 16:9 show sits in the proxy: the display may be 16:10 (letterboxed) or 16:9 (full). Try both
    boxes on a spread of frames and keep the one the rendered slides match better."""
    S = [thumb(Image.open(p)) for p in slides]
    w, h = Image.open(frames[0][1]).size
    boxes = [(0, 0, w, h)]
    if h > w * 9 // 16 + 2:
        bh = w * 9 // 16; boxes.append((0, (h - bh) // 2, w, (h - bh) // 2 + bh))
    best = None
    for box in boxes:
        scores = []
        for pts, f in frames[::max(1, len(frames) // 40)]:
            t = thumb(Image.open(f), box)
            scores.append(max(float((t * s).sum()) for s in S))
        scores.sort()
        q = scores[len(scores) * 3 // 4]   # the better frames: the slides, not the desktop
        if best is None or q > best[0]: best = (q, box)
    return best[1]

def thumb(img, box=None, size=(96, 54)):
    if box: img = img.crop(box)
    a = np.asarray(img.convert("L").resize(size, Image.BILINEAR), dtype=np.float32)
    a -= a.mean(); n = np.linalg.norm(a)
    return a / n if n > 0 else a

def match(frames, slides, box):
    """Best slide per proxy frame. Decks repeat slides (this one has six identical title cards), so among slides
    within a hair of the top score the one nearest the previous match, forward first, wins."""
    S = [thumb(Image.open(p)) for p in slides]
    out = []; prev = 0
    for pts, f in frames:
        t = thumb(Image.open(f), box)
        scores = [float((t * s).sum()) for s in S]
        top = max(scores)
        cands = [i for i, sc in enumerate(scores) if sc >= top - 0.01]
        best = min(cands, key=lambda i: (0 if i >= prev else 1, abs(i - prev)))
        if scores[best] >= 0.55: prev = best
        out.append((pts, best, scores[best], f))
    return out

def main():
    args = sys.argv[1:]
    keys = None
    if "--keys" in args:
        i = args.index("--keys"); keys = args[i + 1]; del args[i:i + 2]
    session, deck, out = args[:3]
    os.makedirs(out, exist_ok=True)
    header = json.load(open(os.path.join(session, "header.json")))
    events = [json.loads(l) for l in open(os.path.join(session, "track.jsonl")) if l.strip()]
    proxy_start = header.get("proxy_start_mono", 0.0)
    clicks = [(e["t_mono"] - proxy_start, e) for e in events if e.get("kind") == "CLICK"]

    slides = render_slides(deck, out)
    proxy = os.path.join(session, header.get("proxy") or "proxy.mp4")
    frames = proxy_frames(session, out, proxy)
    # The show's box inside the display: taken from the frame most like a rendered slide, after the first few.
    box = content_box(frames, slides)
    matched = match(frames, slides, box)
    # A frame that matches no slide well (desktop, PowerPoint window, end screen) is "other".
    good = np.array([m[2] for m in matched]); thresh = max(0.55, float(np.median(good)) - 0.25)
    seq = []
    for pts, best, score, f in matched:
        slide = best if score >= thresh else None
        if seq and seq[-1]["slide"] == slide: seq[-1]["frames"] += 1; continue
        seq.append({"t": pts, "slide": slide, "score": score, "frames": 1})
    end = float(run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "packet=pts_time,duration_time", "-of", "csv=p=0", proxy]).split()[-1].split(",")[0]) + 0.1

    # The rebuild: rendered slides on the proxy's timeline, black where the show was not up, the proxy's sound.
    concat = os.path.join(out, "cuts.txt")
    black = os.path.join(out, "render", "black.png")
    if not os.path.exists(black): Image.new("RGB", (1920, 1080)).save(black)
    with open(concat, "w") as c:
        for i, s in enumerate(seq):
            nxt = seq[i + 1]["t"] if i + 1 < len(seq) else end
            c.write(f"file '{slides[s['slide']] if s['slide'] is not None else black}'\nduration {max(0.04, nxt - s['t']):.4f}\n")
        c.write(f"file '{slides[seq[-1]['slide']] if seq[-1]['slide'] is not None else black}'\n")
    audio = os.path.join(session, header.get("proxy_audio") or header.get("proxy") or "proxy.mp4")
    trim = audio_lead_trim(audio)
    rebuild = os.path.join(out, "rebuild.mp4")
    run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", concat] + (["-ss", f"{trim:.6f}"] if trim else []) + ["-i", audio,
         "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p", "-r", "25",
         "-c:a", "aac", "-b:a", "128k", "-shortest", rebuild])
    compare = os.path.join(out, "rebuild_vs_proxy.mp4")
    run(["ffmpeg", "-v", "error", "-y", "-i", proxy, "-i", rebuild,
         "-filter_complex", "[0:v]scale=960:-2,pad=960:600:0:(600-ih)/2:black[l];[1:v]scale=960:-2,pad=960:600:0:(600-ih)/2:black[r];[l][r]hstack[v]",
         "-map", "[v]", "-map", "1:a", "-c:v", "libx264", "-preset", "fast", "-crf", "22", "-pix_fmt", "yuv420p", "-r", "25", "-c:a", "copy", "-shortest", compare])

    # Report
    lines = []
    lines.append(f"REBUILD REPORT {datetime.datetime.now():%Y-%m-%d %H:%M}")
    lines.append(f"Session: {header.get('session')} on {header.get('machine')}, proxy {header.get('proxy_width')}x{header.get('proxy_height')}, {len(frames)} proxy frames over {end:.1f} s, proxy starts {proxy_start:.3f} s after the session")
    lines.append(f"Deck: {os.path.basename(deck)}, {len(slides)} slides rendered; show box in the proxy {box}")
    lines.append(f"Clicks on the track: {len(clicks)}; match threshold {thresh:.2f}")
    lines.append(f"Sound for the rebuild: {os.path.basename(audio)}{f', AAC delay of {trim * 1000:.0f} ms trimmed (file not closed cleanly)' if trim else ''}")
    lines.append("")
    lines.append("CUT LIST: every change of picture in the proxy, what was up, and the click that caused it")
    key_times = []
    if keys:
        sw = datetime.datetime.fromisoformat(header["start_wall"])
        raw = open(keys, 'rb').read()
        for l in raw.decode('utf-16' if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8').splitlines():
            m = re.match(r"sent (\d+) (\S+|\s) at (\d\d):(\d\d):(\d\d)\.(\d\d\d) slide (\d+) -> (-?\d+)", l.strip())
            if m:
                h, mi, s, ms = map(int, m.group(3, 4, 5, 6))
                t = datetime.datetime.combine(sw.date(), datetime.time(h, mi, s, ms * 1000), tzinfo=sw.tzinfo)
                key_times.append(((t - sw).total_seconds() - proxy_start, m.group(2), int(m.group(7)), int(m.group(8))))
    for s in seq:
        before = [c for c in clicks if c[0] <= s["t"] + 0.05]
        click = before[-1] if before else None
        ctext = f"click {click[1].get('note')} {s['t'] - click[0]:+.3f} s before" if click and s["t"] - click[0] < 3 else "no click within 3 s"
        lines.append(f"cut at {s['t']:.3f} s: {'slide ' + str(s['slide'] + 1) if s['slide'] is not None else 'not a slide (desktop, PowerPoint window or end screen)'}, match {s['score']:.2f}, {s['frames']} proxy frames until the next change, {ctext}")
    lines.append("")
    lines.append("CLICKS ON THE TRACK and the picture change that followed each")
    changes = [s["t"] for s in seq]
    for t, e in clicks:
        after = [c for c in changes if c >= t - 0.05]
        lines.append(f"click {e.get('note')} in {e.get('app') or 'unknown app'} at {t:.3f} s: {'picture changed at ' + format(after[0], '.3f') + ' s, ' + format((after[0] - t) * 1000, '.0f') + ' ms later' if after and after[0] - t < 3 else 'no picture change within 3 s'}")
    if key_times:
        lines.append("")
        lines.append("GROUND TRUTH: the drive script's own record of each keystroke (laptop clock, mapped through header.start_wall) against the track's clicks")
        for kt, key, b, a in key_times:
            near = min(clicks, key=lambda c: abs(c[0] - kt)) if clicks else None
            lines.append(f"sent {key.strip() or 'space'} at {kt:.3f} s (PowerPoint position {b} to {a}): {'track click at ' + format(near[0], '.3f') + ' s, ' + format((near[0] - kt) * 1000, '+.0f') + ' ms' if near and abs(near[0] - kt) < 2 else 'NOT FOUND on the track'}")
    lines.append("")
    lines.append(f"Outputs: {rebuild} (rendered slides on the proxy timeline with the proxy's sound), {compare} (proxy left, rebuild right, same clock)")
    rep = os.path.join(out, "REBUILD_REPORT.txt")
    open(rep, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))

if __name__ == "__main__":
    main()
