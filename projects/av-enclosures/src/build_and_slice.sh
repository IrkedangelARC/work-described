#!/bin/bash
# Complete automated workflow: Generate → Slice → Ready to print
# Usage: ./build_and_slice.sh [unit_name|--all]

PROJECT_DIR="$(dirname "$0")"
cd "$PROJECT_DIR"

echo "=== AV Enclosure Automated Build ==="
echo

# Step 1: Generate STL files
echo "📐 Step 1: Generating STL files..."
if [ "$1" == "--all" ]; then
    python3 generate_all.py --all
elif [ -n "$1" ]; then
    python3 generate_all.py --unit "$1"
else
    echo "Usage:"
    echo "  $0 --all                                 # Build all enclosures"
    echo "  $0 blackmagic_micro_converter_12g        # Build specific unit"
    exit 1
fi

if [ $? -ne 0 ]; then
    echo "❌ STL generation failed"
    exit 1
fi

echo
echo "✓ STL generation complete"
echo

# Step 2: Slice to G-code
echo "🔪 Step 2: Slicing to G-code..."
./auto_slice.sh --all

echo
echo "=== BUILD COMPLETE ==="
echo
echo "📁 G-code files ready in: exports/"
echo "📤 Upload to K1C: http://192.0.2.91"
echo
