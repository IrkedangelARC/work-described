#!/usr/bin/env python3
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Diff every hand-held copy of the ARC brand against brand/arc_brand.json.

Swift and Kotlin cannot import a JSON file at compile time, and arc.json keeps
the 7-key BrandProfile schema it shares with client brand files, so those copies are
checked rather than generated. Run after any edit to the brand file or to a
theme file:

    python3 ~/projects/arc-style/tools/check_brand_sync.py

Exit 0 = every copy matches. Exit 1 = drift, each line names file, token,
found and expected. Missing files are reported and skipped (a frozen app that
is not checked out is not drift).
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECTS = HERE.parent.parent
sys.path.insert(0, str(HERE.parent / "brand"))
from arc_brand import hex as bhex, load  # noqa: E402

BRAND = load()
RED = BRAND["red"]
SCREEN = {k: v for k, v in BRAND["screen"].items() if isinstance(v, str) and v.startswith("#")}

drift: list[str] = []
checked = 0


def report(file: Path, token: str, found: str | None, expected: str) -> None:
    global checked
    checked += 1
    if found is None:
        drift.append(f"  {file.relative_to(PROJECTS)}  {token}: NOT FOUND (expected {expected})")
    elif found.upper() != expected.upper():
        drift.append(f"  {file.relative_to(PROJECTS)}  {token}: {found} -> expected {expected}")


def read(rel: str) -> tuple[Path, str | None]:
    p = PROJECTS / rel
    if not p.exists():
        print(f"  skip (missing): {rel}")
        return p, None
    return p, p.read_text(encoding="utf-8", errors="replace")


# ── Swift: Color(red: 0xRR/255, green: 0xGG/255, blue: 0xBB/255) ───────────
SWIFT_RE = re.compile(r"static let (\w+)\s*=\s*Color\(red: 0x([0-9A-Fa-f]{2})/255, green: 0x([0-9A-Fa-f]{2})/255, blue: 0x([0-9A-Fa-f]{2})/255\)")
SWIFT_FLOAT_RE = re.compile(r"static let (\w+)\s*=\s*Color\(red: ([\d.]+), green: ([\d.]+), blue: ([\d.]+)\)")
SWIFT_TOKENS = {  # ARCTheme name -> brand token
    "ink": "ink", "panel": "panelBg", "moduleBg": "moduleBg", "subGroup": "subGroup", "appGrey": "appGrey", "line": "line",
    "text0": "text0", "text1": "text1", "text2": "text2", "arcRed": "accent", "live": "live", "warn": "warn",
    "secOrange": "secOrange", "secBlue": "secBlue", "secGreen": "secGreen", "secCrimson": "secCrimson",
}


def check_swift(rel: str, full: bool) -> None:
    p, text = read(rel)
    if text is None:
        return
    found: dict[str, str] = {}
    for name, r, g, b in SWIFT_RE.findall(text):
        found[name] = f"#{r}{g}{b}".upper()
    for name, r, g, b in SWIFT_FLOAT_RE.findall(text):
        found[name] = "#%02X%02X%02X" % tuple(round(float(x) * 255) for x in (r, g, b))
    names = SWIFT_TOKENS if full else {"arcRed": "accent"}
    for name, token in names.items():
        report(p, name, found.get(name), SCREEN[token])


# ── Kotlin: val Name = Color(0xFFRRGGBB) ────────────────────────────────────
KT_RE = re.compile(r"val (\w+)\s*=\s*Color\(0xFF([0-9A-Fa-f]{6})\)")
KT_TOKENS = {
    "Ink": "ink", "PanelBg": "panelBg", "ModuleBg": "moduleBg", "AppGrey": "appGrey", "Line": "line",
    "Text0": "text0", "Text1": "text1", "AccentQ": "accent", "LiveQ": "live", "WarnYellow": "warn",
    "SecOrange": "secOrange", "SecBlue": "secBlue", "SecRed": "secRed", "SecCrimson": "secCrimson", "SecGreen": "secGreen",
}


def check_kotlin(rel: str, names: dict[str, str]) -> None:
    p, text = read(rel)
    if text is None:
        return
    found = {n: f"#{h}".upper() for n, h in KT_RE.findall(text)}
    for name, token in names.items():
        report(p, name, found.get(name), SCREEN[token])


def check_regex(rel: str, token: str, pattern: str, expected: str) -> None:
    p, text = read(rel)
    if text is None:
        return
    m = re.search(pattern, text)
    report(p, token, m.group(1) if m else None, expected)


def check_no_old_reds(rel: str) -> None:
    """Art and CSS that should carry only the one red: any other historical ARC red is drift."""
    p, text = read(rel)
    if text is None:
        return
    for old in BRAND["meta"]["history"]:
        if re.search(old, text, re.I):
            report(p, f"old red {old}", old, RED)
    checked_here = re.findall(r"#[0-9A-Fa-f]{6}", text)
    if not any(h.upper() == RED for h in checked_here):
        report(p, "brand red present", None, RED)


def main() -> int:
    print(f"ARC brand sync  red {RED}  ({BRAND['meta']['decided']})")

    # The package and QUAD: full token sets.
    check_swift("arc-style/Sources/ARCStyle/ARCTheme.swift", full=True)
    check_kotlin("arc-ptz/desktop/src/main/kotlin/com/example/arc/ptz/desktop/QuadTheme.kt", KT_TOKENS)

    # Per-app copies still on their own ARCTheme.swift (adopt the package when next touched): red only.
    for rel in ("arc-grab/ArcGrab/Theme/ARCTheme.swift", "arc-switcher/ArcSwitcher/Theme/ARCTheme.swift",
                "arc-lower-thirds/ArcLowerThirds/Theme/ARCTheme.swift"):
        check_swift(rel, full=False)

    # Kotlin screens with a private Accent.
    for rel in ("arc-ptz/desktop/src/main/kotlin/com/example/arc/ptz/desktop/Main.kt",
                "arc-ptz/app/src/main/java/com/example/arc/ptz/ui/video/VideoScreen.kt",
                "arc-ptz/app/src/main/java/com/example/arc/ptz/ui/control/ControlScreen.kt",
                "arc-signal/app/src/main/java/com/example/arc/signal/ui/SinkScreen.kt",
                "arc-signal/app/src/main/java/com/example/arc/signal/pattern/MenuOverlay.kt"):
        check_kotlin(rel, {"Accent": "accent"})
    check_regex("arc-signal/app/src/main/java/com/example/arc/signal/pattern/AudioVisuals.kt", "accent", r"val accent = 0xFF([0-9A-Fa-f]{6})", RED[1:])

    # Documents: brand.py imports the resolver, so only the fallback-free import is checked.
    check_regex("arc-reports/arc_reports/brand.py", "imports arc_brand", r"(from arc_brand import)", "from arc_brand import")

    # Motion: arc.json keeps the BrandProfile schema.
    p, text = read("arc-design/brands/arc.json")
    if text is not None:
        j = json.loads(text)
        for k, v in BRAND["motion"].items():
            if k.startswith("_"):
                continue
            report(p, f"colors.{k}", j["colors"].get(k), v)
        for k in ("font_primary", "font_secondary", "font_accent"):
            report(p, k, j.get(k), BRAND["type"]["motion"])
    check_regex("arc-design/arc_studio/config.py", "ARC_RED", r'ARC_RED = "(#[0-9A-Fa-f]{6})"', RED)
    check_regex("arc-design/arc_studio/config.py", "DEFAULT_FONT", r'DEFAULT_FONT = "([^"]+)"', BRAND["type"]["motion"])
    check_regex("arc-design/arc_studio/models/brand.py", "ColorPalette.primary", r'primary: str = "(#[0-9A-Fa-f]{6})"', RED)

    # Icons.
    check_regex("arc-design/icons/make_icons.py", "RED", r"RED = \((\d+, \d+, \d+), 255\)", "%d, %d, %d" % tuple(int(RED[i:i + 2], 16) for i in (1, 3, 5)))
    for svg in sorted((PROJECTS / "arc-design/icons/src").glob("*.svg")):
        check_no_old_reds(str(svg.relative_to(PROJECTS)))

    # Logo art and test patterns: one red only.
    for rel in ("arc-design/logo/vector-exports/arc_logo_complete.svg", "arc-design/logo/vector-exports/arc_spiral_only.svg",
                "arc-design/test-patterns/LumaKeyTestPattern.svg", "arc-keyer/ArcKeyer/Resources/LumaKeyTestPattern.svg",
                "arc-stage-timer/ArcStageTimer/WebStageDisplay/stage.css"):
        check_no_old_reds(rel)
    check_regex("arc-design/logo/vector-exports/arc_logo_paths.json", "color", r'"color": "(#[0-9A-Fa-f]{6})"', RED)
    check_regex("arc-design/scripts/extract_logo_vectors.py", "ARC_RED", r'ARC_RED = "(#[0-9A-Fa-f]{6})"', RED)

    print(f"  {checked} tokens checked")
    if drift:
        print("DRIFT:")
        print("\n".join(drift))
        return 1
    print("OK: every copy matches the brand file")
    return 0


if __name__ == "__main__":
    sys.exit(main())
