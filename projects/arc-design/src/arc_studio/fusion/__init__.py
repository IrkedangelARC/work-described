#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Fusion workflow — brand-aware template authoring and post-render derivation.

Bridges DaVinci Resolve Studio Fusion templates with ARC's downstream consumers:
  • arc-lower-thirds (Swift) — custom-skin backgrounds via ProRes 4444 + alpha
  • ATEM Media Pool            — PNG sequences for M/E keying
  • arc-keyer (luma)           — ProRes 4444 on solid black for camera-extension keying

Master renders live in fusion/renders/master/ as ProRes 4444 w/ alpha channel.
Derived variants land under fusion/renders/derived/{lower-thirds,atem-media,keyer-luma}/.
"""
