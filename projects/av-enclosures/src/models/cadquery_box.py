#!/usr/bin/env python3
"""
CadQuery hollow box - clean and simple
"""

import cadquery as cq

# Dimensions (mm)
EW, ED, EH = 146.0, 102.5, 116.0
WALL = 3.0

print(f"Creating hollow enclosure with CadQuery...")

# Create hollow box body (open top)
body = (cq.Workplane("XY")
    .box(EW, ED, EH, centered=False)
    .faces(">Z")  # Select top face
    .shell(-WALL)  # Hollow out with wall thickness
)

# Export body
cq.exporters.export(body, '/Users/you/projects/av-enclosures/exports/body_cq.stl')
print("✓ Saved: body_cq.stl")

# Create lid with lip
lid_height = 10
lip_depth = 5
lip_clearance = 0.5

lid = (cq.Workplane("XY")
    .box(EW, ED, lid_height, centered=False)
)

# Add lip underneath
lip = (cq.Workplane("XY")
    .workplane(offset=-lip_depth)
    .box(EW - 2*WALL - lip_clearance,
         ED - 2*WALL - lip_clearance,
         lip_depth,
         centered=False)
    .translate((WALL + lip_clearance/2, WALL + lip_clearance/2, 0))
)

lid = lid.union(lip)

cq.exporters.export(lid, '/Users/you/projects/av-enclosures/exports/lid_cq.stl')
print("✓ Saved: lid_cq.stl")

print(f"\n=== READY ===")
print(f"Files: body_cq.stl ({EW}×{ED}×{EH}mm)")
print(f"       lid_cq.stl ({EW}×{ED}×{lid_height}mm)")
print("\nLoad into OrcaSlicer and slice!")
