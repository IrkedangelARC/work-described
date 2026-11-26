#!/bin/zsh
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

# ARC Style token core must be byte-identical in both Swift apps (the layout
# chains live in ARCTheme+Layout.swift per app). Run before a release.
A="$HOME/projects/arc-capture/ArcCapture/Theme/ARCTheme.swift"
B="$HOME/projects/arc-presenter/ArcPresenter/Theme/ARCTheme.swift"
if diff -q "$A" "$B" >/dev/null; then echo "ARCTheme token core in sync"; else echo "ARCTheme token core DIFFERS:"; diff "$A" "$B"; exit 1; fi
