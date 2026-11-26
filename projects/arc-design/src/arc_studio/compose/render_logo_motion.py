#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Render ARC logo motion video — dynamic reveal with gradation effects.

Outputs white-on-black for luma keying via arc-keyer, demonstrating:
  - Progressive spiral trace with gradient glow trail
  - Axis snap-in with feathered edges
  - Text reveal with soft bloom gradation
  - Pulsing glow cycle showing keyer threshold/softness range
  - Smooth gradient fade out

Usage:
    python -m arc_studio.compose.render_logo_motion [--fps 30] [--duration 12] [--output path.mp4]
"""

from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# ---------------------------------------------------------------------------
# SVG path parser — converts path strings to point sequences
# ---------------------------------------------------------------------------

def _parse_svg_path(d: str) -> list[list[tuple[float, float]]]:
    """Parse SVG path string into list of subpaths (point sequences).

    Supports M, L, C, Z commands (absolute only — ARC logo uses absolute).
    Cubic beziers are sampled at 20 points per curve for smooth rendering.
    """
    tokens = re.findall(r'[MLCZmlcz]|[-+]?\d*\.?\d+', d)
    subpaths: list[list[tuple[float, float]]] = []
    current: list[tuple[float, float]] = []
    i = 0

    while i < len(tokens):
        cmd = tokens[i]
        if cmd in ('M', 'm'):
            if current:
                subpaths.append(current)
            x, y = float(tokens[i+1]), float(tokens[i+2])
            current = [(x, y)]
            i += 3
        elif cmd in ('L', 'l'):
            x, y = float(tokens[i+1]), float(tokens[i+2])
            current.append((x, y))
            i += 3
        elif cmd in ('C', 'c'):
            # Cubic bezier: 3 control points (6 values)
            x1, y1 = float(tokens[i+1]), float(tokens[i+2])
            x2, y2 = float(tokens[i+3]), float(tokens[i+4])
            x3, y3 = float(tokens[i+5]), float(tokens[i+6])
            if current:
                p0 = current[-1]
            else:
                p0 = (x1, y1)
            # Sample bezier
            for t_i in range(1, 21):
                t = t_i / 20.0
                mt = 1 - t
                bx = mt**3*p0[0] + 3*mt**2*t*x1 + 3*mt*t**2*x2 + t**3*x3
                by = mt**3*p0[1] + 3*mt**2*t*y1 + 3*mt*t**2*y2 + t**3*y3
                current.append((bx, by))
            i += 7
        elif cmd in ('Z', 'z'):
            if current and len(current) > 1:
                current.append(current[0])  # Close path
            i += 1
        else:
            # Might be a number following implicit L command
            try:
                x, y = float(tokens[i]), float(tokens[i+1])
                current.append((x, y))
                i += 2
            except (ValueError, IndexError):
                i += 1

    if current:
        subpaths.append(current)
    return subpaths


def _flatten_points(subpaths: list[list[tuple[float, float]]]) -> list[tuple[float, float]]:
    """Flatten all subpaths into a single point sequence."""
    pts = []
    for sp in subpaths:
        pts.extend(sp)
    return pts


# ---------------------------------------------------------------------------
# Easing functions
# ---------------------------------------------------------------------------

def ease_out_cubic(t: float) -> float:
    return 1 - (1 - t) ** 3

def ease_in_out_cubic(t: float) -> float:
    if t < 0.5:
        return 4 * t * t * t
    return 1 - (-2 * t + 2) ** 3 / 2

def ease_out_expo(t: float) -> float:
    return 1 if t >= 1 else 1 - 2 ** (-10 * t)


# ---------------------------------------------------------------------------
# Drawing helpers
# ---------------------------------------------------------------------------

def draw_path_partial(draw: ImageDraw.ImageDraw, points: list[tuple[float, float]],
                      fraction: float, width: int = 3, fill: int = 255):
    """Draw a fraction (0-1) of a polyline path."""
    if not points or fraction <= 0:
        return
    n = max(1, int(len(points) * fraction))
    pts = points[:n]
    if len(pts) < 2:
        return
    for i in range(len(pts) - 1):
        draw.line([pts[i], pts[i+1]], fill=fill, width=width)


def draw_filled_path(draw: ImageDraw.ImageDraw,
                     subpaths: list[list[tuple[float, float]]],
                     fill: int = 255):
    """Draw filled subpaths (for text glyphs)."""
    for sp in subpaths:
        if len(sp) >= 3:
            draw.polygon(sp, fill=fill)


def glow_layer(img: Image.Image, radius: int, intensity: float = 1.0) -> Image.Image:
    """Create a gaussian blur glow from a grayscale image."""
    blurred = img.filter(ImageFilter.GaussianBlur(radius=radius))
    arr = np.array(blurred, dtype=np.float32)
    arr *= intensity
    arr = np.clip(arr, 0, 255).astype(np.uint8)
    return Image.fromarray(arr)


def composite_screen(base: np.ndarray, layer: np.ndarray) -> np.ndarray:
    """Screen-blend two float arrays (0-1 range). Returns float array."""
    return 1.0 - (1.0 - base) * (1.0 - layer)


def multi_glow(img: Image.Image, passes: list[tuple[int, float]]) -> np.ndarray:
    """Stack multiple glow passes at different radii/intensities.

    passes: list of (blur_radius, intensity) tuples.
    Returns float array 0-1.
    """
    result = np.zeros((img.height, img.width), dtype=np.float32)
    for radius, intensity in passes:
        blurred = img.filter(ImageFilter.GaussianBlur(radius=radius))
        layer = np.array(blurred, dtype=np.float32) / 255.0 * intensity
        result = composite_screen(result, layer)
    return result


def radial_gradient(w: int, h: int, cx: float, cy: float,
                    inner_r: float, outer_r: float,
                    inner_val: float = 1.0, outer_val: float = 0.0) -> np.ndarray:
    """Generate a radial gradient (float 0-1) centered at (cx, cy)."""
    y, x = np.ogrid[:h, :w]
    dist = np.sqrt((x - cx)**2 + (y - cy)**2)
    grad = np.clip((dist - inner_r) / max(1, outer_r - inner_r), 0, 1)
    return inner_val + (outer_val - inner_val) * grad


def light_rays(w: int, h: int, cx: float, cy: float,
               num_rays: int = 12, ray_width: float = 0.04,
               intensity: float = 0.5, rotation: float = 0.0) -> np.ndarray:
    """Generate radial light rays emanating from center point."""
    y, x = np.ogrid[:h, :w]
    angles = np.arctan2(y - cy, x - cx) + rotation
    # Create ray pattern using modular arithmetic on angle
    ray_pattern = np.cos(angles * num_rays) ** 16  # Sharp peaks
    # Fade with distance from center
    dist = np.sqrt((x - cx)**2 + (y - cy)**2)
    max_dist = math.sqrt(w**2 + h**2)
    distance_fade = np.clip(1.0 - dist / max_dist, 0, 1) ** 0.5
    return (ray_pattern * distance_fade * intensity).astype(np.float32)


# ---------------------------------------------------------------------------
# Frame renderer
# ---------------------------------------------------------------------------

class LogoMotionRenderer:
    """Renders frames of the ARC logo motion sequence."""

    def __init__(self, width: int = 1920, height: int = 1080, fps: int = 30):
        self.w = width
        self.h = height
        self.fps = fps
        self._load_paths()

    def _load_paths(self):
        path_file = Path(__file__).resolve().parent.parent.parent / "logo" / "vector-exports" / "arc_logo_paths.json"
        data = json.loads(path_file.read_text())
        elements = data["elements"]

        self.spiral_pts = _flatten_points(_parse_svg_path(elements["spiral"]))
        self.x_axis_pts = _flatten_points(_parse_svg_path(elements["x_axis"]))
        self.y_axis_pts = _flatten_points(_parse_svg_path(elements["y_axis"]))
        self.x_arrow_subpaths = _parse_svg_path(elements["x_arrow"])
        self.y_arrow_subpaths = _parse_svg_path(elements["y_arrow"])
        self.arc_text_subpaths = _parse_svg_path(elements["arc_text"])
        self.event_text_subpaths = _parse_svg_path(elements["event_productions_text"])

        self.tick_marks = []
        for tm in data.get("tick_marks", []):
            pts = _flatten_points(_parse_svg_path(tm))
            if pts:
                self.tick_marks.append(pts)

    def render_frame(self, frame_num: int, total_frames: int) -> Image.Image:
        """Render a single frame. Returns an RGB image (white on black).

        Enhanced gradation effects:
          - Multi-pass bloom (near/mid/far glow stacking)
          - Radial gradient pulse from logo origin
          - Luminance-graded spiral (brightness varies along path)
          - Light ray starburst during pulse phase
          - Heavy bloom on text reveal
          - Gradient wipe fade-out with expanding bloom
        """
        t = frame_num / max(1, total_frames - 1)  # 0 → 1

        # Logo origin point (axes intersection)
        ox, oy = 612.0, 442.0

        # Layer: sharp elements
        sharp = Image.new('L', (self.w, self.h), 0)
        draw = ImageDraw.Draw(sharp)

        # Layer: medium glow source (blurred moderately)
        mid_glow = Image.new('L', (self.w, self.h), 0)
        mid_draw = ImageDraw.Draw(mid_glow)

        # Layer: wide/soft glow source (blurred heavily)
        wide_glow = Image.new('L', (self.w, self.h), 0)
        wide_draw = ImageDraw.Draw(wide_glow)

        # Accumulator for background gradients (float 0-1)
        bg = np.zeros((self.h, self.w), dtype=np.float32)

        # ── Phase timing ──
        # 0.00-0.04  Black hold
        # 0.04-0.08  Radial gradient breathes in from origin
        # 0.05-0.35  Spiral traces with luminance gradient + wide glow trail
        # 0.20-0.40  Axes extend with soft halo
        # 0.30-0.45  Arrows with bloom
        # 0.35-0.50  Tick marks
        # 0.38-0.58  ARC text reveals with heavy multi-pass bloom
        # 0.48-0.62  Event Productions with bloom
        # 0.60-0.82  Glow pulse cycle + light rays + radial breathing
        # 0.82-1.00  Bloom expansion fade out

        # ── Ambient radial glow (background atmosphere) ──
        if t > 0.03:
            ambient_frac = min(1.0, (t - 0.03) / 0.12)
            ambient_frac = ease_out_cubic(ambient_frac)
            # Subtle radial gradient centered on origin
            ambient = radial_gradient(self.w, self.h, ox, oy,
                                      inner_r=0, outer_r=600,
                                      inner_val=0.06 * ambient_frac,
                                      outer_val=0.0)
            bg = composite_screen(bg, ambient)

        # ── Spiral trace with luminance gradient ──
        spiral_start, spiral_end = 0.05, 0.35
        if t > spiral_start:
            frac = min(1.0, (t - spiral_start) / (spiral_end - spiral_start))
            frac = ease_out_cubic(frac)
            n_total = len(self.spiral_pts)
            n_draw = max(1, int(n_total * frac))

            # Sharp spiral line — brightness varies along path length
            for j in range(min(n_draw - 1, n_total - 1)):
                pos = j / max(1, n_total - 1)
                # Outer spiral dimmer, inner spiral brighter
                brightness = int(140 + 115 * (1.0 - pos))
                draw.line([self.spiral_pts[j], self.spiral_pts[j+1]],
                          fill=brightness, width=3)

            # Wide glow trail — last 25% of drawn path, fat and bright
            trail_len = 0.25
            trail_start_frac = max(0, frac - trail_len)
            i_start = int(n_total * trail_start_frac)
            i_end = int(n_total * frac)
            if i_end > i_start + 1:
                trail_pts = self.spiral_pts[i_start:i_end]
                for j in range(len(trail_pts) - 1):
                    progress = j / max(1, len(trail_pts) - 1)
                    # Ramp brightness AND width along trail
                    brightness = int(60 + 195 * progress)
                    line_width = int(6 + 20 * progress)
                    wide_draw.line([trail_pts[j], trail_pts[j+1]],
                                   fill=brightness, width=line_width)
                    # Also draw on mid layer at moderate width
                    mid_draw.line([trail_pts[j], trail_pts[j+1]],
                                  fill=int(brightness * 0.7), width=int(line_width * 0.5))

            # Hot point at the drawing tip — bright spot
            if n_draw > 0 and frac < 1.0:
                tip = self.spiral_pts[min(n_draw - 1, n_total - 1)]
                tip_r = 18
                wide_draw.ellipse([tip[0]-tip_r, tip[1]-tip_r,
                                   tip[0]+tip_r, tip[1]+tip_r], fill=255)
                mid_draw.ellipse([tip[0]-tip_r//2, tip[1]-tip_r//2,
                                  tip[0]+tip_r//2, tip[1]+tip_r//2], fill=255)

        # ── Axes with gradient halo ──
        axis_start, axis_end = 0.20, 0.40
        if t > axis_start:
            frac = min(1.0, (t - axis_start) / (axis_end - axis_start))
            frac = ease_out_expo(frac)
            draw_path_partial(draw, self.x_axis_pts, frac, width=2, fill=220)
            draw_path_partial(draw, self.y_axis_pts, frac, width=2, fill=220)
            # Soft halo on axes
            draw_path_partial(mid_draw, self.x_axis_pts, frac, width=8, fill=100)
            draw_path_partial(mid_draw, self.y_axis_pts, frac, width=8, fill=100)

        # ── Arrows with bloom ──
        arrow_start, arrow_end = 0.30, 0.45
        if t > arrow_start:
            frac = min(1.0, (t - arrow_start) / (arrow_end - arrow_start))
            alpha = int(255 * ease_out_cubic(frac))
            draw_filled_path(draw, self.x_arrow_subpaths, fill=alpha)
            draw_filled_path(draw, self.y_arrow_subpaths, fill=alpha)
            # Bloom on arrows
            draw_filled_path(mid_draw, self.x_arrow_subpaths, fill=int(alpha * 0.6))
            draw_filled_path(mid_draw, self.y_arrow_subpaths, fill=int(alpha * 0.6))

        # ── Tick marks ──
        tick_start, tick_end = 0.35, 0.50
        if t > tick_start:
            frac = min(1.0, (t - tick_start) / (tick_end - tick_start))
            n_ticks = int(len(self.tick_marks) * ease_out_cubic(frac))
            for tick_pts in self.tick_marks[:n_ticks]:
                draw_path_partial(draw, tick_pts, 1.0, width=2, fill=200)

        # ── ARC text with heavy multi-pass bloom ──
        arc_start, arc_end = 0.38, 0.58
        if t > arc_start:
            frac = min(1.0, (t - arc_start) / (arc_end - arc_start))
            eased = ease_in_out_cubic(frac)
            alpha = int(255 * eased)
            draw_filled_path(draw, self.arc_text_subpaths, fill=alpha)

            # Bloom ramps up during reveal then settles
            bloom_intensity = 1.0 - abs(frac - 0.5) * 1.4  # Peak at 50% reveal
            bloom_intensity = max(0.15, bloom_intensity)
            draw_filled_path(mid_draw, self.arc_text_subpaths,
                             fill=int(200 * bloom_intensity))
            draw_filled_path(wide_draw, self.arc_text_subpaths,
                             fill=int(160 * bloom_intensity))

        # ── Event Productions text with bloom ──
        evp_start, evp_end = 0.48, 0.62
        if t > evp_start:
            frac = min(1.0, (t - evp_start) / (evp_end - evp_start))
            eased = ease_in_out_cubic(frac)
            alpha = int(255 * eased)
            draw_filled_path(draw, self.event_text_subpaths, fill=alpha)

            bloom_intensity = 1.0 - abs(frac - 0.5) * 1.4
            bloom_intensity = max(0.1, bloom_intensity)
            draw_filled_path(mid_draw, self.event_text_subpaths,
                             fill=int(180 * bloom_intensity))
            draw_filled_path(wide_draw, self.event_text_subpaths,
                             fill=int(120 * bloom_intensity))

        # ── Glow pulse cycle + light rays + radial breathing ──
        pulse_start, pulse_end = 0.60, 0.82
        if pulse_start < t < pulse_end:
            cycle_t = (t - pulse_start) / (pulse_end - pulse_start)

            # Three full pulse cycles with varying amplitude
            pulse = 0.5 + 0.5 * math.sin(cycle_t * 6 * math.pi)
            pulse_sq = pulse ** 0.7  # Soften peaks

            # Redraw entire logo on glow layers at pulsing intensity
            draw_path_partial(mid_draw, self.spiral_pts, 1.0, width=10,
                              fill=int(220 * pulse_sq))
            draw_filled_path(mid_draw, self.arc_text_subpaths,
                             fill=int(200 * pulse_sq))
            draw_filled_path(mid_draw, self.event_text_subpaths,
                             fill=int(160 * pulse_sq))

            draw_path_partial(wide_draw, self.spiral_pts, 1.0, width=20,
                              fill=int(180 * pulse_sq))
            draw_filled_path(wide_draw, self.arc_text_subpaths,
                             fill=int(160 * pulse_sq))
            draw_filled_path(wide_draw, self.event_text_subpaths,
                             fill=int(120 * pulse_sq))

            # Radial gradient pulse — expanding ring from origin
            ring_phase = (cycle_t * 3) % 1.0  # Three rings over the phase
            ring_r = 50 + ring_phase * 800
            ring_width = 120 + ring_phase * 200
            radial_ring = radial_gradient(
                self.w, self.h, ox, oy,
                inner_r=max(0, ring_r - ring_width/2),
                outer_r=ring_r + ring_width/2,
                inner_val=0.0, outer_val=0.0,
            )
            # Ring is bright at its center radius
            dist_arr = np.sqrt(
                (np.arange(self.w)[None, :] - ox)**2 +
                (np.arange(self.h)[:, None] - oy)**2
            )
            ring_mask = np.exp(-((dist_arr - ring_r) / (ring_width * 0.3))**2)
            ring_mask *= 0.12 * pulse_sq * (1.0 - ring_phase * 0.6)
            bg = composite_screen(bg, ring_mask.astype(np.float32))

            # Light rays starburst — rotates slowly
            rotation = cycle_t * math.pi * 0.5
            rays = light_rays(self.w, self.h, ox, oy,
                              num_rays=16, ray_width=0.03,
                              intensity=0.10 * pulse_sq,
                              rotation=rotation)
            bg = composite_screen(bg, rays)

        # ── Gradient fade out with expanding bloom ──
        fade_start = 0.84
        global_alpha = 1.0
        bloom_expand = 1.0
        if t > fade_start:
            fade_frac = (t - fade_start) / (1.0 - fade_start)
            global_alpha = 1.0 - ease_in_out_cubic(fade_frac)
            # Bloom radius expands as we fade — logo dissolves into soft glow
            bloom_expand = 1.0 + fade_frac * 4.0

            # Final radial bloom burst
            final_bloom = radial_gradient(self.w, self.h, ox, oy,
                                          inner_r=0,
                                          outer_r=200 + fade_frac * 600,
                                          inner_val=0.15 * (1.0 - fade_frac),
                                          outer_val=0.0)
            bg = composite_screen(bg, final_bloom)

        # ── Composite all layers ──

        # Multi-pass glow from mid and wide source layers
        mid_radius = int(15 * bloom_expand)
        wide_radius = int(45 * bloom_expand)

        mid_blurred = multi_glow(mid_glow, [
            (mid_radius, 0.9),
        ])
        wide_blurred = multi_glow(wide_glow, [
            (wide_radius, 0.7),
            (int(wide_radius * 1.8), 0.35),
        ])

        # Start with background gradients
        result = bg.copy()

        # Screen-blend the wide glow (outermost halo)
        result = composite_screen(result, wide_blurred)

        # Screen-blend the mid glow
        result = composite_screen(result, mid_blurred)

        # Screen-blend the sharp layer on top
        sharp_arr = np.array(sharp, dtype=np.float32) / 255.0
        result = composite_screen(result, sharp_arr)

        # Apply global fade
        if global_alpha < 1.0:
            result *= global_alpha

        # Clamp and convert
        result = np.clip(result * 255, 0, 255).astype(np.uint8)
        gray = Image.fromarray(result)
        return gray.convert('RGB')

    def render_all(self, duration: float = 12.0) -> list[Image.Image]:
        """Render all frames for the given duration."""
        total = int(duration * self.fps)
        frames = []
        for i in range(total):
            frames.append(self.render_frame(i, total))
            if (i + 1) % self.fps == 0:
                print(f"  Rendered {i+1}/{total} frames "
                      f"({(i+1)/total*100:.0f}%)", flush=True)
        return frames


# ---------------------------------------------------------------------------
# Video export
# ---------------------------------------------------------------------------

def render_video(output_path: str | Path = None,
                 fps: int = 30, duration: float = 12.0) -> Path:
    """Render the full ARC logo motion video."""
    from moviepy import ImageSequenceClip

    if output_path is None:
        output_path = (Path(__file__).resolve().parent.parent.parent
                       / "output" / "arc_logo_motion.mp4")
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"Rendering ARC logo motion: {duration}s @ {fps}fps")
    print(f"Resolution: 1920x1080 (luma key source)")

    renderer = LogoMotionRenderer(fps=fps)
    frames = renderer.render_all(duration)

    print(f"Encoding video → {output_path}")
    frame_arrays = [np.array(f) for f in frames]
    clip = ImageSequenceClip(frame_arrays, fps=fps)
    clip.write_videofile(
        str(output_path),
        codec="libx264",
        preset="medium",
        ffmpeg_params=["-crf", "18", "-pix_fmt", "yuv420p"],
        logger=None,
    )

    size_mb = output_path.stat().st_size / (1024 * 1024)
    print(f"\nDone: {output_path} ({size_mb:.1f} MB)")
    return output_path


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Render ARC logo motion video")
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--duration", type=float, default=12.0)
    parser.add_argument("--output", type=str, default=None)
    args = parser.parse_args()
    render_video(args.output, args.fps, args.duration)
