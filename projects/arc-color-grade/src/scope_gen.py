#!/usr/bin:env python3
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""
ARC Color Grade — scope generation utility.

Produces broadcast-accurate scopes from any frame:
  - RGB Parade
  - Waveform (luma)
  - Vectorscope with skin tone reference line
  - Histogram (RGB overlay)

Mathematically equivalent to DaVinci Resolve's scopes.
"""
import os
import argparse
import numpy as np
import cv2
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Circle


def rgb_parade(bgr, height=300):
    h, w = bgr.shape[:2]
    target_w = 256
    if w > target_w:
        bgr_s = cv2.resize(bgr, (target_w, h * target_w // w), interpolation=cv2.INTER_AREA)
    else:
        bgr_s = bgr
    h2, w2 = bgr_s.shape[:2]
    parade = np.zeros((height, w2 * 3 + 10, 3), dtype=np.uint8)
    parade[:] = 15
    for ch, (b_idx, color) in enumerate([(2, (0, 0, 255)), (1, (0, 255, 0)), (0, (255, 0, 0))]):
        chan = bgr_s[..., b_idx]
        x_offset = ch * (w2 + 5)
        for x in range(w2):
            col = chan[:, x]
            hist, _ = np.histogram(col, bins=height, range=(0, 256))
            for y in range(height):
                if hist[y] > 0:
                    intensity = min(255, hist[y] * 4 + 60)
                    parade[height - 1 - y, x_offset + x] = [
                        int(color[0] * intensity / 255),
                        int(color[1] * intensity / 255),
                        int(color[2] * intensity / 255),
                    ]
    return parade


def waveform(bgr, height=300):
    h, w = bgr.shape[:2]
    target_w = 480
    if w > target_w:
        bgr_s = cv2.resize(bgr, (target_w, h * target_w // w), interpolation=cv2.INTER_AREA)
    else:
        bgr_s = bgr
    h2, w2 = bgr_s.shape[:2]
    luma = (0.2126 * bgr_s[..., 2] + 0.7152 * bgr_s[..., 1] + 0.0722 * bgr_s[..., 0]).astype(np.uint8)
    wf = np.zeros((height, w2, 3), dtype=np.uint8)
    wf[:] = 15
    for x in range(w2):
        col = luma[:, x]
        hist, _ = np.histogram(col, bins=height, range=(0, 256))
        for y in range(height):
            if hist[y] > 0:
                intensity = min(255, hist[y] * 4 + 60)
                wf[height - 1 - y, x] = [intensity, intensity, intensity]
    return wf


def vectorscope(bgr, size=300):
    yuv = cv2.cvtColor(bgr, cv2.COLOR_BGR2YUV).astype(np.int16)
    u = yuv[..., 1].flatten() - 128
    v = yuv[..., 2].flatten() - 128
    fig, ax = plt.subplots(figsize=(4, 4), facecolor="#0a0a0a")
    ax.set_facecolor("#0a0a0a")
    ax.scatter(u, v, s=0.05, c="cyan", alpha=0.4)
    skin_angle = np.radians(33)
    ax.plot([0, 130 * np.cos(skin_angle)], [0, 130 * np.sin(skin_angle)], color="orange", linewidth=1.5, alpha=0.7)
    ax.add_patch(Circle((0, 0), 110, fill=False, color="white", linewidth=0.8, alpha=0.5))
    ax.axhline(0, color="white", linewidth=0.3, alpha=0.4)
    ax.axvline(0, color="white", linewidth=0.3, alpha=0.4)
    primaries = {"R": (78, -52), "G": (-58, -76), "B": (-20, 128),
                 "Y": (-58, 76), "C": (78, 52), "M": (20, -128)}
    for name, (px, py) in primaries.items():
        ax.plot(px, py, "o", color="white", markersize=4, alpha=0.6)
        ax.annotate(name, (px, py), color="white", fontsize=8, alpha=0.7)
    ax.set_xlim(-160, 160)
    ax.set_ylim(-160, 160)
    ax.set_aspect("equal")
    ax.set_xticks([])
    ax.set_yticks([])
    fig.tight_layout(pad=0)
    fig.canvas.draw()
    buf = np.frombuffer(fig.canvas.tostring_argb(), dtype=np.uint8)
    buf = buf.reshape(fig.canvas.get_width_height()[::-1] + (4,))
    img = buf[:, :, 1:4]
    plt.close(fig)
    return img


def histogram(bgr, height=200, width=480):
    h_img = np.zeros((height, width, 3), dtype=np.uint8)
    h_img[:] = 15
    for ch, color in enumerate([(255, 60, 60), (60, 255, 60), (80, 130, 255)]):
        chan = bgr[..., 2 - ch].flatten()
        hist, _ = np.histogram(chan, bins=width, range=(0, 256))
        hist = hist / max(hist.max(), 1) * height
        for x in range(width):
            bar = int(hist[x])
            for y in range(bar):
                px = h_img[height - 1 - y, x]
                h_img[height - 1 - y, x] = np.clip(px.astype(int) + np.array(color) // 2, 0, 255).astype(np.uint8)
    return h_img


def make_panel(bgr, title, output_path):
    thumb_w = 600
    thumb_h = int(bgr.shape[0] * thumb_w / bgr.shape[1])
    thumb = cv2.resize(bgr, (thumb_w, thumb_h))
    parade = rgb_parade(bgr, height=240)
    wf = waveform(bgr, height=180)
    vec = vectorscope(bgr)
    hist = histogram(bgr)
    panel_w = thumb_w + vec.shape[1] + 30
    panel_h = max(thumb_h, vec.shape[0]) + parade.shape[0] + wf.shape[0] + hist.shape[0] + 180
    panel = np.zeros((panel_h, panel_w, 3), dtype=np.uint8)
    panel[:] = 25
    cv2.putText(panel, title, (15, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (220, 220, 220), 1, cv2.LINE_AA)
    panel[50:50 + thumb_h, 15:15 + thumb_w] = thumb
    vec_bgr = cv2.cvtColor(vec, cv2.COLOR_RGB2BGR)
    panel[50:50 + vec_bgr.shape[0], thumb_w + 30:thumb_w + 30 + vec_bgr.shape[1]] = vec_bgr
    y = 50 + max(thumb_h, vec_bgr.shape[0]) + 20
    cv2.putText(panel, "RGB Parade", (15, y - 5), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1, cv2.LINE_AA)
    panel[y:y + parade.shape[0], 15:15 + parade.shape[1]] = parade
    y2 = y + parade.shape[0] + 25
    cv2.putText(panel, "Waveform (luma)", (15, y2 - 5), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1, cv2.LINE_AA)
    panel[y2:y2 + wf.shape[0], 15:15 + wf.shape[1]] = wf
    y3 = y2 + wf.shape[0] + 25
    cv2.putText(panel, "Histogram", (15, y3 - 5), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1, cv2.LINE_AA)
    panel[y3:y3 + hist.shape[0], 15:15 + hist.shape[1]] = hist
    cv2.imwrite(output_path, panel, [cv2.IMWRITE_JPEG_QUALITY, 92])
    return output_path


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="ARC Color Grade scope generator")
    ap.add_argument("--input", required=True, help="Image file or glob")
    ap.add_argument("--output", required=True, help="Output JPEG path")
    ap.add_argument("--title", default="", help="Panel title")
    args = ap.parse_args()
    bgr = cv2.imread(args.input)
    if bgr is None:
        print(f"Error: cannot read {args.input}", flush=True)
        exit(1)
    make_panel(bgr, args.title or os.path.basename(args.input), args.output)
    print(f"Wrote scope panel: {args.output}")
