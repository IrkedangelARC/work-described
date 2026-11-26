#!/usr/bin/env python3
"""
Manual hollow box construction - no boolean operations needed
Creates walls as separate faces, then merges into single mesh
"""

import numpy as np
from stl import mesh

# Dimensions (mm)
EW = 146.0  # External width
ED = 102.5  # External depth
EH = 116.0  # External height
W = 3.0     # Wall thickness

# Internal dimensions
IW = EW - 2*W
ID = ED - 2*W
IH = EH - W  # Top is open

print(f"Creating hollow enclosure: {EW}×{ED}×{EH}mm, wall={W}mm")

def create_wall(p1, p2, p3, p4, p5, p6, p7, p8):
    """Create a rectangular wall from 8 vertices (outer 4, inner 4)"""
    # Two triangles per face (front and back of wall)
    faces = []

    # Outer surface (2 triangles)
    faces.append([p1, p2, p3])
    faces.append([p1, p3, p4])

    # Inner surface (2 triangles, reversed winding)
    faces.append([p5, p7, p6])
    faces.append([p5, p8, p7])

    # Connect outer to inner (edges)
    # Bottom edge
    faces.append([p1, p5, p6])
    faces.append([p1, p6, p2])

    # Right edge
    faces.append([p2, p6, p7])
    faces.append([p2, p7, p3])

    # Top edge
    faces.append([p3, p7, p8])
    faces.append([p3, p8, p4])

    # Left edge
    faces.append([p4, p8, p5])
    faces.append([p4, p5, p1])

    return faces

# Define all vertices for 5-sided box (no top)
vertices = []
all_faces = []

# === BOTTOM WALL ===
# Outer corners (z=0)
bottom_outer = [
    [0, 0, 0],      # 0
    [EW, 0, 0],     # 1
    [EW, ED, 0],    # 2
    [0, ED, 0]      # 3
]
# Inner corners (z=W)
bottom_inner = [
    [W, W, W],          # 4
    [EW-W, W, W],       # 5
    [EW-W, ED-W, W],    # 6
    [W, ED-W, W]        # 7
]

# Bottom is just 2 faces - outer and inner
all_faces.extend([
    [0, 2, 1], [0, 3, 2],  # Outer bottom (facing down)
    [4, 5, 6], [4, 6, 7]   # Inner bottom (facing up)
])

# Connect outer bottom to inner bottom at edges
for i in range(4):
    next_i = (i + 1) % 4
    all_faces.append([i, bottom_inner[i], bottom_inner[next_i]])
    all_faces.append([i, bottom_inner[next_i], next_i])

vertices.extend(bottom_outer)
vertices.extend(bottom_inner)
base_idx = len(vertices)

# === FRONT WALL (Y=0) ===
front_outer = [
    [0, 0, 0],      # Already defined
    [EW, 0, 0],
    [EW, 0, EH],    # 8
    [0, 0, EH]      # 9
]
front_inner = [
    [W, W, W],      # Already defined
    [EW-W, W, W],
    [EW-W, W, EH],  # 10
    [W, W, EH]      # 11
]

# Only add new top vertices
vertices.extend([[EW, 0, EH], [0, 0, EH], [EW-W, W, EH], [W, W, EH]])

# Front wall faces (using existing bottom vertices)
all_faces.extend([
    [0, base_idx, 1], [0, base_idx+1, base_idx],      # Outer
    [4, base_idx+3, base_idx+2], [4, base_idx+2, 5],  # Inner
    [0, 4, base_idx+3], [0, base_idx+3, base_idx+1],  # Left edge
    [1, base_idx, base_idx+2], [1, base_idx+2, 5],    # Right edge
    [base_idx, base_idx+3, base_idx+2], [base_idx, base_idx+2, base_idx]  # Top edge
])

base_idx = len(vertices)

# === BACK WALL (Y=ED) ===
vertices.extend([[EW, ED, EH], [0, ED, EH], [EW-W, ED-W, EH], [W, ED-W, EH]])

all_faces.extend([
    [2, 3, base_idx], [3, base_idx+1, base_idx],
    [6, base_idx+2, base_idx+3], [6, base_idx+3, 7],
    [2, base_idx, base_idx+2], [2, base_idx+2, 6],
    [3, 7, base_idx+3], [3, base_idx+3, base_idx+1],
    [base_idx, base_idx+3, base_idx+2], [base_idx, base_idx+2, base_idx]
])

base_idx = len(vertices)

# === LEFT WALL (X=0) ===
# Uses vertices: 0,3 (bottom outer), 4,7 (bottom inner), 9,13 (top outer), 11,15 (top inner)
# These are already defined, just add faces
all_faces.extend([
    [0, 3, 9], [3, 13, 9],
    [4, 11, 15], [4, 15, 7],
    [0, 9, 11], [0, 11, 4],
    [3, 7, 15], [3, 15, 13],
    [9, 13, 15], [9, 15, 11]
])

# === RIGHT WALL (X=EW) ===
all_faces.extend([
    [1, 8, 2], [2, 8, 12],
    [5, 6, 14], [5, 14, 10],
    [1, 5, 10], [1, 10, 8],
    [2, 12, 14], [2, 14, 6],
    [8, 10, 14], [8, 14, 12]
])

# Convert to numpy array
vertices = np.array(vertices)
faces = np.array(all_faces)

print(f"Generated {len(vertices)} vertices, {len(faces)} faces")

# Create mesh
enclosure_mesh = mesh.Mesh(np.zeros(faces.shape[0], dtype=mesh.Mesh.dtype))
for i, face in enumerate(faces):
    for j in range(3):
        enclosure_mesh.vectors[i][j] = vertices[face[j]]

# Save
enclosure_mesh.save('/Users/you/projects/av-enclosures/exports/enclosure_body_hollow.stl')
print("✓ Saved: enclosure_body_hollow.stl")

# === CREATE LID (simple solid box with lip) ===
lid_height = 10
lip_depth = 5

lid_verts = []
lid_faces = []

# Outer lid box
for z in [0, lid_height]:
    for y in [0, ED]:
        for x in [0, EW]:
            lid_verts.append([x, y, z])

# Lid outer faces
lid_faces = [
    [0,2,1], [0,3,2],  # Bottom
    [4,5,6], [4,6,7],  # Top
    [0,1,5], [0,5,4],  # Front
    [2,3,7], [2,7,6],  # Back
    [0,4,7], [0,7,3],  # Left
    [1,2,6], [1,6,5]   # Right
]

# Add lip (extends down from bottom)
lip_w = IW - 1
lip_d = ID - 1
lip_offset_x = (EW - lip_w) / 2
lip_offset_y = (ED - lip_d) / 2

base = len(lid_verts)
for z in [-lip_depth, 0]:
    for y in [lip_offset_y, lip_offset_y + lip_d]:
        for x in [lip_offset_x, lip_offset_x + lip_w]:
            lid_verts.append([x, y, z])

# Lip faces
lid_faces.extend([
    [base+0, base+1, base+2], [base+0, base+2, base+3],  # Bottom of lip
    [base+4, base+6, base+5], [base+4, base+7, base+6],  # Top of lip (connects to lid bottom)
    [base+0, base+4, base+5], [base+0, base+5, base+1],  # Front
    [base+2, base+6, base+7], [base+2, base+7, base+3],  # Back
    [base+0, base+3, base+7], [base+0, base+7, base+4],  # Left
    [base+1, base+5, base+6], [base+1, base+6, base+2]   # Right
])

lid_verts = np.array(lid_verts)
lid_faces = np.array(lid_faces)

lid_mesh = mesh.Mesh(np.zeros(lid_faces.shape[0], dtype=mesh.Mesh.dtype))
for i, face in enumerate(lid_faces):
    for j in range(3):
        lid_mesh.vectors[i][j] = lid_verts[face[j]]

lid_mesh.save('/Users/you/projects/av-enclosures/exports/enclosure_lid_hollow.stl')
print("✓ Saved: enclosure_lid_hollow.stl")

print("\n=== READY TO SLICE ===")
print("Load these files into OrcaSlicer:")
print("  - enclosure_body_hollow.stl")
print("  - enclosure_lid_hollow.stl")
