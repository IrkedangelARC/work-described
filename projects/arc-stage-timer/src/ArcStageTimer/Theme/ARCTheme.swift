//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
@_exported import ARCStyle

/// ARC Stage Timer's own tokens, on top of the ONE shared ARC Style (the `arc-style` package: ground, module
/// chrome, section tints, the monospace type rule). The app used to carry its own copy of every token, drifted:
/// a near-black ground instead of the console grey, a cyan accent, #A61C1C for the ARC red, 12 pt corners.
/// Those are gone; what is left here is what is Stage Timer's alone.
///
/// The STAGE side is deliberately not console-styled. What a presenter reads from across a room is governed by
/// `DisplayColorScheme` and the big type below: black ground, one colour of meaning at a time, no chrome.
extension ARCTheme {
    // MARK: Timer state (the meaning of a number, on the operator's screen and the stage's)
    static let timerGreen = Color(red: 0, green: 0.784, blue: 0.325)   // #00C853
    static let timerYellow = Color(red: 1, green: 0.839, blue: 0)      // #FFD600
    static let timerRed = Color(red: 1, green: 0.091, blue: 0.267)     // #FF1744

    // MARK: Stage type (read at ten feet on an iPad, across the room on a TV): not console type
    static let timerFont = Font.system(size: 120, weight: .light, design: .monospaced)
    static let timerFontCompact = Font.system(size: 72, weight: .light, design: .monospaced)
    static let cueTitle = Font.system(size: 62, weight: .semibold)
    static let cueSubtitle = Font.system(size: 32, weight: .regular)   // under the 62 pt title, never beside it (2026-09-25)
    static let cueSpeakers = Font.system(size: 36, weight: .medium)
    static let nextUp = Font.system(size: 31, weight: .medium)

    static let cueTitleCompact = Font.system(size: 32, weight: .semibold)
    static let cueSubtitleCompact = Font.system(size: 22, weight: .regular)
    static let cueSpeakersCompact = Font.system(size: 20, weight: .medium)
    static let nextUpCompact = Font.system(size: 16, weight: .medium)

    static let cueTitleStage = Font.system(size: 96, weight: .semibold)
    static let cueSubtitleStage = Font.system(size: 64, weight: .regular)
    static let cueSpeakersStage = Font.system(size: 60, weight: .medium)
    static let nextUpStage = Font.system(size: 48, weight: .medium)

    // MARK: Layout
    static let sidebarWidth: CGFloat = 280
}
