#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""ARC brand resolver. One file of values, resolved by name.

    import sys
    sys.path.insert(0, "/Users/you/projects/arc-style/brand")
    from arc_brand import resolve, hex, rgb01, rgb255

    resolve("red")               -> "#C1272D"
    hex("print.tableHeader")     -> "#383838"
    rgb01("motion.primary")      -> (0.757, 0.153, 0.176)   Fusion / ReportLab floats
    rgb255("screen.accent")      -> (193, 39, 45)            PIL, Kotlin, CSS

Zero dependencies. The values live in arc_brand.json next to this file; this
module never carries a colour of its own. Run it to print the palette.
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

BRAND_FILE = Path(__file__).with_name("arc_brand.json")


@lru_cache(maxsize=1)
def load() -> dict[str, Any]:
    """The whole brand file as a dict (cached)."""
    with open(BRAND_FILE, encoding="utf-8") as fh:
        return json.load(fh)


def resolve(path: str) -> Any:
    """Dotted lookup: "screen.accent", "print.chart.series", "type.document"."""
    node: Any = load()
    for part in path.split("."):
        if not isinstance(node, dict) or part not in node:
            raise KeyError(f"arc_brand: no token {path!r} (stopped at {part!r})")
        node = node[part]
    return node


def hex(path: str) -> str:  # noqa: A001  (shadowing builtins.hex on purpose: it reads as the brand call)
    """Upper-case '#RRGGBB' for a colour token."""
    value = resolve(path)
    if not isinstance(value, str) or len(value) != 7 or value[0] != "#":
        raise TypeError(f"arc_brand: {path!r} is not a colour: {value!r}")
    return value.upper()


def rgb255(path: str) -> tuple[int, int, int]:
    h = hex(path)[1:]
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def rgb01(path: str) -> tuple[float, float, float]:
    r, g, b = rgb255(path)
    return r / 255.0, g / 255.0, b / 255.0


def section(name: str) -> dict[str, str]:
    """Colour tokens of one section ('screen', 'print', 'motion') without notes or nested maps."""
    return {k: v for k, v in resolve(name).items() if isinstance(v, str) and v.startswith("#")}


def tagline(caps: bool = False, mark: bool = True) -> str:
    """The ARC tagline, with the TM (or registered) mark unless mark=False.

    tagline()            -> "We don't sell failure™."
    tagline(caps=True)   -> "WE DON'T SELL FAILURE™"
    """
    t = resolve("tagline")
    text = t["caps"] if caps else t["text"]
    if not mark:
        return text
    symbol = "®" if t["registered"] else t["mark"]
    # The mark sits on the words, inside the full stop.
    return text[:-1] + symbol + "." if text.endswith(".") else text + symbol


def _main() -> None:
    brand = load()
    print(f"ARC brand  red {brand['red']}  decided {brand['meta']['decided']}")
    print(f"tagline    {tagline()}")
    for sec in ("screen", "print", "motion"):
        print(f"\n[{sec}]")
        for k, v in section(sec).items():
            print(f"  {k:14s} {v}")
    print(f"\n[type] document {brand['type']['document']}  console {brand['type']['console']}  motion {brand['type']['motion']}")


if __name__ == "__main__":
    _main()
