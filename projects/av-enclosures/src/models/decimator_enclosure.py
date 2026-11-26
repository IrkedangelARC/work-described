#!/usr/bin/env python3
"""
Decimator MD-HX - Custom Enclosure

Unit dimensions: 79.5mm W × 123mm D × 29.5mm H
Features:
- Front: LCD display, control buttons, SDI IN x2, HDMI IN
- Back: SDI OUT x2, HDMI OUT, DC power
- Scaling and frame rate conversion unit - needs good ventilation
"""

import cadquery as cq

# Decimator unit dimensions (mm) + clearance
UNIT_W = 79.5 + 3  # 82.5mm internal width
UNIT_D = 123.0 + 3  # 126mm internal depth
UNIT_H = 29.5 + 3  # 32.5mm internal height

WALL = 2.5
CORNER_R = 3

EXT_W = UNIT_W + 2 * WALL
EXT_D = UNIT_D + 2 * WALL
EXT_H = UNIT_H + WALL

print(f"Decimator MD-HX Enclosure")
print(f"Internal: {UNIT_W:.1f}×{UNIT_D:.1f}×{UNIT_H:.1f}mm")
print(f"External: {EXT_W:.1f}×{EXT_D:.1f}×{EXT_H:.1f}mm")

# Create base enclosure
enclosure = (cq.Workplane("XY")
    .box(EXT_W, EXT_D, EXT_H, centered=False)
    .edges("|Z")
    .fillet(CORNER_R)
    .faces(">Z")
    .shell(-WALL)
)

# === FRONT PANEL - LCD window + control buttons + inputs ===
# LCD display window (centered, upper area)
enclosure = (enclosure
    .faces("<Y")
    .workplane(centerOption="CenterOfBoundBox")
    .center(0, EXT_H/4)
    .rect(50, 15)  # LCD viewing window
    .cutThruAll()
)

# Control buttons below LCD (4 buttons: Menu, Up, Down, Enter)
button_positions = [-15, -5, 5, 15]
for x_offset in button_positions:
    enclosure = (enclosure
        .faces("<Y")
        .workplane(centerOption="CenterOfBoundBox")
        .center(x_offset, -2)
        .circle(2.5)  # Button access holes
        .cutThruAll()
    )

# SDI IN 1 (BNC - left)
enclosure = (enclosure
    .faces("<Y")
    .workplane(centerOption="CenterOfBoundBox")
    .center(-EXT_W/3, -EXT_H/3)
    .circle(6.5)
    .cutThruAll()
)

# SDI IN 2 (BNC - center-left)
enclosure = (enclosure
    .faces("<Y")
    .workplane(centerOption="CenterOfBoundBox")
    .center(-EXT_W/6, -EXT_H/3)
    .circle(6.5)
    .cutThruAll()
)

# HDMI IN (center-right)
enclosure = (enclosure
    .faces("<Y")
    .workplane(centerOption="CenterOfBoundBox")
    .center(EXT_W/6, -EXT_H/3)
    .rect(16, 6)
    .cutThruAll()
)

# === BACK PANEL - Outputs + Power ===
# SDI OUT 1 (BNC - left)
enclosure = (enclosure
    .faces(">Y")
    .workplane(centerOption="CenterOfBoundBox")
    .center(-EXT_W/4, 0)
    .circle(6.5)
    .cutThruAll()
)

# SDI OUT 2 (BNC - center-left)
enclosure = (enclosure
    .faces(">Y")
    .workplane(centerOption="CenterOfBoundBox")
    .center(-EXT_W/12, 0)
    .circle(6.5)
    .cutThruAll()
)

# HDMI OUT (center-right)
enclosure = (enclosure
    .faces(">Y")
    .workplane(centerOption="CenterOfBoundBox")
    .center(EXT_W/8, 0)
    .rect(16, 6)
    .cutThruAll()
)

# DC Power (right side)
enclosure = (enclosure
    .faces(">Y")
    .workplane(centerOption="CenterOfBoundBox")
    .center(EXT_W/3, 0)
    .circle(4.5)  # DC barrel jack
    .cutThruAll()
)

# === SIDE VENTILATION - Extensive cooling needed ===
# Left side: Ventilation grid (4x6)
for i in range(-1, 3):
    for j in range(-2, 4):
        enclosure = (enclosure
            .faces("<X")
            .workplane(centerOption="CenterOfBoundBox")
            .center(i * 8, j * 6)
            .circle(2.5)
            .cutThruAll()
        )

# Right side: Ventilation grid (4x6)
for i in range(-1, 3):
    for j in range(-2, 4):
        enclosure = (enclosure
            .faces(">X")
            .workplane(centerOption="CenterOfBoundBox")
            .center(i * 8, j * 6)
            .circle(2.5)
            .cutThruAll()
        )

# === TOP EDGES - Chamfer ===
enclosure = (enclosure
    .faces(">Z")
    .edges()
    .chamfer(0.5)
)

# === BOTTOM - Mounting feet with M3 holes ===
foot_r = 6
foot_h = 3

for x_sign in [-1, 1]:
    for y_sign in [-1, 1]:
        x_pos = x_sign * (EXT_W/2 - 10)
        y_pos = y_sign * (EXT_D/2 - 10)

        foot = (cq.Workplane("XY")
            .workplane(offset=0)
            .center(x_pos, y_pos)
            .circle(foot_r)
            .extrude(-foot_h)
        )
        enclosure = enclosure.union(foot)

        enclosure = (enclosure
            .faces("<Z")
            .workplane(centerOption="CenterOfBoundBox")
            .center(x_pos, y_pos)
            .circle(1.6)
            .cutThruAll()
        )

# === LABEL RECESS ===
enclosure = (enclosure
    .faces(">Z")
    .workplane()
    .rect(EXT_W - 10, 10)
    .cutBlind(-0.5)
)

# Export
output_path = '/Users/you/projects/av-enclosures/exports/decimator_mdx_case.stl'
cq.exporters.export(enclosure, output_path)

print(f"\n✓ Saved: decimator_mdx_case.stl")
print(f"\n=== FEATURES ===")
print("Front: LCD window, 4× buttons, 2× SDI IN, 1× HDMI IN")
print("Back: 2× SDI OUT, 1× HDMI OUT, 1× DC power")
print("Sides: Extensive ventilation (4×6 grids)")
print("Bottom: 4× mounting feet with M3 holes")
print(f"\n=== PRINT SPECS ===")
print(f"Size: {EXT_W:.0f}×{EXT_D:.0f}×{EXT_H:.0f}mm")
print("Time: ~2 hours")
