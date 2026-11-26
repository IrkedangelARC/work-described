//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcPresenter

/// Typing a message must not drive the show (2026-09-18), and there are
/// six presets beside the box.
@MainActor
final class MessageKeysTests: XCTestCase {
    func testEveryKeyStaysWithTheTextFieldExceptEscape() {
        // Space, Return, letters, delete, AND the arrows and page keys: a Left
        // to fix a typo must never move the live slide.
        for key: UInt16 in [49, 36, 0, 1, 12, 13, 51, 123, 124, 125, 126, 116, 121] {
            XCTAssertFalse(KeyBindings.leavesTyping(key), "key \(key) is typing")
        }
        XCTAssertTrue(KeyBindings.leavesTyping(53), "Escape is the way out")
    }

    func testSixPresetsByDefault() {
        XCTAssertEqual(MessageEngine.defaultQuickMessages.count, 6)
        XCTAssertTrue(MessageEngine.defaultQuickMessages.allSatisfy { !$0.isEmpty })
    }
}
