#!/usr/bin/env python3
"""
AV Equipment Enclosure - 3-Unit Combo
Designed for Creality K1C (220×220×250mm build volume)
Houses: Decimator MD-HX, Blackmagic Micro Converter 12G, Shure X2U/MVX2U

Author: ARC Event Productions
"""

from solid2 import *
from solid2.extensions.bosl2 import *
import numpy as np

# ========== UNIT DIMENSIONS (mm) ==========
# Add 2mm clearance per side for easy fit

DECIMATOR = {
    'w': 79.5 + 4,  # 83.5mm with clearance
    'd': 123 + 4,   # 127mm with clearance
    'h': 29.5 + 4,  # 33.5mm with clearance
}

BLACKMAGIC = {
    'w': 76.5 + 4,  # 80.5mm with clearance
    'd': 45.8 + 4,  # 49.8mm with clearance
    'h': 24.8 + 4,  # 28.8mm with clearance
}

SHURE = {
    'l': 100 + 4,   # 104mm with clearance
    'dia': 28 + 2,  # 30mm diameter with clearance
}

# ========== ENCLOSURE PARAMETERS ==========
WALL_THICKNESS = 3.0  # 3mm walls for strength
VENT_HOLE_DIA = 4.0   # 4mm ventilation holes
VENT_SPACING = 8.0    # 8mm spacing between vent holes
CORNER_RADIUS = 4.0   # Rounded corners

# Layout: Stack vertically (fits K1C better than side-by-side)
INTERNAL_WIDTH = max(DECIMATOR['d'], BLACKMAGIC['d'], SHURE['l']) + 10
INTERNAL_DEPTH = max(DECIMATOR['w'], BLACKMAGIC['w']) + 10
INTERNAL_HEIGHT = (DECIMATOR['h'] + BLACKMAGIC['h'] + SHURE['dia'] +
                   3 * 5)  # 5mm spacing between units

# External dimensions
EXTERNAL_WIDTH = INTERNAL_WIDTH + 2 * WALL_THICKNESS
EXTERNAL_DEPTH = INTERNAL_DEPTH + 2 * WALL_THICKNESS
EXTERNAL_HEIGHT = INTERNAL_HEIGHT + 2 * WALL_THICKNESS

print(f"Enclosure external dimensions: {EXTERNAL_WIDTH:.1f} × {EXTERNAL_DEPTH:.1f} × {EXTERNAL_HEIGHT:.1f} mm")
print(f"K1C build volume: 220 × 220 × 250 mm")
print(f"Fits on K1C: {EXTERNAL_WIDTH < 220 and EXTERNAL_DEPTH < 220 and EXTERNAL_HEIGHT < 250}")


def rounded_box(width, depth, height, radius):
    """Create a box with rounded corners"""
    return hull()(
        translate([radius, radius, 0])(cylinder(h=height, r=radius)),
        translate([width-radius, radius, 0])(cylinder(h=height, r=radius)),
        translate([radius, depth-radius, 0])(cylinder(h=height, r=radius)),
        translate([width-radius, depth-radius, 0])(cylinder(h=height, r=radius)),
    )


def ventilation_array(width, depth, cols=5, rows=3):
    """Create array of ventilation holes"""
    holes = []
    spacing_x = width / (cols + 1)
    spacing_y = depth / (rows + 1)

    for i in range(1, cols + 1):
        for j in range(1, rows + 1):
            hole = translate([i * spacing_x, j * spacing_y, -1])(
                cylinder(h=WALL_THICKNESS + 2, d=VENT_HOLE_DIA)
            )
            holes.append(hole)

    return union()(*holes)


def cable_port(diameter, position):
    """Create a cable pass-through port with strain relief"""
    return translate(position)(
        union()(
            # Main hole
            rotate([90, 0, 0])(
                cylinder(h=WALL_THICKNESS + 2, d=diameter)
            ),
            # Strain relief chamfer
            rotate([90, 0, 0])(
                translate([0, 0, WALL_THICKNESS])(
                    cylinder(h=2, d1=diameter, d2=diameter + 2)
                )
            )
        )
    )


def main_enclosure():
    """Create the main enclosure body"""

    # Outer shell
    outer = rounded_box(EXTERNAL_WIDTH, EXTERNAL_DEPTH, EXTERNAL_HEIGHT, CORNER_RADIUS)

    # Inner cavity (hollowed out)
    inner = translate([WALL_THICKNESS, WALL_THICKNESS, WALL_THICKNESS])(
        rounded_box(INTERNAL_WIDTH, INTERNAL_DEPTH, INTERNAL_HEIGHT, CORNER_RADIUS - 1)
    )

    # Base body
    body = difference()(
        outer,
        inner
    )

    # Add ventilation to top panel
    top_vents = translate([0, 0, EXTERNAL_HEIGHT - WALL_THICKNESS])(
        ventilation_array(EXTERNAL_WIDTH, EXTERNAL_DEPTH, cols=8, rows=4)
    )

    # Add ventilation to side panels
    left_vents = rotate([90, 0, 90])(
        translate([0, 0, -1])(
            ventilation_array(EXTERNAL_DEPTH, EXTERNAL_HEIGHT - 20, cols=6, rows=3)
        )
    )

    right_vents = translate([EXTERNAL_WIDTH, 0, 0])(
        rotate([90, 0, 90])(
            translate([0, 0, -1])(
                ventilation_array(EXTERNAL_DEPTH, EXTERNAL_HEIGHT - 20, cols=6, rows=3)
            )
        )
    )

    # Cable ports on back panel
    # Decimator connections (SDI, HDMI, Power)
    decimator_ports = [
        cable_port(12, [20, EXTERNAL_DEPTH + 1, EXTERNAL_HEIGHT - 15]),  # BNC
        cable_port(12, [35, EXTERNAL_DEPTH + 1, EXTERNAL_HEIGHT - 15]),  # BNC
        cable_port(10, [50, EXTERNAL_DEPTH + 1, EXTERNAL_HEIGHT - 15]),  # HDMI
        cable_port(8, [65, EXTERNAL_DEPTH + 1, EXTERNAL_HEIGHT - 15]),   # Power
    ]

    # Blackmagic ports (SDI, HDMI, USB-C)
    blackmagic_ports = [
        cable_port(12, [20, EXTERNAL_DEPTH + 1, 50]),  # BNC
        cable_port(10, [35, EXTERNAL_DEPTH + 1, 50]),  # HDMI
        cable_port(8, [50, EXTERNAL_DEPTH + 1, 50]),   # USB-C power
    ]

    # Shure ports (XLR, USB, Headphone)
    shure_ports = [
        cable_port(22, [20, EXTERNAL_DEPTH + 1, 20]),  # XLR input (larger)
        cable_port(10, [45, EXTERNAL_DEPTH + 1, 20]),  # USB output
        cable_port(8, [60, EXTERNAL_DEPTH + 1, 20]),   # Headphone jack
    ]

    # Combine all
    enclosure = difference()(
        body,
        top_vents,
        left_vents,
        right_vents,
        *decimator_ports,
        *blackmagic_ports,
        *shure_ports
    )

    return enclosure


def lid():
    """Create removable lid with labels"""

    lid_outer = rounded_box(EXTERNAL_WIDTH, EXTERNAL_DEPTH, 10, CORNER_RADIUS)

    # Lip that fits into top opening
    lip = translate([WALL_THICKNESS + 0.5, WALL_THICKNESS + 0.5, -5])(
        rounded_box(INTERNAL_WIDTH - 1, INTERNAL_DEPTH - 1, 5, CORNER_RADIUS - 1)
    )

    # Mounting screw holes
    screw_holes = [
        translate([10, 10, -1])(cylinder(h=12, d=3.5)),
        translate([EXTERNAL_WIDTH - 10, 10, -1])(cylinder(h=12, d=3.5)),
        translate([10, EXTERNAL_DEPTH - 10, -1])(cylinder(h=12, d=3.5)),
        translate([EXTERNAL_WIDTH - 10, EXTERNAL_DEPTH - 10, -1])(cylinder(h=12, d=3.5)),
    ]

    # Label text (embossed)
    label_text = translate([EXTERNAL_WIDTH / 2, EXTERNAL_DEPTH / 2, 8])(
        linear_extrude(height=2)(
            text("ARC", size=12, halign="center", valign="center")
        )
    )

    complete_lid = union()(
        difference()(
            union()(lid_outer, lip),
            *screw_holes
        ),
        label_text
    )

    return complete_lid


def mounting_feet():
    """Create rubber feet mounting points"""
    foot = cylinder(h=4, d=15)
    screw_hole = translate([0, 0, -1])(cylinder(h=6, d=4))

    single_foot = difference()(foot, screw_hole)

    feet = [
        translate([12, 12, 0])(single_foot),
        translate([EXTERNAL_WIDTH - 12, 12, 0])(single_foot),
        translate([12, EXTERNAL_DEPTH - 12, 0])(single_foot),
        translate([EXTERNAL_WIDTH - 12, EXTERNAL_DEPTH - 12, 0])(single_foot),
    ]

    return union()(*feet)


# ========== GENERATE MODELS ==========

if __name__ == "__main__":
    print("\nGenerating 3D models...")

    # Main enclosure with feet
    main = union()(
        main_enclosure(),
        mounting_feet()
    )

    # Save main body
    main.save_as_scad("/Users/you/projects/av-enclosures/exports/enclosure_body.scad")
    print("✓ Saved: enclosure_body.scad")

    # Save lid separately
    lid_model = lid()
    lid_model.save_as_scad("/Users/you/projects/av-enclosures/exports/enclosure_lid.scad")
    print("✓ Saved: enclosure_lid.scad")

    print("\nNext steps:")
    print("1. Open .scad files in OpenSCAD")
    print("2. Render (F6)")
    print("3. Export as STL")
    print("4. Slice for K1C with 0.2mm layer height, 20% infill, 3 perimeters")
