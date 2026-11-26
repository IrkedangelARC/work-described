#!/usr/bin/env python3
"""
Direct STL generation without OpenSCAD dependency
Uses numpy-stl for pure Python STL output
"""

import numpy as np
from stl import mesh

# Unit dimensions (mm) with clearance
DECIMATOR = {'w': 83.5, 'd': 127, 'h': 33.5}
BLACKMAGIC = {'w': 80.5, 'd': 49.8, 'h': 28.8}
SHURE = {'l': 104, 'dia': 30}

WALL = 3.0
INTERNAL_WIDTH = 140
INTERNAL_DEPTH = 96.5
INTERNAL_HEIGHT = 110

EXTERNAL_WIDTH = INTERNAL_WIDTH + 2 * WALL
EXTERNAL_DEPTH = INTERNAL_DEPTH + 2 * WALL
EXTERNAL_HEIGHT = INTERNAL_HEIGHT + 2 * WALL

def create_box_mesh(width, depth, height, wall_thickness):
    """Create a hollow box mesh"""
    vertices = []
    faces = []

    # Outer box vertices
    outer = [
        [0, 0, 0], [width, 0, 0], [width, depth, 0], [0, depth, 0],  # bottom
        [0, 0, height], [width, 0, height], [width, depth, height], [0, depth, height]  # top
    ]

    # Inner box vertices (hollowed)
    w = wall_thickness
    inner = [
        [w, w, w], [width-w, w, w], [width-w, depth-w, w], [w, depth-w, w],  # bottom
        [w, w, height], [width-w, w, height], [width-w, depth-w, height], [w, depth-w, height]  # top
    ]

    vertices.extend(outer)
    vertices.extend(inner)

    # Create faces for outer shell
    # Bottom face
    faces.extend([[0, 2, 1], [0, 3, 2]])
    # Top face
    faces.extend([[4, 5, 6], [4, 6, 7]])
    # Sides
    faces.extend([[0, 1, 5], [0, 5, 4]])  # front
    faces.extend([[1, 2, 6], [1, 6, 5]])  # right
    faces.extend([[2, 3, 7], [2, 7, 6]])  # back
    faces.extend([[3, 0, 4], [3, 4, 7]])  # left

    # Create faces for inner shell (reversed normals)
    offset = 8
    faces.extend([[offset+0, offset+1, offset+2], [offset+0, offset+2, offset+3]])
    faces.extend([[offset+4, offset+6, offset+5], [offset+4, offset+7, offset+6]])
    faces.extend([[offset+0, offset+4, offset+5], [offset+0, offset+5, offset+1]])
    faces.extend([[offset+1, offset+5, offset+6], [offset+1, offset+6, offset+2]])
    faces.extend([[offset+2, offset+6, offset+7], [offset+2, offset+7, offset+3]])
    faces.extend([[offset+3, offset+7, offset+4], [offset+3, offset+4, offset+0]])

    # Connect outer to inner at top opening
    for i in range(4):
        next_i = (i + 1) % 4
        faces.extend([
            [4+i, offset+4+i, offset+4+next_i],
            [4+i, offset+4+next_i, 4+next_i]
        ])

    vertices = np.array(vertices)
    faces = np.array(faces)

    # Create mesh
    box_mesh = mesh.Mesh(np.zeros(faces.shape[0], dtype=mesh.Mesh.dtype))
    for i, face in enumerate(faces):
        for j in range(3):
            box_mesh.vectors[i][j] = vertices[face[j]]

    return box_mesh

def create_cylinder_mesh(radius, height, segments=32):
    """Create a cylinder mesh for cable holes"""
    vertices = []
    faces = []

    # Bottom center
    vertices.append([0, 0, 0])
    # Top center
    vertices.append([0, 0, height])

    # Bottom circle
    for i in range(segments):
        angle = 2 * np.pi * i / segments
        x = radius * np.cos(angle)
        y = radius * np.sin(angle)
        vertices.append([x, y, 0])

    # Top circle
    for i in range(segments):
        angle = 2 * np.pi * i / segments
        x = radius * np.cos(angle)
        y = radius * np.sin(angle)
        vertices.append([x, y, height])

    # Bottom cap faces
    for i in range(segments):
        next_i = (i + 1) % segments
        faces.append([0, 2 + i, 2 + next_i])

    # Top cap faces
    for i in range(segments):
        next_i = (i + 1) % segments
        faces.append([1, 2 + segments + next_i, 2 + segments + i])

    # Side faces
    for i in range(segments):
        next_i = (i + 1) % segments
        bottom_i = 2 + i
        bottom_next = 2 + next_i
        top_i = 2 + segments + i
        top_next = 2 + segments + next_i

        faces.append([bottom_i, top_i, top_next])
        faces.append([bottom_i, top_next, bottom_next])

    vertices = np.array(vertices)
    faces = np.array(faces)

    cyl_mesh = mesh.Mesh(np.zeros(faces.shape[0], dtype=mesh.Mesh.dtype))
    for i, face in enumerate(faces):
        for j in range(3):
            cyl_mesh.vectors[i][j] = vertices[face[j]]

    return cyl_mesh

print(f"Creating enclosure: {EXTERNAL_WIDTH} × {EXTERNAL_DEPTH} × {EXTERNAL_HEIGHT} mm")
print(f"Fits K1C (220×220×250): {EXTERNAL_WIDTH < 220 and EXTERNAL_DEPTH < 220 and EXTERNAL_HEIGHT < 250}")

# Create main body
print("\nGenerating main enclosure body...")
body = create_box_mesh(EXTERNAL_WIDTH, EXTERNAL_DEPTH, EXTERNAL_HEIGHT, WALL)
body.save('/Users/you/projects/av-enclosures/exports/enclosure_body.stl')
print("✓ Saved: enclosure_body.stl")

# Create lid (10mm tall with lip)
print("Generating lid...")
lid = create_box_mesh(EXTERNAL_WIDTH, EXTERNAL_DEPTH, 10, WALL)
lid.save('/Users/you/projects/av-enclosures/exports/enclosure_lid.stl')
print("✓ Saved: enclosure_lid.stl")

print("\n=== PRINT SETTINGS FOR K1C ===")
print("Material: PLA or PETG")
print("Layer height: 0.2mm")
print("Infill: 20%")
print("Perimeters/walls: 3")
print("Supports: None needed")
print("Print time estimate: ~4-5 hours (body), ~1 hour (lid)")
print("\n=== CABLE PORT DIMENSIONS ===")
print("Decimator: 12mm (BNC ×2), 10mm (HDMI), 8mm (Power)")
print("Blackmagic: 12mm (BNC), 10mm (HDMI), 8mm (USB-C)")
print("Shure: 22mm (XLR), 10mm (USB), 8mm (3.5mm jack)")
print("\nDrill these ports after printing for precise fit.")
