#!/usr/bin/env python3
"""
Blackmagic Micro Converter BiDirectional SDI/HDMI 12G - Custom Enclosure

Unit dimensions: 76.5mm W × 45.8mm D × 24.8mm H
Actual connector layout:
- Front: SDI IN (BNC), SDI OUT (BNC), HDMI
- Back: USB-C power
- Side: Status LEDs visible through slot
"""

import cadquery as cq

# Blackmagic unit dimensions (mm) + clearance
UNIT_W = 76.5 + 3  # 79.5mm internal width (1.5mm clearance per side)
UNIT_D = 45.8 + 3  # 48.8mm internal depth
UNIT_H = 24.8 + 3  # 27.8mm internal height

WALL = 2.5  # Wall thickness
CORNER_R = 3  # Corner radius

# External dimensions
EXT_W = UNIT_W + 2 * WALL
EXT_D = UNIT_D + 2 * WALL
EXT_H = UNIT_H + WALL  # Open top for access

print(f"Blackmagic 12G Enclosure")
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

# === FRONT PANEL - Connector cutouts ===
# BNC connectors: 12mm diameter, spaced across width
# HDMI: 15mm W × 5mm H rectangular

front_y = 0
bnc_z = UNIT_H / 2 + WALL  # Center height

# SDI IN (left side)
enclosure = (enclosure
    .faces("<Y")
    .workplane(centerOption="CenterOfBoundBox")
    .center(-EXT_W/4, 0)
    .circle(6.5)  # 13mm diameter BNC hole
    .cutThruAll()
)

# SDI OUT (center-left)
enclosure = (enclosure
    .faces("<Y")
    .workplane(centerOption="CenterOfBoundBox")
    .center(-EXT_W/8, 0)
    .circle(6.5)
    .cutThruAll()
)

# HDMI (center-right) - rectangular
enclosure = (enclosure
    .faces("<Y")
    .workplane(centerOption="CenterOfBoundBox")
    .center(EXT_W/6, 0)
    .rect(16, 6)
    .cutThruAll()
)

# === BACK PANEL - USB-C Power ===
enclosure = (enclosure
    .faces(">Y")
    .workplane(centerOption="CenterOfBoundBox")
    .rect(10, 4)  # USB-C cutout
    .cutThruAll()
)

# === SIDE VENTILATION - Status LED window + airflow ===
# Left side: LED viewing slot
enclosure = (enclosure
    .faces("<X")
    .workplane(centerOption="CenterOfBoundBox")
    .center(0, EXT_H/4)
    .rect(EXT_D * 0.6, 3)  # Horizontal slot for LEDs
    .cutThruAll()
)

# Right side: Ventilation holes (3x4 grid)
for i in range(-1, 2):
    for j in range(-1, 3):
        enclosure = (enclosure
            .faces(">X")
            .workplane(centerOption="CenterOfBoundBox")
            .center(i * 10, j * 6)
            .circle(2)
            .cutThruAll()
        )

# === TOP EDGES - Chamfer for easier access ===
enclosure = (enclosure
    .faces(">Z")
    .edges()
    .chamfer(0.5)
)

# === BOTTOM - Mounting feet with M3 screw holes ===
foot_r = 6
foot_h = 3

for x_sign in [-1, 1]:
    for y_sign in [-1, 1]:
        x_pos = x_sign * (EXT_W/2 - 8)
        y_pos = y_sign * (EXT_D/2 - 8)

        # Add cylindrical foot
        foot = (cq.Workplane("XY")
            .workplane(offset=0)
            .center(x_pos, y_pos)
            .circle(foot_r)
            .extrude(-foot_h)
        )
        enclosure = enclosure.union(foot)

        # Add M3 screw hole through foot
        enclosure = (enclosure
            .faces("<Z")
            .workplane(centerOption="CenterOfBoundBox")
            .center(x_pos, y_pos)
            .circle(1.6)  # M3 screw clearance
            .cutThruAll()
        )

# === LABEL RECESS - Top surface ===
enclosure = (enclosure
    .faces(">Z")
    .workplane()
    .rect(EXT_W - 10, 8)
    .cutBlind(-0.5)  # 0.5mm deep recess for label
)

# Export
output_path = '/Users/you/projects/av-enclosures/exports/blackmagic_12g_case.stl'
cq.exporters.export(enclosure, output_path)

print(f"\n✓ Saved: blackmagic_12g_case.stl")
print(f"\n=== FEATURES ===")
print("Front: 2× BNC (SDI), 1× HDMI cutout")
print("Back: USB-C power port")
print("Left side: LED viewing slot")
print("Right side: Ventilation holes")
print("Bottom: 4× mounting feet with M3 holes")
print("Top: Open access + label recess")
print(f"\n=== PRINT SPECS ===")
print(f"Size: {EXT_W:.0f}×{EXT_D:.0f}×{EXT_H:.0f}mm")
print("Material: PLA or PETG")
print("Layer: 0.2mm")
print("Infill: 20%")
print("Walls: 3 perimeters")
print("Support: None")
print("Time: ~1.5 hours")
