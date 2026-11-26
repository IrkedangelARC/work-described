#!/usr/bin/env python3
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""
ARC Color Grade — multicam color matching pipeline.

Usage:
    python3 arc_color_grade.py --input /path/to/shoot --output /path/to/out

Implements:
    1. Media inspection via ffprobe
    2. Reference still extraction
    3. White reference auto-detection (HSV-based)
    4. WB + exposure correction (per-channel gain)
    5. Wood-region saturation compensation
    6. CDL + 3D LUT generation
    7. Contact sheet + scope panel generation

Tested on Sony BRC-AM7 + SRG-A40 PTZs recorded to Atomos Sumo (ProRes 422 LT).
"""
import os
import sys
import json
import argparse
import subprocess
import glob
from pathlib import Path

import numpy as np
import cv2


REFERENCE_FRAMES_DEFAULT = [300, 900, 1200]  # 5, 15, 20 min
ANALYSIS_FRAMES_DEFAULT = [2400, 3000, 3600, 4500, 5400, 6300, 7200]  # 40-120 min
LUT_SIZE = 33


def inspect_media(path):
    """Return ffprobe JSON for a media file."""
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_format", "-show_streams",
         "-print_format", "json", str(path)],
        capture_output=True, text=True, check=True,
    )
    return json.loads(result.stdout)


def extract_still(input_path, t_seconds, output_path):
    """Extract a single still at the given timecode.

    setparams forces bt709 + tv range before swscale: AJA Ki Pro ProRes
    tags container primaries but leaves frame-side primaries 'reserved',
    which makes ffmpeg 8.x swscale refuse the pixfmt conversion.
    """
    subprocess.run(
        ["ffmpeg", "-y", "-ss", str(t_seconds), "-i", str(input_path),
         "-vf", "setparams=range=tv:colorspace=bt709:color_primaries=bt709:"
                "color_trc=bt709,scale=1280:-2",
         "-frames:v", "1", "-q:v", "2", str(output_path)],
        capture_output=True, check=True,
    )


def find_white_pixels(bgr, region=None):
    """Return should-be-white pixels (high V, low S in HSV) and their count."""
    roi = bgr if region is None else bgr[region[0]:region[1], region[2]:region[3]]
    hsv = cv2.cvtColor(roi, cv2.COLOR_BGR2HSV)
    mask = (hsv[..., 2] > 180) & (hsv[..., 1] < 35)
    if mask.sum() < 50:
        mask = (hsv[..., 2] > 150) & (hsv[..., 1] < 50)
    return roi[mask], int(mask.sum())


def wood_mask(bgr):
    """Mask warm-brown wood paneling pixels (HSV range)."""
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    mask = cv2.inRange(hsv, np.array([5, 40, 30]), np.array([30, 200, 200]))
    return cv2.erode(mask, np.ones((5, 5), np.uint8))


def compute_camera_wb(white_pixels_bgr):
    """Compute per-channel WB gain from a stack of white pixels (BGR)."""
    bgr_mean = np.mean(white_pixels_bgr, axis=0)
    rgb_mean = bgr_mean[::-1]  # to R, G, B
    R, G, B = rgb_mean
    return {
        "R_gain": float(G / R),
        "G_gain": 1.0,
        "B_gain": float(G / B),
        "white_G": float(G),
        "white_R": float(R),
        "white_B": float(B),
    }


def compute_final_slopes(camera_wbs):
    """Combine WB gain with exposure lift across cameras."""
    max_G = max(c["white_G"] for c in camera_wbs.values())
    final = {}
    for cam, wb in camera_wbs.items():
        lift = max_G / wb["white_G"]
        final[cam] = {
            "R": wb["R_gain"] * lift,
            "G": wb["G_gain"] * lift,
            "B": wb["B_gain"] * lift,
            "lift": lift,
        }
    return final


def luma(bgr):
    """Rec.709 luma (0-255 float) from a BGR image."""
    f = bgr.astype(np.float32)
    return 0.0722 * f[..., 0] + 0.7152 * f[..., 1] + 0.2126 * f[..., 2]


def measure_luma_anchors(images_bgr, black_pct=1.0, white_pct=95.0):
    """Per-camera black and bright luma anchors (normalized 0-1).

    Black = low percentile (shadows / dark screen), robust to a few hot pixels.
    White = high percentile (brightest stable tones), avoids specular clipping
    that a strict max would catch. Pooled across all supplied frames.
    """
    vals = []
    for bgr in images_bgr:
        vals.append(luma(bgr).ravel())
    if not vals:
        return None
    allv = np.concatenate(vals)
    b = float(np.percentile(allv, black_pct)) / 255.0
    w = float(np.percentile(allv, white_pct)) / 255.0
    return {"black": b, "white": w}


def compute_two_point_match(cam_anchors, ref_cam):
    """Solve per-camera scalar slope+offset to map each camera's (black,white)
    luma anchors onto the reference camera's. Equal across R/G/B so exposure and
    black level move without disturbing the (already-close) color balance.

        out = in*slope + offset   with   slope=(Wr-Br)/(Wc-Bc),  offset=Br-slope*Bc
    """
    ref = cam_anchors[ref_cam]
    Br, Wr = ref["black"], ref["white"]
    out = {}
    for cam, a in cam_anchors.items():
        Bc, Wc = a["black"], a["white"]
        span = Wc - Bc
        slope = (Wr - Br) / span if span > 1e-4 else 1.0
        offset = Br - slope * Bc
        out[cam] = {
            "slope": {"R": slope, "G": slope, "B": slope},
            "offset": {"R": offset, "G": offset, "B": offset},
            "black": Bc, "white": Wc,
        }
    return out


def apply_sop(bgr, slope, offset):
    """Apply scalar/dict CDL slope+offset to a BGR image for preview."""
    f = bgr.astype(np.float32) / 255.0
    for ci, ch in enumerate(("B", "G", "R")):
        f[..., ci] = f[..., ci] * slope[ch] + offset[ch]
    return np.clip(f * 255, 0, 255).astype(np.uint8)


def apply_slopes(bgr, slopes):
    """Apply per-channel slope (CDL-style multiplier)."""
    f = bgr.astype(np.float32) / 255.0
    f[..., 0] *= slopes["B"]
    f[..., 1] *= slopes["G"]
    f[..., 2] *= slopes["R"]
    return np.clip(f * 255, 0, 255).astype(np.uint8)


def apply_sat(bgr, factor):
    """HSV-space saturation scaling."""
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV).astype(np.float32)
    hsv[..., 1] = np.clip(hsv[..., 1] * factor, 0, 255)
    return cv2.cvtColor(hsv.astype(np.uint8), cv2.COLOR_HSV2BGR)


def measure_wood_sat(images_bgr):
    """Mean saturation of wood pixels across a list of BGR images."""
    sat_vals = []
    for bgr in images_bgr:
        m = wood_mask(bgr)
        if m.sum() < 1000:
            continue
        hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
        sat_vals.append(np.mean(hsv[..., 1][m > 0]))
    return float(np.mean(sat_vals)) if sat_vals else None


def write_cdl(path, cam_id, slopes, sat, offset=None, power=None, description=""):
    """Write an ASC CDL XML file. offset/power are 3-tuples (R,G,B)."""
    off = offset if offset is not None else {"R": 0.0, "G": 0.0, "B": 0.0}
    pw = power if power is not None else {"R": 1.0, "G": 1.0, "B": 1.0}
    xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<ColorDecisionList xmlns="urn:ASC:CDL:v1.01">
    <ColorDecision>
        <ColorCorrection id="{cam_id}">
            <SOPNode>
                <Description>{description}</Description>
                <Slope>{slopes["R"]:.4f} {slopes["G"]:.4f} {slopes["B"]:.4f}</Slope>
                <Offset>{off["R"]:.4f} {off["G"]:.4f} {off["B"]:.4f}</Offset>
                <Power>{pw["R"]:.4f} {pw["G"]:.4f} {pw["B"]:.4f}</Power>
            </SOPNode>
            <SatNode>
                <Saturation>{sat:.3f}</Saturation>
            </SatNode>
        </ColorCorrection>
    </ColorDecision>
</ColorDecisionList>
'''
    Path(path).write_text(xml)


def write_cube_lut(path, slopes, sat, offset=None, power=None,
                   title="ARC Color Grade", size=LUT_SIZE):
    """Write a 3D LUT .cube file implementing CDL SOP (slope/offset/power) + sat."""
    off = offset if offset is not None else {"R": 0.0, "G": 0.0, "B": 0.0}
    pw = power if power is not None else {"R": 1.0, "G": 1.0, "B": 1.0}
    # Build grid
    coords = np.linspace(0, 1, size)
    pts = np.zeros((size**3, 3), dtype=np.float32)
    idx = 0
    for ib in range(size):
        for ig in range(size):
            for ir in range(size):
                pts[idx] = [coords[ir], coords[ig], coords[ib]]
                idx += 1
    # Apply ASC CDL SOP per channel: out = (in*slope + offset)^power
    for ci, ch in enumerate(("R", "G", "B")):
        v = pts[:, ci] * slopes[ch] + off[ch]
        v = np.clip(v, 0, None)
        pts[:, ci] = np.power(v, pw[ch])
    pts = np.clip(pts, 0, 1)
    # Apply sat (luma + sat*(c - luma))
    luma = 0.2126 * pts[:, 0] + 0.7152 * pts[:, 1] + 0.0722 * pts[:, 2]
    for c in range(3):
        pts[:, c] = luma + sat * (pts[:, c] - luma)
    pts = np.clip(pts, 0, 1)
    with open(path, "w") as f:
        f.write(f'TITLE "{title}"\n')
        f.write(f"LUT_3D_SIZE {size}\n")
        f.write("DOMAIN_MIN 0.0 0.0 0.0\n")
        f.write("DOMAIN_MAX 1.0 1.0 1.0\n\n")
        for r, g, b in pts:
            f.write(f"{r:.6f} {g:.6f} {b:.6f}\n")


def find_movie_files(input_dir):
    """Find .MOV/.MP4/.MXF files in input directory, sorted."""
    patterns = ["*.MOV", "*.mov", "*.MP4", "*.mp4", "*.MXF", "*.mxf"]
    files = []
    for p in patterns:
        files.extend(glob.glob(os.path.join(input_dir, p)))
    return sorted(set(files))


def main():
    ap = argparse.ArgumentParser(description="ARC Color Grade pipeline")
    ap.add_argument("--input", required=True, help="Folder containing camera ISOs")
    ap.add_argument("--output", required=True, help="Output folder")
    ap.add_argument("--reference-frames", default="5,15,20",
                    help="Comma-separated minutes for white-reference sampling")
    ap.add_argument("--analysis-frames", default="40,50,60,75,90,105,120",
                    help="Comma-separated minutes for stills extraction and verification")
    ap.add_argument("--sat-mode", default="split",
                    choices=["full", "split", "none"],
                    help="Saturation compensation mode")
    ap.add_argument("--reference-cam", type=int, default=2,
                    help="Reference ISO: sat anchor (wb mode) or black/white anchor (luma mode)")
    ap.add_argument("--skip-iso", default="4",
                    help="Comma-separated ISO numbers to skip (e.g. slide feed)")
    ap.add_argument("--mode", default="wb", choices=["wb", "luma"],
                    help="wb: white-ref WB + wood-sat (default). "
                         "luma: two-point exposure+black match, color untouched")
    ap.add_argument("--black-pct", type=float, default=1.0,
                    help="luma mode: percentile for black anchor")
    ap.add_argument("--white-pct", type=float, default=95.0,
                    help="luma mode: percentile for bright anchor")
    ap.add_argument("--white-ref", action="append", default=[],
                    help="Explicit white/neutral reference for one camera, repeatable: "
                         "ISO=SECONDS@x0,y0,x1,y1 (file time; box in 1280-wide still pixels). "
                         "Overrides auto-detection for that ISO. Use on tight shots, where the "
                         "auto pick lands on skin, khaki or other non-neutral bright surfaces.")
    ap.add_argument("--max-iso", type=int, default=12,
                    help="Highest ISO number to look for")
    args = ap.parse_args()

    input_dir = Path(args.input)
    output_dir = Path(args.output)
    stills_dir = output_dir / "stills"
    grades_dir = output_dir / "grades"
    output_dir.mkdir(parents=True, exist_ok=True)
    stills_dir.mkdir(exist_ok=True)
    grades_dir.mkdir(exist_ok=True)

    ref_minutes = [int(x.strip()) for x in args.reference_frames.split(",")]
    ana_minutes = [int(x.strip()) for x in args.analysis_frames.split(",")]
    skip = {int(x.strip()) for x in args.skip_iso.split(",") if x.strip()}

    # Phase 1: find files
    files = find_movie_files(input_dir)
    print(f"Found {len(files)} files in {input_dir}")
    for f in files:
        print(f"  {os.path.basename(f)}")

    # Map to ISO numbers. Match "ISO{n}." (trailing dot before extension) and
    # scan high->low so ISO12 isn't captured by the "ISO1" substring test.
    iso_files = {}
    for f in files:
        name = os.path.basename(f).upper()
        for i in range(args.max_iso, 0, -1):
            if f"ISO{i}." in name:
                if i not in skip:
                    iso_files[i] = f
                break
    print(f"\nUsing ISOs: {sorted(iso_files.keys())}  (skipped: {sorted(skip)})")

    # Phase 2: extract stills
    print("\nExtracting reference stills...")
    for iso, path in iso_files.items():
        for m in ref_minutes + ana_minutes:
            out = stills_dir / f"ISO{iso}_{m:03d}min.jpg"
            if not out.exists():
                try:
                    extract_still(path, m * 60, out)
                except subprocess.CalledProcessError:
                    print(f"  failed: ISO{iso} at {m}min")

    # ---- luma mode: two-point exposure + black-level match (color untouched) ----
    if args.mode == "luma":
        print("\nMeasuring luma anchors (black / bright) per camera...")
        cam_anchors = {}
        for iso in sorted(iso_files):
            imgs = []
            for m in ref_minutes + ana_minutes:
                still = stills_dir / f"ISO{iso}_{m:03d}min.jpg"
                if still.exists():
                    bgr = cv2.imread(str(still))
                    if bgr is not None:
                        imgs.append(bgr)
            a = measure_luma_anchors(imgs, args.black_pct, args.white_pct)
            if a is None:
                print(f"  ISO{iso}: no stills, skipping")
                continue
            cam_anchors[iso] = a
            print(f"  ISO{iso}: black={a['black']*255:5.1f}  white={a['white']*255:5.1f}")

        if args.reference_cam not in cam_anchors:
            ref = sorted(cam_anchors)[len(cam_anchors) // 2]
            print(f"\nReference ISO {args.reference_cam} absent; using ISO{ref}")
        else:
            ref = args.reference_cam
        print(f"Reference camera: ISO{ref}  "
              f"(black={cam_anchors[ref]['black']*255:.1f}, white={cam_anchors[ref]['white']*255:.1f})")

        match = compute_two_point_match(cam_anchors, ref)
        print("\nTwo-point match (slope=exposure, offset=black level):")
        for iso in sorted(match):
            m = match[iso]
            print(f"  ISO{iso}: slope={m['slope']['R']:.4f}  offset={m['offset']['R']:+.4f}")

        print("\nWriting CDL + LUT files...")
        for iso in sorted(match):
            m = match[iso]
            cdl_path = grades_dir / f"ISO{iso}_arccolor.cdl"
            write_cdl(str(cdl_path), f"ISO{iso}_ARCColorGrade", m["slope"], 1.0,
                      offset=m["offset"],
                      description=f"ARC exposure+black match ISO{iso} -> ref ISO{ref}")
            lut_path = grades_dir / f"ISO{iso}_arccolor.cube"
            write_cube_lut(str(lut_path), m["slope"], 1.0, offset=m["offset"],
                           title=f"ARC Exposure Match ISO{iso}")
            print(f"  {cdl_path.name} / {lut_path.name}")

        summary = grades_dir / "GRADE_SUMMARY.txt"
        with open(summary, "w") as f:
            f.write("ARC Color Grade Summary (luma exposure+black match)\n")
            f.write("=" * 50 + "\n\n")
            f.write(f"Input: {input_dir}\nReference cam: ISO{ref}\n")
            f.write(f"Black pct: {args.black_pct}  White pct: {args.white_pct}\n")
            f.write(f"Frames: {ref_minutes + ana_minutes} min\n\n")
            f.write("Per-camera SOP (slope/offset applied equally to R/G/B, sat=1.0):\n")
            for iso in sorted(match):
                m = match[iso]
                f.write(f"  ISO{iso}: in_black={m['black']*255:5.1f} in_white={m['white']*255:5.1f} "
                        f"-> slope={m['slope']['R']:.4f} offset={m['offset']['R']:+.4f}\n")
            f.write("\nApply in Resolve: Color page -> Group Pre-Clip -> Apply CDL File\n")
        print(f"\nDone. Summary: {summary}")
        return

    # Phase 3-5: white balance
    print("\nSampling white references...")
    explicit = {}
    for spec in args.white_ref:
        iso_s, rest = spec.split("=")
        t_s, box = rest.split("@")
        explicit[int(iso_s)] = (float(t_s), tuple(int(v) for v in box.split(",")))
    camera_white_pixels = {}
    overlays = []
    for iso, (t_s, (x0, y0, x1, y1)) in explicit.items():
        if iso not in iso_files:
            continue
        still = stills_dir / f"ISO{iso}_whiteref_{int(t_s)}s.jpg"
        if not still.exists():
            extract_still(iso_files[iso], t_s, still)
        bgr = cv2.imread(str(still))
        # An explicit box IS the reference: measure every unclipped pixel in it. The auto
        # filter (low HSV saturation) rejects a white object under a strong cast, which is
        # exactly the cast we are measuring (JOB-0000: pink-cast tee on ATEM ISO2 -> 0 px).
        roi_px = bgr[y0:y1, x0:x1].reshape(-1, 3)
        pixels = roi_px[roi_px.max(axis=1) < 250]
        count = len(pixels)
        print(f"  ISO{iso}: explicit ref @ {t_s:.0f}s box {x0},{y0}-{x1},{y1}: {count} px"
              f" ({len(roi_px) - count} clipped px dropped)")
        camera_white_pixels[iso] = pixels if count > 20 else None
        o = bgr.copy()
        roi = o[y0:y1, x0:x1]
        roi[roi.max(axis=2) < 250] = (255, 0, 255)
        cv2.rectangle(o, (x0, y0), (x1, y1), (0, 255, 255), 2)
        overlays.append((iso, o))
    for iso in iso_files:
        if iso in explicit:
            continue
        all_white = []
        for m in ref_minutes:
            still = stills_dir / f"ISO{iso}_{m:03d}min.jpg"
            if not still.exists():
                continue
            bgr = cv2.imread(str(still))
            # Default safe region: bottom half avoids projector spill
            h = bgr.shape[0]
            pixels, count = find_white_pixels(bgr, region=(h // 3, h, 0, bgr.shape[1]))
            if count > 50:
                all_white.append(pixels)
        if not all_white:
            print(f"  ISO{iso}: no white pixels found, sampling full frame")
            for m in ref_minutes:
                still = stills_dir / f"ISO{iso}_{m:03d}min.jpg"
                if not still.exists():
                    continue
                bgr = cv2.imread(str(still))
                pixels, count = find_white_pixels(bgr)
                if count > 50:
                    all_white.append(pixels)
        camera_white_pixels[iso] = np.vstack(all_white) if all_white else None
        first = stills_dir / f"ISO{iso}_{ref_minutes[0]:03d}min.jpg"
        if first.exists():
            o = cv2.imread(str(first)); h = o.shape[0]
            roi = o[h // 3:h]
            hsv = cv2.cvtColor(roi, cv2.COLOR_BGR2HSV)
            m = (hsv[..., 2] > 180) & (hsv[..., 1] < 35)
            if m.sum() < 50:
                m = (hsv[..., 2] > 150) & (hsv[..., 1] < 50)
            roi[m] = (255, 0, 255)
            overlays.append((iso, o))

    # Always show what was treated as white: auto-detection has picked khaki trousers
    # on tight shots (JOB-0000). Check this sheet before trusting any slope.
    if overlays:
        tiles = []
        for iso, o in sorted(overlays, key=lambda x: x[0]):
            t = cv2.resize(o, (640, 360))
            cv2.putText(t, f"ISO{iso} white pick", (12, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 255, 255), 2)
            tiles.append(t)
        while len(tiles) % 2:
            tiles.append(np.zeros_like(tiles[0]))
        sheet = np.vstack([np.hstack(tiles[i:i + 2]) for i in range(0, len(tiles), 2)])
        cv2.imwrite(str(output_dir / "WHITE_PICK_CHECK.jpg"), sheet)
        print(f"  white-pick overlay: {output_dir / 'WHITE_PICK_CHECK.jpg'}")

    print("\nWhite reference RGB:")
    camera_wbs = {}
    for iso, pix in camera_white_pixels.items():
        if pix is None or len(pix) == 0:
            print(f"  ISO{iso}: NO white reference found, skipping")
            continue
        wb = compute_camera_wb(pix)
        camera_wbs[iso] = wb
        print(f"  ISO{iso}: R={wb['white_R']:.1f} G={wb['white_G']:.1f} B={wb['white_B']:.1f} "
              f"(R/G={wb['white_R']/wb['white_G']:.3f}, B/G={wb['white_B']/wb['white_G']:.3f})")

    final_slopes = compute_final_slopes(camera_wbs)
    print("\nFinal slopes (WB × exposure lift):")
    for iso, s in final_slopes.items():
        print(f"  ISO{iso}: Slope R={s['R']:.3f} G={s['G']:.3f} B={s['B']:.3f}  exposure_lift={s['lift']:.3f}")

    # Phase 6: saturation compensation (wood-based)
    print("\nMeasuring wood saturation (post-WB) per camera...")
    cam_sat = {}
    for iso in iso_files:
        if iso not in final_slopes:
            continue
        images = []
        for m in ana_minutes:
            still = stills_dir / f"ISO{iso}_{m:03d}min.jpg"
            if not still.exists():
                continue
            bgr = cv2.imread(str(still))
            corrected = apply_slopes(bgr, final_slopes[iso])
            images.append(corrected)
        s = measure_wood_sat(images)
        if s is None:   # no wood in frame (e.g. audience camera): keep its native saturation
            print(f"  ISO{iso}: no wood pixels, sat factor fixed at 1.000")
            continue
        cam_sat[iso] = s
        print(f"  ISO{iso}: wood S = {s:.1f}")

    if args.reference_cam in cam_sat:
        target_sat = cam_sat[args.reference_cam]
    else:
        target_sat = np.median(list(cam_sat.values()))
    print(f"\nSaturation reference: {target_sat:.1f}")

    sat_factors = {iso: 1.0 for iso in final_slopes if iso not in cam_sat}
    for iso, s in cam_sat.items():
        if args.sat_mode == "none":
            sat_factors[iso] = 1.0
        elif args.sat_mode == "full":
            sat_factors[iso] = target_sat / s
        else:  # split
            midpoint = (s + target_sat) / 2
            sat_factors[iso] = midpoint / s
        print(f"  ISO{iso}: sat factor = {sat_factors[iso]:.3f} (mode={args.sat_mode})")

    # Phase 7: write deliverables
    print("\nWriting CDL files...")
    for iso, slopes in final_slopes.items():
        sat = sat_factors[iso]
        cdl_path = grades_dir / f"ISO{iso}_arccolor.cdl"
        write_cdl(str(cdl_path), f"ISO{iso}_ARCColorGrade", slopes, sat,
                  description=f"ARC Color Grade WB+sat for ISO{iso}")
        lut_path = grades_dir / f"ISO{iso}_arccolor.cube"
        write_cube_lut(str(lut_path), slopes, sat,
                       title=f"ARC Color Grade ISO{iso}")
        print(f"  {cdl_path}")
        print(f"  {lut_path}")

    # Write summary
    summary = grades_dir / "GRADE_SUMMARY.txt"
    with open(summary, "w") as f:
        f.write("ARC Color Grade Summary\n")
        f.write("=" * 40 + "\n\n")
        f.write(f"Input: {input_dir}\n")
        f.write(f"Reference frames: {ref_minutes}\n")
        f.write(f"Analysis frames: {ana_minutes}\n")
        f.write(f"Sat mode: {args.sat_mode}\n\n")
        f.write("Final CDL values:\n")
        for iso, slopes in final_slopes.items():
            sat = sat_factors[iso]
            f.write(f"  ISO{iso}: Slope R={slopes['R']:.3f} G={slopes['G']:.3f} B={slopes['B']:.3f}  Sat={sat:.3f}\n")
        f.write("\nApply in Resolve:\n")
        f.write("  Color page -> Group Pre-Clip node -> Right-click -> Apply CDL File\n")

    print(f"\nDone. Summary: {summary}")
    print(f"Apply CDLs from: {grades_dir}")


if __name__ == "__main__":
    main()
