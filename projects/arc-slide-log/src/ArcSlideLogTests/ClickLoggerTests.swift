//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import CoreGraphics
@testable import ArcSlideLog

/// Click impulses are named by key, never by typed text; auto-repeat is one press.
final class ClickLoggerTests: XCTestCase {
    private func key(_ code: Int64, flags: CGEventFlags = [], repeat r: Bool = false) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
        e.flags = flags
        e.setIntegerValueField(.keyboardEventAutorepeat, value: r ? 1 : 0)
        return e
    }

    func testClickerKeysHaveNames() {
        XCTAssertEqual(ClickLogger.describe(type: .keyDown, event: key(121))?.name, "pagedown")
        XCTAssertEqual(ClickLogger.describe(type: .keyDown, event: key(124))?.name, "right")
        XCTAssertEqual(ClickLogger.describe(type: .keyDown, event: key(49))?.name, "space")
        XCTAssertEqual(ClickLogger.describe(type: .keyDown, event: key(11))?.name, "b")
        XCTAssertEqual(ClickLogger.describe(type: .keyDown, event: key(53))?.name, "esc")
        XCTAssertEqual(ClickLogger.describe(type: .keyDown, event: key(0))?.name, "key 0", "a letter is a code, not text")
        XCTAssertEqual(ClickLogger.describe(type: .keyDown, event: key(124))?.source, "key")
    }

    func testModifiersAndAutoRepeat() {
        let d = ClickLogger.describe(type: .keyDown, event: key(124, flags: [.maskShift, .maskCommand]))
        XCTAssertEqual(d?.modifiers, "cmd+shift")
        XCTAssertNil(ClickLogger.describe(type: .keyDown, event: key(124, repeat: true)), "a held key is one press")
        XCTAssertNil(ClickLogger.describe(type: .keyDown, event: key(124))?.modifiers)
    }

    func testMouseButtons() {
        let left = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        XCTAssertEqual(ClickLogger.describe(type: .leftMouseDown, event: left)?.name, "mouse-left")
        XCTAssertEqual(ClickLogger.describe(type: .leftMouseDown, event: left)?.source, "mouse")
        let right = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: .zero, mouseButton: .right)!
        XCTAssertEqual(ClickLogger.describe(type: .rightMouseDown, event: right)?.name, "mouse-right")
        XCTAssertNil(ClickLogger.describe(type: .keyUp, event: key(124)), "only presses")
    }
}
