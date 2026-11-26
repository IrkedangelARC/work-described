#!/usr/bin/env python3
"""
Shure X2U - Custom Enclosure (Simplified)

Unit: Inline cylindrical adapter ~100mm L × 28mm diameter
Connectors:
- Input end: XLR female (mic input)
- Output end: USB-A male
- Side: 3.5mm headphone jack, gain knob, 48V switch
"""

import cadquery as cq

# Shure X2U dimensions (mm)
UNIT_L = 104  # Internal length with clearance
UNIT_DIA = 30  # Internal diameter with clearance

WALL = 2.5
CAP = 3

EXT_L = UNIT_L + 2 * CAP
EXT_DIA = UNIT_DIA + 2 * WALL

print(f"Shure X2U Enclosure")
print(f"External: {EXT_L:.0f}mm L × {EXT_DIA:.0f}mm dia")

# Main cylindrical body (hollow tube)
outer = (cq.Workplane("XY")
    .circle(EXT_DIA/2)
    .extrude(EXT_L)
)

inner = (cq.Workplane("XY")
    .workplane(offset=CAP)
    .circle(UNIT_DIA/2)
    .extrude(UNIT_L)
)

body = outer.cut(inner)

# === INPUT END - XLR cutout ===
xlr_hole = (cq.Workplane("XY")
    .workplane(offset=0)
    .circle(11)  # 22mm XLR
    .extrude(CAP + 1)
)
body = body.cut(xlr_hole)

# === OUTPUT END - USB-A cutout ===
usb_hole = (cq.Workplane("XY")
    .workplane(offset=EXT_L - CAP - 1)
    .rect(12, 5)  # USB-A rectangular
    .extrude(CAP + 2)
)
body = body.cut(usb_hole)

# === SIDE CUTOUTS - Simplified approach ===
# Headphone jack (positioned at 30% length)
hp_jack = (cq.Workplane("XZ")
    .workplane(offset=EXT_DIA/2 + 1)
    .center(0, EXT_L * 0.3)
    .circle(4.5)
    .extrude(-EXT_DIA)
)
body = body.cut(hp_jack)

# Gain knob slot (50% length)
gain_slot = (cq.Workplane("XZ")
    .workplane(offset=EXT_DIA/2 + 1)
    .center(0, EXT_L * 0.5)
    .rect(8, 15)
    .extrude(-EXT_DIA)
)
body = body.cut(gain_slot)

# 48V switch slot (70% length)
switch_slot = (cq.Workplane("XZ")
    .workplane(offset=EXT_DIA/2 + 1)
    .center(0, EXT_L * 0.7)
    .rect(6, 10)
    .extrude(-EXT_DIA)
)
body = body.cut(switch_slot)

# === VENTILATION - Holes on bottom ===
for i in range(8):
    z_pos = 15 + i * 12
    vent = (cq.Workplane("XZ")
        .workplane(offset=-EXT_DIA/2 + WALL/2)
        .center(0, z_pos)
        .circle(2)
        .extrude(WALL + 1)
    )
    body = body.cut(vent)

# === MOUNTING CLIPS === (Smaller, more discrete)
# Left mounting clip
clip_w = 8   # Reduced from 10mm
clip_h = 15  # Reduced from 25mm
clip_t = 3   # Reduced from 4mm

left_clip = (cq.Workplane("YZ")
    .workplane(offset=-EXT_DIA/2)
    .center(EXT_L/2, 0)
    .rect(clip_h, clip_w)
    .extrude(-clip_t)
    .edges("|X")
    .fillet(1)
)

# Screw hole in clip
screw_hole = (cq.Workplane("YZ")
    .workplane(offset=-EXT_DIA/2 - clip_t/2)
    .center(EXT_L/2, 0)
    .circle(2)
    .extrude(-clip_t)
)
left_clip = left_clip.cut(screw_hole)

body = body.union(left_clip)

# Right clip (mirror)
right_clip = (cq.Workplane("YZ")
    .workplane(offset=EXT_DIA/2)
    .center(EXT_L/2, 0)
    .rect(clip_h, clip_w)
    .extrude(clip_t)
    .edges("|X")
    .fillet(1)
)

screw_hole_r = (cq.Workplane("YZ")
    .workplane(offset=EXT_DIA/2 + clip_t/2)
    .center(EXT_L/2, 0)
    .circle(2)
    .extrude(clip_t)
)
right_clip = right_clip.cut(screw_hole_r)

body = body.union(right_clip)

# Export
output_path = '/Users/you/projects/av-enclosures/exports/shure_x2u_case.stl'
cq.exporters.export(body, output_path)

print(f"\n✓ Saved: shure_x2u_case.stl")
print(f"\n=== FEATURES ===")
print("Input: XLR female (22mm)")
print("Output: USB-A rectangular cutout")
print("Top: Headphone jack, gain knob, 48V switch")
print("Bottom: Ventilation holes")
print("Sides: Mounting clips with M4 screw holes")
print("\n=== PRINT SPECS ===")
print(f"Size: {EXT_L:.0f}×{EXT_DIA:.0f}mm cylinder")
print("Time: ~1.5 hours")
