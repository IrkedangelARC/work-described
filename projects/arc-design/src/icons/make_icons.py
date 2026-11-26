#!/usr/bin/env python3
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""ARC app icons, one family (rewritten 2026-09-17).

WHAT CHANGED FROM THE 2026-09-11 VERSION
The old script drew the same ARC mark on all nine icons and told them apart
with a Futura label. That label is gone by 32 px and unreadable at 16 px, so
in the Dock, the menu bar and the Finder sidebar all nine apps were the same
picture. This version gives each app its own glyph and composes each icns
size separately instead of downscaling one 1024 master:

    >= 256 px   glyph + Futura label + the ARC mark as a corner badge
       128 px   glyph + label, badge dropped (it is a smudge at that size)
    <=  64 px   glyph only, larger, no label, no badge

So the brand reads at Dock-hover size and the app reads at menu-bar size.

SOURCES
Per-app artwork lives in src/<key>.svg, one file per app, editable in
Inkscape (or Affinity Designer). Draw inside the 232..792 box on a 1024
canvas, stroke 56, round caps, ARC red; whatever survives a 16 px render is
the whole icon. src/<key>.png is accepted too and is white-keyed to alpha,
for artwork that only exists as raster (see LOCKUP below). Any colour in the
file is forced to ARC red so a black drawing still comes out on-brand.

The badge is the ARC mark (axis cross, origin circle, golden spiral, both
arrowheads) from arc-laser/assets/engrave-ready/ARC_mark.svg, the only real
vector copy of it. The files under logo/ on the archive volume are raster: the
one named "Arc Logo tranperent.png" has no alpha channel and carries ghost
text in its background, and "Arc Logo tranperent.svg" is a 4 MB PNG wrapped
in an <image> tag, not paths. logo/raster-exports/arc_logo.png is the clean
one (1505x1020, white ground) and is what LOCKUP points at.

OUTPUT (per app, into out/<key>/)
    icon-1024.png        large-tier preview
    icon-32.png          small-tier preview, actual pixels
    <key>.icns           10 images, composed per size
    AppIcon.appiconset/  the same 10 + Contents.json, for Xcode
    layers/              bg / glyph / label / badge as unmasked transparent
                         1024 PNGs, to drag into Icon Composer for a .icon

macOS 26+ draws its own container, mask, shadow and glass for a .icon, so
the layers/ export deliberately has no rounded rect and no baked shade. The
.icns keeps the 824 px rounded square because the fleet still deploys to
macOS 14 and 15, where the app supplies its own container.

USAGE
    make_icons.py                     every app in APPS -> out/<key>/
    make_icons.py ptz presenter       a subset
    make_icons.py --sheet             also write out/_contact_sheet.png
    make_icons.py --install           also copy into each project's target
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFont

ROOT = "/Users/you/projects"
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")
OUT = os.path.join(HERE, "out")
MARK_SVG = f"{ROOT}/arc-laser/assets/engrave-ready/ARC_mark.svg"
LOCKUP = f"{ROOT}/arc-design/logo/raster-exports/arc_logo.png"
FUTURA = "/System/Library/Fonts/Supplemental/Futura.ttc"

RED = (193, 39, 45, 255)          # ARC red #C1272D, the logo red (arc-style/brand/arc_brand.json)

# Glyph colour = the app's signal-flow role (decided 2026-09-18: more colourful,
# colour-coordinated icons). Blue IN, orange OPERATE, green MONITOR, crimson OUT, from the brand file, so the
# Dock reads like the consoles: what brings media in is blue, what the operator drives is orange, what
# leaves the box is crimson. The ARC mark badge stays red on every icon.
sys.path.insert(0, f"{ROOT}/arc-style/brand")
from arc_brand import hex as brand_hex  # noqa: E402
ROLE_HEX = {"in": brand_hex("screen.secBlue"), "op": brand_hex("screen.secOrange"),
            "mon": brand_hex("screen.secGreen"), "out": brand_hex("screen.secCrimson")}
# zoom = "in": the sidecar's job is bringing remote participants INTO the show, which
# groups it with Capture and Grab. dictate = "mon": it has no signal-flow role at all,
# so it sits with the timer as a desk utility rather than pretending to be program.
APP_ROLE = {"capture": "in", "grab": "in", "zoom": "in",
            "ptz": "op", "presenter": "op",
            "timer": "mon", "dictate": "mon",
            "keyer": "out", "switcher": "out", "showmode": "out",
            "slidelog": "mon"}   # a recorder of what happened, no signal-flow role: with the timer and dictate
GROUND = (18, 18, 18, 255)        # #121212
WEDGE = [(28, 28, 28), (36, 36, 36), (44, 44, 44), (52, 52, 52), (60, 60, 60)]
LABEL = (236, 236, 236, 255)

# Geometry, all as a fraction of the icon body (Apple HIG: the body is 824 of
# a 1024 canvas, corner radius 185.4 of that body).
BODY_F = 824 / 1024
RADIUS_F = 185.4 / 824
SMALL_MAX = 64                    # at or below this, glyph only
GLYPH_LARGE = 0.52                # glyph box as a fraction of the body
GLYPH_SMALL = 0.66
GLYPH_CY_LARGE = 0.44             # glyph centre, fraction down the body
GLYPH_CY_SMALL = 0.50
LABEL_CY = 0.815
BADGE_F = 0.17                    # ARC mark badge, fraction of the body
BADGE_MIN = 256                   # below this the badge is a smudge, so drop it

# key: (label, install target). Targets are an .xcassets dir (the parent of
# AppIcon.appiconset) or an .icns path for the Compose-built PTZ app.
# 2026-09-22: presenter and capture now point at the LIVE worktrees (arc-presenter-v5,
# arc-capture-v3). They used to name arc-presenter / arc-capture, the old checkouts, which
# is why the 2026-09-17 install had to be hand-copied into the worktrees afterwards.
# zoom and dictate added; both shipped with no asset catalog and no icon at all.
# basic and assimilator dropped: both retired, and ARC Presenter Basic was removed from
# every fleet Mac on 2026-09-22.
APPS = {
    "ptz":         ("PTZ",         f"{ROOT}/arc-ptz/desktop/packaging/ARC PTZ QUAD.icns"),
    "presenter":   ("PRESENTER",   f"{ROOT}/arc-presenter-v5/ArcPresenter/Assets.xcassets"),
    "timer":       ("TIMER",       f"{ROOT}/arc-stage-timer/ArcStageTimer/Assets.xcassets"),
    "keyer":       ("KEYER",       f"{ROOT}/arc-keyer/ArcKeyer/Assets.xcassets"),
    "switcher":    ("SWITCHER",    f"{ROOT}/arc-switcher/ArcSwitcher/Assets.xcassets"),
    "capture":     ("CAPTURE",     f"{ROOT}/arc-capture-v3/ArcCapture/Assets.xcassets"),
    "grab":        ("GRAB",        f"{ROOT}/arc-grab/ArcGrab/Assets.xcassets"),
    "zoom":        ("ZOOM",        f"{ROOT}/arc-zoom/ArcZoom/Assets.xcassets"),
    "dictate":     ("DICTATE",     f"{ROOT}/arc-dictate/ArcDictate/Assets.xcassets"),
    "showmode":    ("SHOW MODE",   f"{ROOT}/arc-show-mode/ArcShowMode/Assets.xcassets"),
    "slidelog":    ("SLIDE LOG",   f"{ROOT}/arc-slide-log/ArcSlideLog/Assets.xcassets"),
    "show":        ("SHOW",        f"{ROOT}/arc-show-v2/v2/controlapp/ARC Show.icns"),
}

# The mark's own paths, from ICON.txt: spiral, cross+circle, both arrowheads.
KEEP = {"path37", "path4", "path5", "path2", "path3"}
STROKE = {"path37": 55, "path4": 45, "path5": 45, "path2": 45, "path3": 45}

# icns/appiconset points. iconutil wants exactly these; 64 is not one of them
# and the old script's icon_64x64.png was being ignored.
POINTS = [16, 32, 128, 256, 512]
PIXELS = sorted({p * s for p in POINTS for s in (1, 2)})   # 16, 32, 64, 128, 256, 512, 1024


# --------------------------------------------------------------------------
# sources

def _rsvg(svg_text: str, px: int) -> Image.Image:
    """Render SVG text px wide on transparent, then trim.

    Width only, never -w AND -h: the ARC mark's artboard is 100 x 75.471 mm,
    and pinning both axes squeezes it into a square. The glyphs under src/ are
    square so they do not care, but the badge does."""
    with tempfile.TemporaryDirectory() as td:
        src, png = os.path.join(td, "a.svg"), os.path.join(td, "a.png")
        open(src, "w").write(svg_text)
        subprocess.run(["rsvg-convert", "-w", str(px), "-b", "none", "-o", png, src],
                       check=True)
        im = Image.open(png).convert("RGBA")
    return im.crop(im.getbbox() or (0, 0, px, px))


def render_mark(px: int) -> Image.Image:
    """The ARC mark in red on transparent, trimmed. The SVG structure is kept
    intact so the relative paths keep their group transforms (ICON.txt)."""
    svg = open(MARK_SVG).read()

    def fix(m):
        tag = m.group(0)
        pid = re.search(r'id="([^"]+)"', tag)
        pid = pid.group(1) if pid else ""
        if pid not in KEEP:
            return re.sub(r' d="[^"]*"', ' d="M0,0"', tag)
        tag = re.sub(r'stroke-width:[0-9.]+', f'stroke-width:{STROKE[pid]}', tag)
        tag = re.sub(r'stroke:#[0-9a-fA-F]+', 'stroke:#C1272D', tag)
        tag = re.sub(r'fill:#[0-9a-fA-F]+', 'fill:none', tag)
        if 'stroke-linecap' in tag:
            tag = re.sub(r'stroke-linecap:[a-z]+', 'stroke-linecap:round', tag)
        else:
            tag = tag.replace('style="', 'style="stroke-linecap:round;', 1)
        return tag

    return _rsvg(re.sub(r'<path[^>]*>', fix, svg), px)


def white_key(im: Image.Image) -> Image.Image:
    """Raster artwork on a white ground -> transparent, for the logo files
    under logo/, none of which carry an alpha channel despite their names.

    Alpha is 255 - min(R,G,B), which is how far the pixel is from white along
    its weakest channel, so an anti-aliased edge fades out instead of turning
    into a hard fringe. Keying on the LIGHTEST channel instead would read ARC
    red (R=200) as nearly white and hand back an almost invisible logo. The
    colour is then un-premultiplied, otherwise every soft edge keeps the white
    it was sitting on and the mark gets a pale halo on the dark ground."""
    a = np.asarray(im.convert("RGB"), dtype=np.float32)
    alpha = 255.0 - a.min(axis=2)
    # The lockup's red bottoms out at 16, not 0, so its densest pixel keys to
    # alpha 220 and the whole mark lands at 86% opacity. Normalise so the
    # densest ink is fully opaque.
    peak = float(alpha.max())
    if peak > 0:
        alpha = np.clip(alpha * (255.0 / peak), 0, 255)
    safe = np.maximum(alpha, 1.0)[:, :, None]
    rgb = np.clip((a - (255.0 - alpha)[:, :, None]) * 255.0 / safe, 0, 255)
    out = np.dstack([rgb, alpha[:, :, None]]).astype(np.uint8)
    keyed = Image.fromarray(out, "RGBA")
    return keyed.crop(keyed.getbbox() or (0, 0, keyed.width, keyed.height))


def render_glyph(key: str, px: int) -> Image.Image:
    """Per-app artwork from src/<key>.svg, or src/<key>.png white-keyed.
    Every colour in an SVG is forced to the app's ROLE colour (APP_ROLE), so a
    glyph drawn in black or red still lands on-brand."""
    svg = os.path.join(SRC, f"{key}.svg")
    png = os.path.join(SRC, f"{key}.png")
    colour = ROLE_HEX[APP_ROLE.get(key, "op")]
    if os.path.exists(svg):
        text = open(svg).read()
        text = re.sub(r'(stroke|fill)="#[0-9a-fA-F]{3,8}"', rf'\1="{colour}"', text)
        text = re.sub(r'(stroke|fill):#[0-9a-fA-F]{3,8}', rf'\1:{colour}', text)
        return _rsvg(text, px)
    if os.path.exists(png):
        im = white_key(Image.open(png))
        return im.resize((px, max(1, round(px * im.height / im.width))), Image.LANCZOS)
    raise SystemExit(f"no artwork for {key}: expected {svg} or {png}")


# --------------------------------------------------------------------------
# composition

def rounded_rect_mask(size: int, radius: float) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def ground(body: int) -> Image.Image:
    """Near-black square with the Signal wedge: five vertical bands, each a
    touch lighter than the last, then a soft diagonal darkening so it reads
    as a surface rather than a flag. The diagonal is built small and scaled
    up, which is both smooth and O(1) in the icon size (the old per-pixel
    loop made a 2048 px compose take minutes)."""
    g = Image.new("RGBA", (body, body), GROUND)
    d = ImageDraw.Draw(g)
    bw = body / len(WEDGE)
    for i, c in enumerate(WEDGE):
        d.rectangle([int(i * bw), 0, int((i + 1) * bw), body], fill=c + (255,))
    n = 64
    small = Image.new("L", (n, n))
    px = small.load()
    for y in range(n):
        for x in range(n):
            px[x, y] = int(255 * (1.0 - 0.22 * (x + y) / (2.0 * (n - 1))))
    shade = small.resize((body, body), Image.BICUBIC)
    r, gg, b, a = g.split()
    return Image.merge("RGBA", (ImageChops.multiply(r, shade),
                                ImageChops.multiply(gg, shade),
                                ImageChops.multiply(b, shade), a))


def fit_font(text: str, max_w: int, max_h: int) -> ImageFont.FreeTypeFont:
    size = max_h
    while size > 10:
        f = ImageFont.truetype(FUTURA, size, index=2)  # .ttc: 0 Medium, 1 Italic, 2 Bold
        if f.getlength(text) + 0.12 * size * (len(text) - 1) <= max_w:
            return f
        size -= 2
    return ImageFont.truetype(FUTURA, 10, index=2)


def draw_spaced(d: ImageDraw.ImageDraw, xy, text, font, fill, spacing):
    x, y = xy
    for ch in text:
        d.text((x, y), ch, font=font, fill=fill)
        x += font.getlength(ch) + spacing


def fit(im: Image.Image, box: int) -> Image.Image:
    """Scale artwork so its longest side is box px, preserving aspect."""
    s = box / max(im.size)
    return im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.LANCZOS)


def compose(key: str, label: str, canvas: int, small: bool, badge: bool = True,
            masked: bool = True, layer: str | None = None) -> Image.Image:
    """One icon at one canvas size. `small` picks the glyph-only treatment,
    `badge` draws the ARC mark in the corner. `masked=False` and `layer` are
    what the Icon Composer export uses: no rounded container, and one element
    at a time on transparent."""
    body = round(canvas * BODY_F)
    off = (canvas - body) // 2
    ic = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))

    if masked and layer in (None, "bg"):
        g = ground(body)
        g.putalpha(rounded_rect_mask(body, body * RADIUS_F))
        ic.alpha_composite(g, (off, off))
    elif layer == "bg":
        ic.alpha_composite(ground(body), (off, off))
    if layer == "bg":
        return ic

    if layer in (None, "glyph"):
        gl = fit(render_glyph(key, canvas), round(body * (GLYPH_SMALL if small else GLYPH_LARGE)))
        cy = GLYPH_CY_SMALL if small else GLYPH_CY_LARGE
        ic.alpha_composite(gl, (off + (body - gl.width) // 2,
                                off + round(body * cy) - gl.height // 2))
    if layer == "glyph":
        return ic

    if small:                       # no label, no badge below 128 px
        return ic

    if layer in (None, "label"):
        d = ImageDraw.Draw(ic)
        font = fit_font(label, round(body * 0.70), round(body * 0.125))
        spacing = 0.12 * font.size
        tw = font.getlength(label) + spacing * (len(label) - 1)
        draw_spaced(d, (off + (body - tw) / 2, off + round(body * LABEL_CY) - font.size // 2),
                    label, font, LABEL, spacing)
    if layer == "label":
        return ic

    if layer in (None, "badge") and badge:
        bd = fit(render_mark(canvas), round(body * BADGE_F))
        ic.alpha_composite(bd, (off + body - bd.width - round(body * 0.055),
                                off + round(body * 0.055)))
    return ic


def render_at(key: str, label: str, px: int) -> Image.Image:
    """Compose at 4x the target (capped at 2048) and resample down, so 16 and
    32 px come out of their own composition rather than a 1024 downscale."""
    canvas = min(px * 4, 2048)
    im = compose(key, label, canvas, small=px <= SMALL_MAX, badge=px >= BADGE_MIN)
    return im.resize((px, px), Image.LANCZOS) if canvas != px else im


# --------------------------------------------------------------------------
# output

def write_iconset(key: str, label: str, outdir: str) -> str:
    by_px = {px: render_at(key, label, px) for px in PIXELS}

    iconset = os.path.join(outdir, "icon.iconset")
    shutil.rmtree(iconset, ignore_errors=True); os.makedirs(iconset)
    for pt in POINTS:
        by_px[pt].save(os.path.join(iconset, f"icon_{pt}x{pt}.png"))
        by_px[pt * 2].save(os.path.join(iconset, f"icon_{pt}x{pt}@2x.png"))
    icns = os.path.join(outdir, f"{key}.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)

    aset = os.path.join(outdir, "AppIcon.appiconset")
    shutil.rmtree(aset, ignore_errors=True); os.makedirs(aset)
    images = []
    for pt in POINTS:
        for scale in (1, 2):
            name = f"AppIcon-mac-{pt}.png" if scale == 1 else f"AppIcon-mac-{pt}@2x.png"
            by_px[pt * scale].save(os.path.join(aset, name))
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x",
                           "size": f"{pt}x{pt}"})
    json.dump({"images": images, "info": {"author": "xcode", "version": 1}},
              open(os.path.join(aset, "Contents.json"), "w"), indent=2)

    by_px[1024].save(os.path.join(outdir, "icon-1024.png"))
    by_px[32].save(os.path.join(outdir, "icon-32.png"))
    return icns


def write_layers(key: str, label: str, outdir: str):
    """Unmasked transparent layers for Icon Composer. No container and no
    baked shade: on macOS 26+ the system draws those itself."""
    ldir = os.path.join(outdir, "layers")
    shutil.rmtree(ldir, ignore_errors=True); os.makedirs(ldir)
    for name in ("bg", "glyph", "label", "badge"):
        im = compose(key, label, 2048, small=False, masked=False, layer=name)
        im.resize((1024, 1024), Image.LANCZOS).save(os.path.join(ldir, f"{name}-1024.png"))


def contact_sheet(keys):
    """Both tiers side by side, because the whole point is what survives at
    16 and 32 px. Large tile 128, then the 32 and 16 renders at actual size."""
    pad, tile = 16, 128
    sheet = Image.new("RGBA", (pad + len(keys) * (tile + pad), tile + 3 * pad + 72), (24, 24, 24, 255))
    d = ImageDraw.Draw(sheet)
    f = ImageFont.truetype(FUTURA, 16, index=0)
    for i, key in enumerate(keys):
        x = pad + i * (tile + pad)
        big = Image.open(os.path.join(OUT, key, "icon-1024.png")).resize((tile, tile), Image.LANCZOS)
        sheet.alpha_composite(big, (x, pad))
        s32 = Image.open(os.path.join(OUT, key, "icon.iconset", "icon_32x32.png"))
        s16 = Image.open(os.path.join(OUT, key, "icon.iconset", "icon_16x16.png"))
        sheet.alpha_composite(s32, (x, pad * 2 + tile))
        sheet.alpha_composite(s16, (x + 40, pad * 2 + tile + 8))
        d.text((x, pad * 2 + tile + 44), key, font=f, fill=(200, 200, 200, 255))
    path = os.path.join(OUT, "_contact_sheet.png")
    sheet.save(path)
    return path


def install(key: str, outdir: str, target: str):
    if target.endswith(".icns"):
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy(os.path.join(outdir, f"{key}.icns"), target)
        print(f"  installed {target}")
        return
    if not os.path.isdir(target):
        print(f"  SKIP install: no asset catalog at {target}")
        return
    dst = os.path.join(target, "AppIcon.appiconset")
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(os.path.join(outdir, "AppIcon.appiconset"), dst)
    print(f"  installed {dst}")


def main():
    if not shutil.which("rsvg-convert"):
        raise SystemExit("rsvg-convert not found: brew install librsvg")
    if not os.path.exists(MARK_SVG):
        raise SystemExit(f"ARC mark missing: {MARK_SVG}")

    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    do_install, do_sheet = "--install" in sys.argv, "--sheet" in sys.argv
    unknown = [k for k in args if k not in APPS]
    if unknown:
        raise SystemExit(f"unknown app key(s): {', '.join(unknown)}\nknown: {', '.join(APPS)}")
    keys = args or list(APPS)

    os.makedirs(OUT, exist_ok=True)
    for key in keys:
        label, target = APPS[key]
        outdir = os.path.join(OUT, key)
        os.makedirs(outdir, exist_ok=True)
        icns = write_iconset(key, label, outdir)
        write_layers(key, label, outdir)
        print(f"{key}: {label} -> {outdir} ({os.path.getsize(icns) // 1024} KB icns)")
        if do_install:
            install(key, outdir, target)

    if do_sheet:
        print(f"contact sheet -> {contact_sheet(keys)}")


if __name__ == "__main__":
    main()
