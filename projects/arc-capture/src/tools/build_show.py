#!/usr/bin/env python3
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Build ONE combined .arcdeck from a show folder.

    tools/build_show.py FOLDER [--out DECK.arcdeck] [--app PATH] [--timeout S] [--force]

Items are taken in filename order (the deck intake's N.NN naming sorts
naturally), unless FOLDER/show.json exists: then its "items" list gives the
order and the paths (which may live anywhere), and its "name" the deck name.
That file is what ARC Capture's SHOW tab saves. Per item:
  .pptx/.ppt   captured by ARC Capture headless (manifest v2: click marks,
               entry clips, loops, stopAt); cached under FOLDER/.arcbuild/
               and reused while the .pptx is unchanged
  .pdf         every page becomes a still slide
  .png/.jpg    one still slide, fitted on a 16:9 black canvas
  .mp4/.mov    one video slide (poster = first frame), plays on entry
  .webloc      a Google Slides link (drag the URL from Chrome into the folder):
               captured by ARC Capture's Google Slides driver, cached like a .pptx
  .key         a Keynote deck, captured by the Keynote driver
  .arcdeck     an already captured deck, merged as-is (no recapture)
The result is slides.pdf + media/ + manifest.json (version 2) with a
"source" on every slide, plus build_report.json.
"""
import argparse, json, os, re, shutil, subprocess, sys, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_APP = os.path.join(REPO, "build/Build/Products/Release/ARC Capture.app/Contents/MacOS/ARC Capture")
DECK_EXT = (".pptx", ".ppt", ".key"); PDF_EXT = (".pdf",); IMG_EXT = (".png", ".jpg", ".jpeg", ".heic", ".tif", ".tiff")
LINK_EXT = (".webloc", ".url"); ARC_EXT = (".arcdeck",)
VID_EXT = (".mp4", ".mov", ".m4v")

def natural_key(s):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]

def link_url(path):
    """URL inside a .webloc (plist) or Windows .url file."""
    if path.lower().endswith(".webloc"):
        import plistlib
        try: return plistlib.load(open(path, "rb")).get("URL")
        except Exception:
            out = subprocess.run(["plutil", "-convert", "xml1", "-o", "-", path], capture_output=True, text=True).stdout
            m = re.search(r"<string>(https?://[^<]+)</string>", out); return m.group(1) if m else None
    for line in open(path, errors="ignore"):
        if line.startswith("URL="): return line.strip()[4:]
    return None

def capture(app, pptx, work, timeout, force, watch=False):
    name = os.path.splitext(os.path.basename(pptx))[0]
    source = link_url(pptx) if pptx.lower().endswith(LINK_EXT) else pptx
    if source is None:
        return None, {"ok": False, "error": "no URL in link file"}
    out_dir = os.path.join(work, name); deck = os.path.join(out_dir, name + ".arcdeck")
    report = os.path.join(out_dir, "report.json")
    if not force and os.path.isdir(deck) and os.path.exists(report) and os.path.getmtime(report) >= os.path.getmtime(pptx):
        print(f"  reuse  {name} (captured {time.strftime('%H:%M', time.localtime(os.path.getmtime(report)))})", flush=True)
        return deck, json.load(open(report))
    shutil.rmtree(out_dir, ignore_errors=True); os.makedirs(out_dir)
    print(f"  capture {name} ...", flush=True); t0 = time.time()
    subprocess.run([app, "--watch" if watch else "--headless", "--in", source, "--out", out_dir, "--report", report, "--timeout", str(timeout)],
                   stdout=open(os.path.join(out_dir, "run.log"), "w"), stderr=subprocess.STDOUT, timeout=timeout + 120)
    rep = json.load(open(report)) if os.path.exists(report) else {"ok": False, "error": "no report"}
    print(f"          {'ok' if rep.get('ok') else 'FAILED ' + str(rep.get('error'))} in {time.time() - t0:.0f} s, {len(rep.get('slides', []))} slides", flush=True)
    return (deck if rep.get("ok") else None), rep

def pptx_notes(pptx):
    """1-based slide number -> speaker notes text (body placeholder only)."""
    import zipfile, xml.etree.ElementTree as ET
    A = "{http://schemas.openxmlformats.org/drawingml/2006/main}"; P = "{http://schemas.openxmlformats.org/presentationml/2006/main}"
    R = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
    PR = "{http://schemas.openxmlformats.org/package/2006/relationships}"
    notes = {}
    try:
        z = zipfile.ZipFile(pptx)
        pres = ET.fromstring(z.read("ppt/presentation.xml"))
        prels = ET.fromstring(z.read("ppt/_rels/presentation.xml.rels"))
        rid_target = {r.get("Id"): r.get("Target") for r in prels.findall(PR + "Relationship")}
        order = [rid_target[s.get(R + "id")] for s in pres.iter(P + "sldId")]
        for n, target in enumerate(order, 1):
            slide = target.split("/")[-1]
            rels_path = f"ppt/slides/_rels/{slide}.rels"
            if rels_path not in z.namelist(): continue
            srels = ET.fromstring(z.read(rels_path))
            ns = [r.get("Target") for r in srels.findall(PR + "Relationship") if "notesSlide" in r.get("Type", "")]
            if not ns: continue
            npath = "ppt/notesSlides/" + ns[0].split("/")[-1]
            if npath not in z.namelist(): continue
            root = ET.fromstring(z.read(npath))
            paras = []
            for sp in root.iter(P + "sp"):
                ph = sp.find(f".//{P}nvPr/{P}ph")
                if ph is None or ph.get("type") != "body": continue
                for para in sp.iter(A + "p"):
                    t = "".join(x.text or "" for x in para.iter(A + "t")).strip()
                    if t: paras.append(t)
            text = "\n".join(paras).strip()
            if text: notes[n] = text
    except Exception as e:
        print(f"  notes: {os.path.basename(pptx)}: {e}", flush=True)
    return notes

def probe_codecs(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type,codec_name", "-of", "json", path],
                         capture_output=True, text=True).stdout
    streams = json.loads(out or "{}").get("streams", [])
    v = [st.get("codec_name") for st in streams if st.get("codec_type") == "video" and st.get("codec_name") != "mjpeg"]
    a = [st.get("codec_name") for st in streams if st.get("codec_type") == "audio"]
    return (v[0] if v else None), (a[0] if a else None)

def transcode_if_needed(src, dst_mov):
    """Presenter plays H.264 + AAC in .mov/.mp4 reliably; anything else
    (HEVC, ProRes, odd audio) goes through VideoToolbox once."""
    v, a = probe_codecs(src)
    ext = os.path.splitext(src)[1].lower()
    if v == "h264" and (a in (None, "aac")) and ext in (".mov", ".mp4", ".m4v"):
        shutil.copy2(src, dst_mov); return "copied"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-map", "0:v:0", "-map", "0:a?", "-c:v", "h264_videotoolbox", "-b:v", "16M",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", dst_mov], check=True)
    return f"transcoded from {v}/{a}"

def hand_back(deck):
    """Open the finished deck in ARC Presenter (preview, not live) when it is running."""
    import urllib.request, urllib.parse
    try:
        # quote, not urlencode: Presenter reads "+" literally, so a deck name with spaces never opened.
        req = urllib.request.Request("http://localhost:8760/open?path=" + urllib.parse.quote(deck), method="POST")
        urllib.request.urlopen(req, timeout=20).read()
        return True
    except Exception:
        return False

def first_frame(video, png):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "0.2", "-i", video, "-frames:v", "1", "-vf", "scale=1920:-2", png], check=False)
    return os.path.exists(png)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder"); ap.add_argument("--out"); ap.add_argument("--app", default=DEFAULT_APP)
    ap.add_argument("--timeout", type=int, default=3600); ap.add_argument("--force", action="store_true")
    ap.add_argument("--no-open", action="store_true", help="do not hand the deck to ARC Presenter")
    ap.add_argument("--watch", action="store_true", help="show the capture monitor window for each PowerPoint deck")
    a = ap.parse_args()
    import fitz  # PyMuPDF
    folder = os.path.abspath(a.folder.rstrip("/")); show = os.path.basename(folder)
    out = os.path.abspath(a.out) if a.out else os.path.join(folder, show + ".arcdeck")
    work = os.path.join(folder, ".arcbuild"); os.makedirs(work, exist_ok=True)
    show_json = os.path.join(folder, "show.json")
    if os.path.exists(show_json):
        spec = json.load(open(show_json))
        show = spec.get("name") or show
        if not a.out: out = os.path.join(folder, show + ".arcdeck")
        paths = [i["path"] if isinstance(i, dict) else i for i in spec.get("items", [])]
        paths = [p if os.path.isabs(p) else os.path.join(folder, p) for p in paths]
        items = [p for p in paths if os.path.exists(p)]
        missing = [p for p in paths if not os.path.exists(p)]
        if missing: print("  missing items skipped:", [os.path.basename(m) for m in missing])
    else:
        items = [os.path.join(folder, f) for f in sorted(os.listdir(folder), key=natural_key)
                 if not f.startswith(".") and not f.startswith("~$")
                 and (os.path.isfile(os.path.join(folder, f)) or f.lower().endswith((".key",) + ARC_EXT))
                 and f.lower().endswith(DECK_EXT + PDF_EXT + IMG_EXT + VID_EXT + LINK_EXT + ARC_EXT)
                 and not f.startswith(show + ".arcdeck")]
    print(f"show {show}: {len(items)} item(s)")
    doc = fitz.open(); entries = []; media_src = []; report = {"show": show, "items": []}
    tmp_out = out + ".building"; shutil.rmtree(tmp_out, ignore_errors=True); os.makedirs(os.path.join(tmp_out, "media"))
    def add_page_from_image(png):
        page = doc.new_page(width=1920, height=1080)
        page.draw_rect(page.rect, color=None, fill=(0, 0, 0))
        page.insert_image(page.rect, filename=png, keep_proportion=True)
    for path in items:
        f = os.path.basename(path.rstrip("/")); low = f.lower(); n0 = len(entries)
        if low.endswith(ARC_EXT):
            # Already captured: merge as-is (pages, clips, notes, click marks).
            deck = path
            man = json.load(open(os.path.join(deck, "manifest.json")))
            src = fitz.open(os.path.join(deck, "slides.pdf")); doc.insert_pdf(src); src.close()
            notes_here = {}
            try: notes_here = json.load(open(os.path.join(deck, "notes.json")))
            except Exception: pass
            for k, e in enumerate(man["slides"], 1):
                e = dict(e); e["source"] = f
                if str(k) in notes_here: e["_note"] = notes_here[str(k)]
                for key in ("file", "entryFile"):
                    if e.get(key): media_src.append((os.path.join(deck, e[key]), key, len(entries)))
                entries.append(e)
            report["items"].append({"file": f, "status": "merged", "slides": len(man["slides"])})
        elif low.endswith(DECK_EXT + LINK_EXT):
            deck, rep = capture(a.app, path, work, a.timeout, a.force, a.watch)
            if not deck:
                report["items"].append({"file": f, "status": "FAILED", "error": rep.get("error")}); continue
            man = json.load(open(os.path.join(deck, "manifest.json")))
            src = fitz.open(os.path.join(deck, "slides.pdf")); doc.insert_pdf(src); src.close()
            src_notes = pptx_notes(path) if low.endswith((".pptx", ".ppt")) else {}
            for e in man["slides"]:
                e = dict(e); e["source"] = f
                if e.get("pptxSlide") in src_notes: e["_note"] = src_notes[e["pptxSlide"]]
                for key in ("file", "entryFile"):
                    if e.get(key):
                        media_src.append((os.path.join(deck, e[key]), key, len(entries)))
                entries.append(e)
            report["items"].append({"file": f, "status": "captured", "slides": len(man["slides"]), "notes": len(src_notes), "warnings": rep.get("warnings", [])})
        elif low.endswith(PDF_EXT):
            src = fitz.open(path); doc.insert_pdf(src); n = src.page_count; src.close()
            for i in range(n): entries.append({"type": "image", "source": f, "sourcePage": i + 1})
            report["items"].append({"file": f, "status": "pages", "slides": n})
        elif low.endswith(IMG_EXT):
            add_page_from_image(path); entries.append({"type": "image", "source": f})
            report["items"].append({"file": f, "status": "still", "slides": 1})
        elif low.endswith(VID_EXT):
            poster = os.path.join(work, os.path.splitext(f)[0] + "_poster.png")
            if first_frame(path, poster): add_page_from_image(poster)
            else: doc.new_page(width=1920, height=1080)
            media_src.append((path, "file", len(entries)))
            entries.append({"type": "video", "source": f})
            report["items"].append({"file": f, "status": "video", "slides": 1})
        print(f"  + {f}: slides {n0 + 1}..{len(entries)}", flush=True)
    # renumber and copy media
    for i, e in enumerate(entries, 1):
        e["slide"] = i
        for key in ("file", "entryFile"): e.pop(key, None)
    for src, key, idx in media_src:
        i = idx + 1
        rel = f"media/slide_{i:03d}{'_in' if key == 'entryFile' else ''}.mov"
        if entries[idx].get("source", "").lower().endswith(VID_EXT) and key == "file":
            how = transcode_if_needed(src, os.path.join(tmp_out, rel))
            print(f"  media {entries[idx]['source']}: {how}", flush=True)
        else:
            shutil.copy2(src, os.path.join(tmp_out, rel))
        entries[idx][key] = rel
    notes = {str(i + 1): e.pop("_note") for i, e in enumerate(entries) if e.get("_note")}
    if notes: json.dump(notes, open(os.path.join(tmp_out, "notes.json"), "w"), indent=1, ensure_ascii=False)
    doc.save(os.path.join(tmp_out, "slides.pdf")); doc.close()
    json.dump({"version": 2, "show": show, "slides": entries}, open(os.path.join(tmp_out, "manifest.json"), "w"), indent=1, sort_keys=True)
    report["slides"] = len(entries); report["video"] = sum(1 for e in entries if e.get("type") == "video"); report["notes"] = len(notes)
    json.dump(report, open(os.path.join(tmp_out, "build_report.json"), "w"), indent=1)
    shutil.rmtree(out, ignore_errors=True); os.rename(tmp_out, out)
    print(f"wrote {out}: {len(entries)} slides, {report['video']} video, {len(notes)} slide(s) with notes")
    if not a.no_open:
        print("  handed to ARC Presenter" if hand_back(out) else "  ARC Presenter not running; open the deck by hand")
    return 0

if __name__ == "__main__": sys.exit(main())
