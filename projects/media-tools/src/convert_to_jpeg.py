#!/usr/bin/env python3
"""
Convert all images in a folder to high-quality JPEG using ffmpeg
"""

import os
import subprocess
from pathlib import Path

def convert_to_jpeg(input_folder, output_folder=None):
    """
    Convert all images in input_folder to JPEG at highest quality.

    Args:
        input_folder: Path to folder containing images
        output_folder: Path to save converted images (default: same as input with _jpeg suffix)
    """
    input_path = Path(input_folder)

    if output_folder is None:
        output_folder = input_path.parent / f"{input_path.name}_jpeg"
    else:
        output_folder = Path(output_folder)

    # Create output folder if it doesn't exist
    output_folder.mkdir(parents=True, exist_ok=True)

    # Supported image formats
    image_extensions = ['.png', '.webp', '.jpg', '.jpeg', '.gif', '.bmp', '.tiff']

    # Find all images
    images = []
    for ext in image_extensions:
        images.extend(input_path.glob(f'*{ext}'))
        images.extend(input_path.glob(f'*{ext.upper()}'))

    if not images:
        print(f"No images found in {input_folder}")
        return

    print(f"Found {len(images)} images to convert")
    print(f"Output folder: {output_folder}")
    print()

    converted = 0
    skipped = 0

    for img_file in images:
        # Create output filename with .jpg extension
        output_file = output_folder / f"{img_file.stem}.jpg"

        # Skip if already a JPEG and we're outputting to same folder
        if img_file.suffix.lower() in ['.jpg', '.jpeg'] and output_folder == input_path:
            print(f"⏭ Skipping (already JPEG): {img_file.name}")
            skipped += 1
            continue

        print(f"Converting: {img_file.name} → {output_file.name}")

        try:
            # ffmpeg command for highest quality JPEG
            # -q:v 2 = highest quality (scale is 2-31, lower is better)
            subprocess.run([
                'ffmpeg',
                '-i', str(img_file),
                '-q:v', '2',  # Highest quality
                '-y',  # Overwrite output file if exists
                str(output_file)
            ], check=True, capture_output=True)

            converted += 1
            print(f"  ✓ Done")

        except subprocess.CalledProcessError as e:
            print(f"  ✗ Error: {e.stderr.decode()}")
        except FileNotFoundError:
            print("  ✗ Error: ffmpeg not found. Make sure it's installed (brew install ffmpeg)")
            return

    print()
    print(f"Conversion complete!")
    print(f"  Converted: {converted}")
    print(f"  Skipped: {skipped}")
    print(f"  Total: {len(images)}")


if __name__ == "__main__":
    import sys

    # Default to Desktop/screenshots if no argument provided
    if len(sys.argv) > 1:
        input_folder = sys.argv[1]
    else:
        input_folder = "/Users/you/Desktop/screenshots"

    print(f"Converting images from: {input_folder}")
    print()

    convert_to_jpeg(input_folder)
