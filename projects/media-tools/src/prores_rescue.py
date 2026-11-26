"""Rebuild a ProRes .mov whose QuickTime wrapper is gone (no ftyp/mdat header, no moov index, head and tail cut).

What is left in such a file is the raw interleave a ProRes writer leaves in mdat:
    [ProRes frame]*30  [PCM audio chunk]  [ProRes frame]*30  [PCM audio chunk] ...
Each ProRes frame starts with a 4-byte big-endian size and 'icpf', so the frames can be walked exactly. Everything that is
not a frame is an audio chunk. Measured on a set of interview recordings (two cameras, 2026-10-04):
  - 1080p59.94: each audio chunk carries 30 frames' worth = 24,024 samples at 48 kHz (1001 * 24)
  - PCM 24-bit little-endian, 4 channels (chunk 288,768 B) or 2 channels (144,384 B); a chunk holds 24,064 samples, the
    last 40 are a copy of the NEXT chunk's first 40 (writer look-ahead), so only the first 24,024 are kept
  - the file starts inside a frame and ends inside a frame: both partial frames are dropped

Output keeps every intact frame (no re-encode): a video-only .mov is written with a fresh index, the audio is written to a
.wav, then ffmpeg muxes both (-c copy) into the final .mov. Which 30 frames an audio chunk belongs to (the ones after it or
before it) is a parameter: `--audio-order lead|follow`. Measured 10/4 on 2-minute test builds of one interview clip (mouth-region
motion from Haar faces vs the voice envelope, 6,884 frames with a face): lead peaks at -7 frames (lips move ~0.12 s before
the sound, normal speech), follow at +23 (lips 0.38 s AFTER the sound: impossible). Default = lead. Re-measure for footage
from another writer (--minutes N makes a short test build).

AJA layout (--layout aja, measured 2026-10-06 on one archived interview file, frames tagged 'aja1',
1920x1080, a constant 671,744 B per frame): audio chunks are 3,932,160 B = 16 PLANAR slots x 81,920 samples x 24-bit LE
(only the first 4 slots carry audio, the rest are zeros); 81,920 samples = 1.7067 s = 102.29 frames at 59.94, so chunks
fall every 100 or 104 frames and do not line up with groups of frames. Proof: 4 planes join chunk to chunk within a normal
sample step (2 planes jump 3-7x), and each plane boundary inside a chunk jumps 15-55x. The audio is written as one stream
starting at the first chunk; frames before it are dropped (lead), or kept with the chunk covering the frames before it
(follow).

Run:  python3 prores_rescue.py SRC.mov OUT_DIR [--layout ninja|aja] [--audio-order lead|follow] [--fps 60000/1001] [--fourcc apch] [--minutes N]
The source file is only read, never written.
"""
from __future__ import annotations
import argparse, json, os, shutil, struct, subprocess, sys, wave
from pathlib import Path
import numpy as np

SPC = 24024                  # audio samples per 30-frame chunk at 59.94 (48 kHz)
FRAMES_PER_CHUNK = 30
AJA_SLOTS = 16               # AJA: planar slots per audio chunk (24-bit LE each)


def walk(src: str) -> dict:
    """Return {'video': [(off, size)], 'audio': [(off, size)], 'order': ['v'|'a', ...]} for the intact elements."""
    sz = os.path.getsize(src); V, A, order = [], [], []
    with open(src, "rb") as h:
        first = h.read(4 << 20).find(b"icpf") - 4
        if first < 0:
            raise SystemExit(f"{src}: no ProRes frame in the first 4 MB")
        pos = first
        while pos + 8 <= sz:
            h.seek(pos); fs, tag = struct.unpack(">I4s", h.read(8))
            if tag == b"icpf" and 8 < fs < 8_000_000:
                if pos + fs > sz:
                    break                                          # the tail frame is cut: drop it
                V.append((pos, fs)); order.append("v"); pos += fs; continue
            h.seek(pos); blk = h.read(16 << 20); k = blk.find(b"icpf", 4)
            if k == -1:
                break                                              # a cut audio chunk at the end: drop it
            A.append((pos, k - 4)); order.append("a"); pos += k - 4
    return {"video": V, "audio": A, "order": order, "lead_bytes": first, "size": sz}


def plan(w: dict, audio_order: str) -> dict:
    """Pick the frames and chunks that line up. Start on the first frame after the first audio chunk (the group before it
    is missing its head or its audio). lead: chunk j covers the 30 frames after it; follow: the 30 frames before it."""
    order = w["order"]; ia = order.index("a")
    v_start = order[:ia].count("v")                               # frames before the first chunk are dropped
    a_first = 0 if audio_order == "lead" else 1
    chunks = w["audio"][a_first:]
    frames = w["video"][v_start:]
    n_groups = min(len(chunks), len(frames) // FRAMES_PER_CHUNK)
    return {"frames": frames[: n_groups * FRAMES_PER_CHUNK], "chunks": chunks[:n_groups], "dropped_head_frames": v_start}


# ---- QuickTime writer (video only) ----------------------------------------------------------------------------------
def atom(t: bytes, *body: bytes) -> bytes:
    b = b"".join(body); return struct.pack(">I4s", 8 + len(b), t) + b


def full(t: bytes, ver: int, flags: int, *body: bytes) -> bytes:
    return atom(t, struct.pack(">I", (ver << 24) | flags), *body)


def moov_video(sizes: list[int], offsets: list[int], w: int, h: int, ts: int, dur: int, fourcc: bytes, name: str) -> bytes:
    n = len(sizes); total = n * dur
    mat = struct.pack(">9I", 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000)
    mvhd = full(b"mvhd", 0, 0, struct.pack(">IIII", 0, 0, ts, total), struct.pack(">IH", 0x10000, 0x100), b"\0" * 10, mat,
                b"\0" * 24, struct.pack(">I", 2))
    tkhd = full(b"tkhd", 0, 0xF, struct.pack(">IIIII", 0, 0, 1, 0, total), b"\0" * 8, struct.pack(">hhhH", 0, 0, 0, 0), mat,
                struct.pack(">II", w << 16, h << 16))
    mdhd = full(b"mdhd", 0, 0, struct.pack(">IIII", 0, 0, ts, total), struct.pack(">HH", 0, 0))
    hdlr = full(b"hdlr", 0, 0, b"mhlr", b"vide", b"appl", b"\0" * 8, bytes([len(name)]) + name.encode())
    vmhd = full(b"vmhd", 0, 1, struct.pack(">H3H", 0x40, 0x8000, 0x8000, 0x8000))
    dhlr = full(b"hdlr", 0, 0, b"dhlr", b"alis", b"appl", b"\0" * 8, b"\0")
    dinf = atom(b"dinf", full(b"dref", 0, 0, struct.pack(">I", 1), full(b"alis", 0, 1)))
    cname = b"Apple ProRes 422 HQ"[:31]
    entry = (b"\0" * 6 + struct.pack(">H", 1) + struct.pack(">HH4sII", 0, 0, b"appl", 0, 0x200) + struct.pack(">HH", w, h)
             + struct.pack(">II", 72 << 16, 72 << 16) + struct.pack(">IH", 0, 1) + bytes([len(cname)]) + cname.ljust(31, b"\0")
             + struct.pack(">hh", 24, -1)
             + atom(b"colr", b"nclc", struct.pack(">HHH", 1, 1, 1)) + atom(b"fiel", bytes([1, 0])) + struct.pack(">I", 0))
    stsd = full(b"stsd", 0, 0, struct.pack(">I", 1), struct.pack(">I4s", 8 + len(entry), fourcc) + entry)
    stts = full(b"stts", 0, 0, struct.pack(">III", 1, n, dur))
    stsc = full(b"stsc", 0, 0, struct.pack(">IIII", 1, 1, 1, 1))
    stsz = full(b"stsz", 0, 0, struct.pack(">II", 0, n), struct.pack(f">{n}I", *sizes))
    co64 = full(b"co64", 0, 0, struct.pack(">I", n), struct.pack(f">{n}Q", *offsets))
    stbl = atom(b"stbl", stsd, stts, stsc, stsz, co64)
    trak = atom(b"trak", tkhd, atom(b"mdia", mdhd, hdlr, atom(b"minf", vmhd, dhlr, dinf, stbl)))
    return atom(b"moov", mvhd, trak)


def frame_wh(src: str, off: int) -> tuple[int, int]:
    with open(src, "rb") as h:
        h.seek(off); b = h.read(20)
    return struct.unpack(">HH", b[16:20])


def write_video(src: str, frames: list, out: Path, fps: tuple[int, int], fourcc: bytes) -> None:
    w, h = frame_wh(src, frames[0][0]); ts, dur = fps
    ftyp = atom(b"ftyp", b"qt  ", struct.pack(">I", 0x20050300), b"qt  ")
    data = sum(s for _, s in frames)
    with open(src, "rb") as fi, open(out, "wb") as fo:
        fo.write(ftyp); fo.write(struct.pack(">I4sQ", 1, b"mdat", 16 + data))
        offs, cur = [], len(ftyp) + 16
        for off, s in frames:
            fi.seek(off); buf = fi.read(s)
            if len(buf) != s or buf[4:8] != b"icpf":
                raise SystemExit(f"frame read failed at {off}")
            fo.write(buf); offs.append(cur); cur += s
        fo.write(moov_video([s for _, s in frames], offs, w, h, ts, dur, fourcc, "ProRes rescued"))


def plan_aja(w: dict, audio_order: str, fps: float = 60000 / 1001) -> dict:
    """AJA: audio is one continuous stream of planar chunks. follow (measured 10/6, the default for AJA): chunk k holds
    the sound of the ~102 frames written BEFORE it, so the stream starts chunk_frames before the first chunk's position;
    lead (wrong for this writer: audio 1.8-2.0 s late at 3 points, audibly out of sync): it starts there."""
    order = w["order"]; ia = order.index("a"); before = order[:ia].count("v")
    n = w["audio"][0][1] // (AJA_SLOTS * 3); chunk_frames = n / 48000 * fps
    start = before if audio_order == "lead" else before - chunk_frames   # video frame where audio sample 0 plays
    v_start = max(0, int(np.ceil(start))) if start > 0 else 0
    skip = round((v_start - start) / fps * 48000)                         # audio samples before frame v_start
    return {"frames": w["video"][v_start:], "chunks": w["audio"], "dropped_head_frames": v_start, "audio_skip": skip}


def write_audio_aja(src: str, chunks: list, out: Path, max_samples: int | None = None, skip: int = 0) -> int:
    size = chunks[0][1]; n = size // (AJA_SLOTS * 3)
    if n * AJA_SLOTS * 3 != size:
        raise SystemExit(f"AJA audio chunk {size} B is not {AJA_SLOTS} planar 24-bit slots")
    with open(src, "rb") as fi:
        fi.seek(chunks[len(chunks) // 2][0]); b = fi.read(size)
    ch = sum(1 for k in range(AJA_SLOTS) if any(b[k * n * 3:(k + 1) * n * 3]))   # active slots (the rest are zeros)
    import numpy as np
    done = 0
    with open(src, "rb") as fi, wave.open(str(out), "wb") as wv:
        wv.setnchannels(ch); wv.setsampwidth(3); wv.setframerate(48000)
        for off, s in chunks:
            if s != size:
                raise SystemExit(f"odd AJA audio chunk size {s} at {off}")
            fi.seek(off); planes = np.frombuffer(fi.read(ch * n * 3), np.uint8).reshape(ch, n, 3)
            k = min(skip, n); skip -= k                                            # leading samples before frame 0
            wv.writeframes(planes[:, k:].transpose(1, 0, 2).tobytes())             # planar -> interleaved
            done += n - k
            if max_samples and done >= max_samples:
                break
    return ch


def write_audio(src: str, chunks: list, out: Path) -> int:
    ch = round(chunks[0][1] / (SPC + 40) / 3)
    if (SPC + 40) * 3 * ch != chunks[0][1]:
        raise SystemExit(f"audio chunk {chunks[0][1]} B is not 24,064 samples of 24-bit audio")
    keep = SPC * 3 * ch
    with open(src, "rb") as fi, wave.open(str(out), "wb") as wv:
        wv.setnchannels(ch); wv.setsampwidth(3); wv.setframerate(48000)
        for off, s in chunks:
            if s != chunks[0][1]:
                raise SystemExit(f"odd audio chunk size {s} at {off}")
            fi.seek(off); wv.writeframes(fi.read(keep))
    return ch


def rescue(src: str, out_dir: str, audio_order: str = "lead", fps="60000/1001", fourcc="apch", minutes: float | None = None,
           layout: str = "ninja") -> dict:
    out_dir = Path(out_dir); out_dir.mkdir(parents=True, exist_ok=True)
    stem = Path(src).stem + ("" if minutes is None else f" TEST {audio_order}")
    final = out_dir / f"{stem}.mov"
    if final.exists():
        raise SystemExit(f"{final} exists; not overwriting")
    ts, dur = (int(x) for x in fps.split("/"))
    w = walk(src); p = plan(w, audio_order) if layout == "ninja" else plan_aja(w, audio_order, ts / dur)
    if minutes is not None:
        nf = int(minutes * 60 * ts / dur)
        if layout == "ninja":
            g = nf // FRAMES_PER_CHUNK
            p["frames"], p["chunks"] = p["frames"][: g * FRAMES_PER_CHUNK], p["chunks"][:g]
        else:
            p["frames"] = p["frames"][:nf]
    tv, ta = out_dir / f".{stem}.video.mov", out_dir / f".{stem}.audio.wav"
    write_video(src, p["frames"], tv, (ts, dur), fourcc.encode())
    if layout == "aja":
        ch = write_audio_aja(src, p["chunks"], ta, max_samples=round(len(p["frames"]) * dur / ts * 48000) + 81920,
                             skip=p["audio_skip"])
    else:
        ch = write_audio(src, p["chunks"], ta)
    r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(tv), "-i", str(ta), "-map", "0:v", "-map", "1:a", "-c", "copy",
                        "-shortest", "-f", "mov", str(final)], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"ffmpeg mux failed: {r.stderr[-800:]}")
    tv.unlink(); ta.unlink()
    res = {"src": src, "out": str(final), "frames": len(p["frames"]), "audio_chunks": len(p["chunks"]), "channels": ch,
           "seconds": round(len(p["frames"]) * dur / ts, 3), "dropped_head_frames": p["dropped_head_frames"],
           "lead_bytes_skipped": w["lead_bytes"], "audio_order": audio_order, "layout": layout}
    (out_dir / f"{stem}.rescue.json").write_text(json.dumps(res, indent=1))
    return res


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", nargs="+"); ap.add_argument("out_dir")
    ap.add_argument("--audio-order", choices=["lead", "follow"], help="default: lead for ninja, follow for aja (measured)")
    ap.add_argument("--layout", choices=["ninja", "aja"], default="ninja")
    ap.add_argument("--fps", default="60000/1001"); ap.add_argument("--fourcc", default="apch")
    ap.add_argument("--minutes", type=float, help="test build of the first N minutes only")
    a = ap.parse_args()
    for s in a.src:
        order = a.audio_order or ("follow" if a.layout == "aja" else "lead")
        print(json.dumps(rescue(s, a.out_dir, order, a.fps, a.fourcc, a.minutes, a.layout)), flush=True)
