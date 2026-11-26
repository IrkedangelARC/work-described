#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Generate Fusion .setting macros from brand tokens.

Fusion macros are plain-text Lua-ish tables, so templates can be authored
programmatically instead of clicked together in the Resolve GUI. One generator
emits a correct template for any brand in brands/.

Spec for ARC_LT_FullWidth follows docs/FUSION_WORKFLOW.md exactly:
  1920x1080 30fps, 5 s (0-1 in, 1-4 hold, 4-5 out), 10% title safe.

Usage:
    python -m arc_studio.fusion.template_gen --brand arc
    python -m arc_studio.fusion.template_gen --brand client --out /tmp/x.setting
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def hex_to_rgb(h: str) -> tuple[float, float, float]:
    h = h.lstrip("#")
    return tuple(round(int(h[i:i + 2], 16) / 255.0, 4) for i in (0, 2, 4))


def load_brand(slug: str) -> dict:
    p = ROOT / "brands" / f"{slug}.json"
    if not p.exists():
        raise SystemExit(f"no brand tokens at {p}")
    return json.loads(p.read_text())


def _spline(name: str, keys: list[tuple[int, float]]) -> str:
    """Linear BezierSpline. keys = [(frame, value), ...]"""
    body = ",\n".join(
        f"\t\t\t\t\t\t[{f}] = {{ {v} }}" for f, v in keys
    )
    return (
        f"\t\t\t\t{name} = BezierSpline {{\n"
        f"\t\t\t\t\tSplineColor = {{ Red = 255, Green = 0, Blue = 255 }},\n"
        f"\t\t\t\t\tNameSet = true,\n"
        f"\t\t\t\t\tKeyFrames = {{\n{body}\n\t\t\t\t\t}}\n"
        f"\t\t\t\t}},\n"
    )


def build(brand: dict, fps: int = 30) -> str:
    c = brand["colors"]
    pr, pg, pb = hex_to_rgb(c["primary"])
    # Dark title block: near-black, never pure - reads better on OLED (per workflow doc)
    br, bg, bb = hex_to_rgb(c.get("secondary", "#141414"))
    br, bg, bb = [min(1.0, round(x + 0.08, 4)) for x in (br, bg, bb)]
    tr, tg, tb = hex_to_rgb(c["text_primary"])
    sr, sg, sb = hex_to_rgb(c["text_secondary"])
    font = brand["font_primary"]
    slug = brand["slug"].upper()
    name = f"{slug}_LT_FullWidth"

    IN_A, IN_B = 0, 15          # accent block fade in
    IN_C, IN_D = 5, 20          # title block, staggered 0.17 s behind
    TX_A, TX_B = 15, 30         # name write-on
    TX_C, TX_D = 18, 33         # title write-on, +3 frames
    OUT_A, OUT_B = 120, 150     # 4 s -> 5 s out

    s = []
    s.append("{\n\tTools = ordered() {\n")
    s.append(f"\t\t{name} = MacroOperator {{\n")
    s.append("\t\t\tCtrlWZoom = false,\n\t\t\tNameSet = true,\n")
    # ---- published parameters (what an editor can change on the timeline) ----
    s.append("\t\t\tInputs = ordered() {\n")
    s.append('\t\t\t\tName = InstanceInput {\n\t\t\t\t\tSourceOp = "TextName",\n'
             '\t\t\t\t\tSource = "StyledText",\n\t\t\t\t\tName = "Name",\n'
             '\t\t\t\t\tDefault = "SPEAKER NAME",\n\t\t\t\t},\n')
    s.append('\t\t\t\tTitle = InstanceInput {\n\t\t\t\t\tSourceOp = "TextTitle",\n'
             '\t\t\t\t\tSource = "StyledText",\n\t\t\t\t\tName = "Title",\n'
             '\t\t\t\t\tDefault = "Title / Organisation",\n\t\t\t\t},\n')
    s.append('\t\t\t\tAccentRed = InstanceInput {\n\t\t\t\t\tSourceOp = "BGAccent",\n'
             '\t\t\t\t\tSource = "TopLeftRed",\n\t\t\t\t\tName = "Accent Red",\n\t\t\t\t},\n')
    s.append('\t\t\t\tAccentGreen = InstanceInput {\n\t\t\t\t\tSourceOp = "BGAccent",\n'
             '\t\t\t\t\tSource = "TopLeftGreen",\n\t\t\t\t\tName = "Accent Green",\n\t\t\t\t},\n')
    s.append('\t\t\t\tAccentBlue = InstanceInput {\n\t\t\t\t\tSourceOp = "BGAccent",\n'
             '\t\t\t\t\tSource = "TopLeftBlue",\n\t\t\t\t\tName = "Accent Blue",\n\t\t\t\t},\n')
    s.append("\t\t\t},\n")
    s.append('\t\t\tOutputs = ordered() {\n\t\t\t\tMainOutput1 = InstanceOutput {\n'
             '\t\t\t\t\tSourceOp = "MergeTitle",\n\t\t\t\t\tSource = "Output",\n\t\t\t\t}\n\t\t\t},\n')
    s.append("\t\t\tViewInfo = GroupInfo { Pos = { 0, 0 } },\n")
    s.append("\t\t\tTools = ordered() {\n")

    # ---- 1. transparent base plate ----
    s.append("\t\t\t\tBGBase = Background {\n\t\t\t\t\tInputs = {\n"
             "\t\t\t\t\t\tGlobalOut = Input { Value = 149, },\n"
             "\t\t\t\t\t\tWidth = Input { Value = 1920, },\n"
             "\t\t\t\t\t\tHeight = Input { Value = 1080, },\n"
             "\t\t\t\t\t\tUseFrameFormatSettings = Input { Value = 1, },\n"
             "\t\t\t\t\t\tTopLeftAlpha = Input { Value = 0, },\n"
             '\t\t\t\t\t\tType = Input { Value = FuID { "Solid" }, },\n'
             "\t\t\t\t\t},\n\t\t\t\t\tViewInfo = OperatorInfo { Pos = { 0, 0 } },\n\t\t\t\t},\n")

    # ---- 2. accent block (brand primary) ----
    s.append("\t\t\t\tBGAccent = Background {\n\t\t\t\t\tInputs = {\n"
             "\t\t\t\t\t\tGlobalOut = Input { Value = 149, },\n"
             "\t\t\t\t\t\tWidth = Input { Value = 806, },\n"
             "\t\t\t\t\t\tHeight = Input { Value = 120, },\n"
             "\t\t\t\t\t\tUseFrameFormatSettings = Input { Value = 0, },\n"
             f"\t\t\t\t\t\tTopLeftRed = Input {{ Value = {pr}, }},\n"
             f"\t\t\t\t\t\tTopLeftGreen = Input {{ Value = {pg}, }},\n"
             f"\t\t\t\t\t\tTopLeftBlue = Input {{ Value = {pb}, }},\n"
             '\t\t\t\t\t\tType = Input { Value = FuID { "Solid" }, },\n'
             "\t\t\t\t\t},\n\t\t\t\t\tViewInfo = OperatorInfo { Pos = { 0, 55 } },\n\t\t\t\t},\n")
    s.append("\t\t\t\tXFAccent = Transform {\n\t\t\t\t\tInputs = {\n"
             '\t\t\t\t\t\tCenter = Input { Value = { 0.255, 0.18 }, },\n'
             '\t\t\t\t\t\tInput = Input { SourceOp = "BGAccent", Source = "Output", },\n'
             "\t\t\t\t\t},\n\t\t\t\t\tViewInfo = OperatorInfo { Pos = { 110, 55 } },\n\t\t\t\t},\n")

    # ---- 3. dark title block ----
    s.append("\t\t\t\tBGTitle = Background {\n\t\t\t\t\tInputs = {\n"
             "\t\t\t\t\t\tGlobalOut = Input { Value = 149, },\n"
             "\t\t\t\t\t\tWidth = Input { Value = 922, },\n"
             "\t\t\t\t\t\tHeight = Input { Value = 120, },\n"
             "\t\t\t\t\t\tUseFrameFormatSettings = Input { Value = 0, },\n"
             f"\t\t\t\t\t\tTopLeftRed = Input {{ Value = {br}, }},\n"
             f"\t\t\t\t\t\tTopLeftGreen = Input {{ Value = {bg}, }},\n"
             f"\t\t\t\t\t\tTopLeftBlue = Input {{ Value = {bb}, }},\n"
             '\t\t\t\t\t\tType = Input { Value = FuID { "Solid" }, },\n'
             "\t\t\t\t\t},\n\t\t\t\t\tViewInfo = OperatorInfo { Pos = { 0, 110 } },\n\t\t\t\t},\n")
    s.append("\t\t\t\tXFTitle = Transform {\n\t\t\t\t\tInputs = {\n"
             '\t\t\t\t\t\tCenter = Input { Value = { 0.705, 0.18 }, },\n'
             '\t\t\t\t\t\tInput = Input { SourceOp = "BGTitle", Source = "Output", },\n'
             "\t\t\t\t\t},\n\t\t\t\t\tViewInfo = OperatorInfo { Pos = { 110, 110 } },\n\t\t\t\t},\n")

    # ---- 4/5. text ----
    s.append("\t\t\t\tTextName = TextPlus {\n\t\t\t\t\tInputs = {\n"
             "\t\t\t\t\t\tGlobalOut = Input { Value = 149, },\n"
             "\t\t\t\t\t\tWidth = Input { Value = 1920, },\n"
             "\t\t\t\t\t\tHeight = Input { Value = 1080, },\n"
             "\t\t\t\t\t\tUseFrameFormatSettings = Input { Value = 1, },\n"
             '\t\t\t\t\t\tStyledText = Input { Value = "SPEAKER NAME", },\n'
             f'\t\t\t\t\t\tFont = Input {{ Value = "{font}", }},\n'
             '\t\t\t\t\t\tStyle = Input { Value = "Bold", },\n'
             "\t\t\t\t\t\tSize = Input { Value = 0.06, },\n"
             f"\t\t\t\t\t\tRed1 = Input {{ Value = {tr}, }},\n"
             f"\t\t\t\t\t\tGreen1 = Input {{ Value = {tg}, }},\n"
             f"\t\t\t\t\t\tBlue1 = Input {{ Value = {tb}, }},\n"
             "\t\t\t\t\t\tCenter = Input { Value = { 0.255, 0.18 }, },\n"
             "\t\t\t\t\t\tHorizontalJustification = Input { Value = 3, },\n"
             "\t\t\t\t\t\tVerticalJustification = Input { Value = 3, },\n"
             '\t\t\t\t\t\tWriteOnEnd = Input { SourceOp = "NameWriteOn", Source = "Value", },\n'
             "\t\t\t\t\t},\n\t\t\t\t\tViewInfo = OperatorInfo { Pos = { 0, 165 } },\n\t\t\t\t},\n")
    s.append(_spline("NameWriteOn", [(TX_A, 0), (TX_B, 1)]))

    s.append("\t\t\t\tTextTitle = TextPlus {\n\t\t\t\t\tInputs = {\n"
             "\t\t\t\t\t\tGlobalOut = Input { Value = 149, },\n"
             "\t\t\t\t\t\tWidth = Input { Value = 1920, },\n"
             "\t\t\t\t\t\tHeight = Input { Value = 1080, },\n"
             "\t\t\t\t\t\tUseFrameFormatSettings = Input { Value = 1, },\n"
             '\t\t\t\t\t\tStyledText = Input { Value = "Title / Organisation", },\n'
             f'\t\t\t\t\t\tFont = Input {{ Value = "{font}", }},\n'
             '\t\t\t\t\t\tStyle = Input { Value = "Medium", },\n'
             "\t\t\t\t\t\tSize = Input { Value = 0.038, },\n"
             f"\t\t\t\t\t\tRed1 = Input {{ Value = {sr}, }},\n"
             f"\t\t\t\t\t\tGreen1 = Input {{ Value = {sg}, }},\n"
             f"\t\t\t\t\t\tBlue1 = Input {{ Value = {sb}, }},\n"
             "\t\t\t\t\t\tCenter = Input { Value = { 0.705, 0.19 }, },\n"
             "\t\t\t\t\t\tHorizontalJustification = Input { Value = 3, },\n"
             "\t\t\t\t\t\tVerticalJustification = Input { Value = 3, },\n"
             '\t\t\t\t\t\tWriteOnEnd = Input { SourceOp = "TitleWriteOn", Source = "Value", },\n'
             "\t\t\t\t\t},\n\t\t\t\t\tViewInfo = OperatorInfo { Pos = { 0, 220 } },\n\t\t\t\t},\n")
    s.append(_spline("TitleWriteOn", [(TX_C, 0), (TX_D, 1)]))

    # ---- 6-9. merges, each carrying its own in/out level animation ----
    def merge(nm, bgop, fgop, pos, spline_nm, keys):
        s.append(f"\t\t\t\t{nm} = Merge {{\n\t\t\t\t\tInputs = {{\n"
                 f'\t\t\t\t\t\tBackground = Input {{ SourceOp = "{bgop}", Source = "Output", }},\n'
                 f'\t\t\t\t\t\tForeground = Input {{ SourceOp = "{fgop}", Source = "Output", }},\n'
                 f'\t\t\t\t\t\tBlend = Input {{ SourceOp = "{spline_nm}", Source = "Value", }},\n'
                 "\t\t\t\t\t\tPerformDepthMerge = Input { Value = 0, },\n"
                 f"\t\t\t\t\t}},\n\t\t\t\t\tViewInfo = OperatorInfo {{ Pos = {{ {pos[0]}, {pos[1]} }} }},\n\t\t\t\t}},\n")
        s.append(_spline(spline_nm, keys))

    merge("MergeAccent", "BGBase", "XFAccent", (220, 55), "AccentLevel",
          [(IN_A, 0), (IN_B, 1), (OUT_A, 1), (OUT_B, 0)])
    merge("MergeBlock", "MergeAccent", "XFTitle", (220, 110), "BlockLevel",
          [(IN_C, 0), (IN_D, 1), (OUT_A, 1), (OUT_B, 0)])
    merge("MergeName", "MergeBlock", "TextName", (220, 165), "NameLevel",
          [(TX_A, 0), (TX_A + 4, 1), (OUT_A, 1), (OUT_B - 8, 0)])
    merge("MergeTitle", "MergeName", "TextTitle", (220, 220), "TitleLevel",
          [(TX_C, 0), (TX_C + 4, 1), (OUT_A, 1), (OUT_B - 8, 0)])

    s.append("\t\t\t}\n\t\t}\n\t},\n")
    s.append(f'\tActiveTool = "{name}"\n}}\n')
    return "".join(s)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--brand", default="arc")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    b = load_brand(a.brand)
    text = build(b)
    out = Path(a.out) if a.out else (
        ROOT / "fusion" / "templates" / "Titles" / "ARC" /
        f"{b['slug'].upper()}_LT_FullWidth.setting")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    print(f"wrote {out}  ({len(text)} bytes, {text.count(chr(10))} lines)")


if __name__ == "__main__":
    main()
