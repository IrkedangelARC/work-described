#!/usr/bin/env python3
"""
Remove white background from image and make it transparent
"""

from PIL import Image
import sys

def remove_white_background(input_path, output_path, threshold=240):
    """
    Remove white/light gray background from an image and make it transparent.

    Args:
        input_path: Path to input image
        output_path: Path to save output image
        threshold: Brightness threshold (0-255). Pixels brighter than this become transparent.
    """
    # Open the image
    img = Image.open(input_path)

    # Convert to RGBA if not already
    img = img.convert("RGBA")

    # Get pixel data
    datas = img.getdata()

    # Create new pixel data with transparency
    new_data = []
    for item in datas:
        # If pixel is close to white (all RGB values above threshold), make it transparent
        if item[0] > threshold and item[1] > threshold and item[2] > threshold:
            new_data.append((255, 255, 255, 0))  # Fully transparent
        else:
            new_data.append(item)  # Keep original pixel

    # Update image data
    img.putdata(new_data)

    # Save as PNG (supports transparency)
    img.save(output_path, "PNG")
    print(f"✓ Saved transparent image to: {output_path}")
    print(f"  Original size: {Image.open(input_path).size}")
    print(f"  Output size: {img.size}")

if __name__ == "__main__":
    input_file = "/Users/you/Desktop/arc_logo.png"
    output_file = "/Users/you/projects/media-tools/assets/arc_logo_transparent.png"

    print(f"Removing white background from: {input_file}")
    print(f"Threshold: 240 (pixels brighter than this become transparent)")
    print()

    remove_white_background(input_file, output_file, threshold=240)
