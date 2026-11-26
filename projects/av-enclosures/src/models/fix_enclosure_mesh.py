#!/usr/bin/env python3
"""
Fixed STL generation with proper manifold meshes
Uses trimesh for watertight geometry
"""

import trimesh
import numpy as np

# Dimensions (mm)
EXTERNAL_WIDTH = 146.0
EXTERNAL_DEPTH = 102.5
EXTERNAL_HEIGHT = 116.0
WALL = 3.0

INTERNAL_WIDTH = EXTERNAL_WIDTH - 2 * WALL
INTERNAL_DEPTH = EXTERNAL_DEPTH - 2 * WALL
INTERNAL_HEIGHT = EXTERNAL_HEIGHT - WALL  # Open top

print(f"Generating enclosure: {EXTERNAL_WIDTH}×{EXTERNAL_DEPTH}×{EXTERNAL_HEIGHT}mm")

# Create outer box
outer_box = trimesh.creation.box(
    extents=[EXTERNAL_WIDTH, EXTERNAL_DEPTH, EXTERNAL_HEIGHT]
)

# Create inner cavity (slightly smaller, positioned at bottom)
inner_box = trimesh.creation.box(
    extents=[INTERNAL_WIDTH, INTERNAL_DEPTH, INTERNAL_HEIGHT]
)

# Position inner box: centered XY, raised by WALL thickness
inner_box.apply_translation([0, 0, WALL/2])

# Boolean difference to create hollow enclosure
try:
    body = outer_box.difference(inner_box, engine='blender')
except:
    # Fallback if blender not available
    print("Using scad engine for boolean operations...")
    body = outer_box.difference(inner_box, engine='scad')

# Save body
body.export('/Users/you/projects/av-enclosures/exports/enclosure_body_v2.stl')
print("✓ Saved: enclosure_body_v2.stl")

# Create lid (simple box with lip)
lid_outer = trimesh.creation.box(
    extents=[EXTERNAL_WIDTH, EXTERNAL_DEPTH, 10]
)

# Lip that fits inside opening
lip = trimesh.creation.box(
    extents=[INTERNAL_WIDTH - 1, INTERNAL_DEPTH - 1, 5]
)
lip.apply_translation([0, 0, -2.5])  # Offset downward

lid = lid_outer.union(lip, engine='scad')
lid.export('/Users/you/projects/av-enclosures/exports/enclosure_lid_v2.stl')
print("✓ Saved: enclosure_lid_v2.stl")

print("\n=== STATS ===")
print(f"Body: {body.is_watertight} watertight, {len(body.faces)} faces")
print(f"Lid: {lid.is_watertight} watertight, {len(lid.faces)} faces")
print("\n=== READY FOR K1C ===")
print("Load enclosure_body_v2.stl and enclosure_lid_v2.stl into OrcaSlicer")
