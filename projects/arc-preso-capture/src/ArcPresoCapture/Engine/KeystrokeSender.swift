//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import CoreGraphics

final class KeystrokeSender {
    private let rightArrowKeyCode: CGKeyCode = 0x7C  // kVK_RightArrow

    func sendRightArrow() {
        post(keyCode: rightArrowKeyCode)
    }

    private func post(keyCode: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
