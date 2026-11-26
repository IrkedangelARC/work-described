#!/bin/bash
# Build follow-eyes (ARC Follow's detector). Output: follow/build/follow-eyes
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$HERE/build"
swiftc -O -o "$HERE/build/follow-eyes" "$HERE/eyes/main.swift" -framework Vision -framework ImageIO
echo "built: $HERE/build/follow-eyes"
