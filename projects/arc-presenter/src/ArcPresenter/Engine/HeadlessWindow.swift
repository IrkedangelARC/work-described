//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

/// A window that exists to be CAPTURED, not looked at: the DeckLink program window with no program
/// display, and the share window Zoom picks. Borderless, ordinary level, black, out of the tab cycle,
/// in a corner of the OPERATOR's screen behind the operator window: on screen (ScreenCaptureKit needs
/// that; occluded is fine) but out of the way. One placement for both (assessment 2026-09-20: the two
/// copies picked "the key window's screen", which can be the program display, and a window placed there
/// sits under the shield where the operator cannot see it).
@MainActor
enum HeadlessWindow {
    enum Corner { case bottomLeft, bottomRight }

    /// The operator's screen: where the operator window is, else the main screen.
    static var operatorScreen: NSScreen? {
        OperatorWindowSizing.operatorWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Style and place `window` at `size` in `corner` of the operator's screen, sent to the back.
    /// Returns false when there is no screen to place it on.
    @discardableResult
    static func place(_ window: NSWindow, size: NSSize, corner: Corner) -> Bool {
        guard let screen = operatorScreen else { return false }
        let v = screen.visibleFrame
        window.styleMask = [.borderless]
        window.level = .normal
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        let x = corner == .bottomLeft ? v.minX + 16 : v.maxX - size.width - 16
        window.setFrame(NSRect(x: x, y: v.minY + 16, width: size.width, height: size.height), display: true)
        window.orderBack(nil)
        return true
    }
}
