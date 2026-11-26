#!/bin/bash
# Auto-slice STL files using OrcaSlicer CLI
# Usage: ./auto_slice.sh [filename.stl] or ./auto_slice.sh --all

ORCA="/Applications/OrcaSlicer.app/Contents/MacOS/orcaslicer-console"
CONFIG_DIR="$HOME/Library/Application Support/OrcaSlicer"
PRINTER_PRESET="Creality K1C 0.4 nozzle"
FILAMENT_PRESET="Creality Generic PLA"
PROCESS_PRESET="0.20mm Standard @Creality K1C"

EXPORTS_DIR="$(dirname "$0")/exports"

if [ ! -f "$ORCA" ]; then
    echo "❌ OrcaSlicer CLI not found at: $ORCA"
    echo "Checking alternate location..."
    ORCA="/Applications/OrcaSlicer.app/Contents/MacOS/OrcaSlicer"
fi

if [ ! -f "$ORCA" ]; then
    echo "❌ OrcaSlicer not found. Install OrcaSlicer first."
    exit 1
fi

slice_file() {
    local stl_file="$1"
    local base_name=$(basename "$stl_file" .stl)
    local output_gcode="${EXPORTS_DIR}/${base_name}_AUTO.gcode"

    echo "🔄 Slicing: $base_name"

    "$ORCA" \
        --export-gcode \
        --load "$stl_file" \
        --output "$output_gcode" \
        --printer "$PRINTER_PRESET" \
        --filament "$FILAMENT_PRESET" \
        --print-settings "$PROCESS_PRESET" \
        2>/dev/null

    if [ $? -eq 0 ] && [ -f "$output_gcode" ]; then
        local size=$(du -h "$output_gcode" | awk '{print $1}')
        echo "  ✓ Generated: $output_gcode ($size)"
    else
        echo "  ❌ Failed to slice $base_name"
        echo "  Trying manual fallback..."
        open -a OrcaSlicer "$stl_file"
    fi
}

if [ "$1" == "--all" ]; then
    echo "=== Auto-slicing all STL files ==="
    for stl in "$EXPORTS_DIR"/*.stl; do
        if [ -f "$stl" ]; then
            slice_file "$stl"
        fi
    done
elif [ -n "$1" ]; then
    if [ -f "$1" ]; then
        slice_file "$1"
    else
        echo "❌ File not found: $1"
        exit 1
    fi
else
    echo "Usage:"
    echo "  $0 exports/blackmagic_12g_case.stl    # Slice single file"
    echo "  $0 --all                               # Slice all STL files"
fi
