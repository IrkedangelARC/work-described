//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// ARC Presenter's layout chain; the token core in ARCTheme.swift stays
/// identical to ARC Capture's.
extension ARCTheme {
    // MARK: Layout chain (the ARC layout law: one given, everything derived)
    // The GIVEN: the NEXT thumbnail width. The rail is built around it; the
    // preview column absorbs whatever the window leaves. Rails are FIXED
    // (PTZ instrument law): tools keep their geometry, the picture flexes.
    static let nextThumbW: CGFloat = 480
    static let nextThumbH: CGFloat = (nextThumbW * 9 / 16).rounded()      // 270
    static let nextThumbMinH: CGFloat = 96                                // NEXT may shrink to this on a short display (150 until the 1512x945 fit, 2026-09-23)
    static let railPad: CGFloat = 8                                       // rail edge to module
    static let railW: CGFloat = nextThumbW + 2 * modulePad + 2 * railPad + 2   // 514
    static let filmThumbH: CGFloat = 90                                   // filmstrip: one constant
    static let filmLabelH: CGFloat = 24
    /// Every footer section's content row: one height for all three boxes (they were 4 different heights with
    /// ragged tops, 2026-09-17). 52 for the 43 pt counter until the one-row footer of 2026-09-23.
    static let footerRowH: CGFloat = 38
    /// The slide counter: 28 pt bold mono (43 pt until 2026-09-23 took a whole row's height and width).
    static let footerCounter = Font.system(size: 28, weight: .bold, design: .monospaced)
    /// The counter's box, from the deck's own page count, fixed per deck so the arrows never move as the
    /// digits change: "367 / 367" is nine cells, 17 pt a cell at 28 pt bold mono (0.6 em).
    static func counterWidth(pages: Int) -> CGFloat {
        let cells = "\(max(1, pages)) / \(max(1, pages))".count
        return max(120, CGFloat(cells) * 17 + 6)
    }
    /// An OUTPUTS chip's text (header bar since 2026-09-23) never sets the window's width: between these it
    /// takes what the header has left; below the minimum it truncates in the middle. The full name is
    /// in the chip's menu. The minimum holds "PGM  NOT SET" (twelve cells) at the chip's legible 12 pt, so
    /// it follows the console text size: a chip cut short says nothing.
    static var outputChipMinW: CGFloat { (ARCTheme.legible(12) * 0.62 * 12).rounded() + 4 }
    static let outputChipMaxW: CGFloat = 170
    /// The pinned LIVE deck tab's widest: LIVE badge, about 12 cells of name, and the tab's padding.
    static let pinnedTabMaxW: CGFloat = 240
    /// The header width from which the clock is shown at its full 29 pt; narrower, 20 pt (2026-09-23).
    static let fullClockHeaderW: CGFloat = 1700
    static let jumpFieldW: CGFloat = 64       // "Go to" at 16 pt mono (was 132 at 29 pt until 2026-09-23)
}

// ARCExpandButton, arcExpandButton and ControlWindow moved to the ARCStyle package (ARCControls.swift, 2026-09-19):
// Capture uses the same glyph and window toggle.
