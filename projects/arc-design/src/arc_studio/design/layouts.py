#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Layout mockups for ARC name cards.

Compose candidate layouts as static PNGs FIRST, review, then build the winner
in Fusion. Iterating composition here takes milliseconds; iterating it by
building Fusion macros takes minutes and hides mistakes until render time.

The checkerboard ground is deliberate - it shows where alpha actually is, so
you can judge how much of frame a design occupies before committing.

    python -m arc_studio.design.layouts --name "Alex Example" --role "Lead Technician"
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
FONT = "/System/Library/Fonts/HelveticaNeue.ttc"
BOLD, MED = 1, 0
W, H = 1920, 1080
LEFT = 280          # common left margin - every layout hangs off this
BASE = 820          # shared baseline band


def _f(sz: int, idx: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT, sz, index=idx)


def _ground() -> tuple[Image.Image, ImageDraw.ImageDraw]:
    im = Image.new("RGB", (W, H), (40, 40, 44))
    d = ImageDraw.Draw(im)
    for y in range(0, H, 60):
        for x in range(0, W, 60):
            if (x // 60 + y // 60) % 2 == 0:
                d.rectangle([x, y, x + 59, y + 59], fill=(52, 52, 58))
    return im, d


def _brand(slug: str) -> dict:
    return json.loads((ROOT / "brands" / f"{slug}.json").read_text())


def _rgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def rule(d, name, role, red, white, grey):
    d.rectangle([LEFT, BASE - 58, LEFT + 6, BASE + 64], fill=red)
    d.text((LEFT + 30, BASE - 56), name, font=_f(72, BOLD), fill=white)
    d.text((LEFT + 32, BASE + 20), role.upper(), font=_f(34, MED), fill=grey)


def plate(d, name, role, red, white, grey):
    fn, fr = _f(66, BOLD), _f(30, MED)
    pw = int(max(d.textlength(name, font=fn), d.textlength(role.upper(), font=fr))) + 120
    d.rectangle([LEFT, BASE - 70, LEFT + pw, BASE + 78], fill=(20, 20, 20))
    d.rectangle([LEFT, BASE - 70, LEFT + 14, BASE + 78], fill=red)
    d.text((LEFT + 50, BASE - 52), name, font=fn, fill=white)
    d.text((LEFT + 52, BASE + 22), role.upper(), font=fr, fill=grey)


def underscore(d, name, role, red, white, grey):
    fn = _f(76, BOLD)
    tw = d.textlength(name, font=fn)
    d.text((LEFT, BASE - 60), name, font=fn, fill=white)
    d.rectangle([LEFT, BASE + 26, LEFT + tw + 90, BASE + 32], fill=red)
    d.text((LEFT, BASE + 48), role.upper(), font=_f(32, MED), fill=grey)


def data_panel(d, name, role, red, white, grey):
    """NASA-console feel. NOTE: needs work - the small red label reads as
    invisible at distance. Do not ship without enlarging it."""
    d.rectangle([LEFT, BASE - 96, LEFT + 900, BASE - 94], fill=(90, 90, 90))
    d.rectangle([LEFT, BASE + 92, LEFT + 900, BASE + 94], fill=(90, 90, 90))
    d.text((LEFT, BASE - 84), " ".join("CREW"), font=_f(22, MED), fill=red)
    d.text((LEFT, BASE - 46), name, font=_f(64, BOLD), fill=white)
    d.text((LEFT, BASE + 36), " ".join(role.upper()), font=_f(26, MED), fill=(120, 120, 120))


LAYOUTS = {"A_rule": rule, "B_plate": plate, "C_underscore": underscore, "D_data_panel": data_panel}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="Alex Example")
    ap.add_argument("--role", default="Technical Director")
    ap.add_argument("--brand", default="arc")
    ap.add_argument("--outdir", default=str(ROOT / "docs" / "layouts"))
    a = ap.parse_args()
    b = _brand(a.brand)
    red = _rgb(b["colors"]["primary"])
    white = _rgb(b["colors"]["text_primary"])
    grey = _rgb(b["colors"]["text_secondary"])
    out = Path(a.outdir); out.mkdir(parents=True, exist_ok=True)
    for key, fn in LAYOUTS.items():
        im, d = _ground()
        fn(d, a.name, a.role, red, white, grey)
        d.text((60, 40), key.replace("_", " "), font=_f(30, MED), fill=(255, 220, 220))
        p = out / f"{a.brand}_{key}.png"
        im.save(p)
        print(f"wrote {p.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
