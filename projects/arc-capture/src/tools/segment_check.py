#!/usr/bin/env python3
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Walk an arcdeck in ARC Presenter over the control API, one /next per click,
and print slide, segment and clip position after each: the measured record of
per-click playback (manifest v2). Usage: segment_check.py DECK.arcdeck [--max N]"""
import json, os, sys, time, urllib.parse, urllib.request

API = "http://localhost:8760"
def api(method, route, **q):
    url = API + route + ("?" + urllib.parse.urlencode(q) if q else "")
    req = urllib.request.Request(url, method=method)
    with urllib.request.urlopen(req, timeout=20) as r: return r.read().decode()

def state(): return json.loads(api("GET", "/state"))

def main():
    deck = os.path.abspath(sys.argv[1]); mx = int(sys.argv[sys.argv.index("--max") + 1]) if "--max" in sys.argv else 400
    name = os.path.splitext(os.path.basename(deck.rstrip("/")))[0]
    api("POST", "/open", path=deck); time.sleep(2)
    idx = None
    for _ in range(20):
        decks = state().get("decks", [])
        cands = [i for i, d in enumerate(decks, 1) if d["name"].lower().startswith(name.lower())]
        if cands: idx = cands[-1]; break       # newest same-name deck is the one just opened
        time.sleep(0.5)
    if not idx: raise SystemExit("deck not listed")
    api("POST", "/select", deck=str(idx)); time.sleep(0.3); api("POST", "/take"); time.sleep(0.5)
    api("POST", "/close", deck="others"); api("POST", "/first"); time.sleep(1.5)
    man = json.load(open(os.path.join(deck, "manifest.json")))
    print("manifest version", man.get("version"))
    st = state(); print(f"start: slide {st['slide']}/{st['totalSlides']} seg {st.get('segment')}/{st.get('segments')}")
    rows = []
    for n in range(1, mx + 1):
        before = state()
        api("POST", "/next"); t = time.time(); time.sleep(1.5)
        st = state(); clip = st.get("clip") or {}
        row = {"click": n, "from": before["slide"], "slide": st["slide"], "segment": st.get("segment"), "segments": st.get("segments"),
               "clipTime": clip.get("time"), "rate": clip.get("rate"), "loop": clip.get("loop")}
        rows.append(row)
        kind = "SEGMENT" if st["slide"] == before["slide"] else "ADVANCE"
        print(f"click {n:3d}: {kind} slide {before['slide']}->{st['slide']} seg {st.get('segment')}/{st.get('segments')} clip t={clip.get('time')} rate={clip.get('rate')}", flush=True)
        if st["slide"] >= st["totalSlides"] and (st.get("segments") or 0) <= (st.get("segment") or 0): break
    out = os.path.join(os.path.dirname(deck), "segment_check.json"); json.dump(rows, open(out, "w"), indent=1)
    print("wrote", out)

if __name__ == "__main__": main()
