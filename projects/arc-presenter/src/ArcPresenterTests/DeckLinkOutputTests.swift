//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import ARCDeckLink
@testable import ArcPresenter

final class DeckLinkOutputTests: XCTestCase {
    private let devices = [
        DeckLinkDevice(persistentID: 1001, name: "UltraStudio Express Monitor 3G", supportsPlayback: true, supportsInternalKeying: false, supportsExternalKeying: false),
        DeckLinkDevice(persistentID: 2002, name: "UltraStudio Monitor 3G", supportsPlayback: true, supportsInternalKeying: false, supportsExternalKeying: false),
    ]

    func testFirstAndIndex() {
        XCTAssertEqual(DeckLinkOutput.match("first", in: devices)?.persistentID, 1001)
        XCTAssertEqual(DeckLinkOutput.match("0", in: devices)?.persistentID, 1001)
        XCTAssertEqual(DeckLinkOutput.match("", in: devices)?.persistentID, 1001)
        XCTAssertEqual(DeckLinkOutput.match("2", in: devices)?.persistentID, 2002)
        XCTAssertNil(DeckLinkOutput.match("3", in: devices))
    }

    func testPersistentIDAndNames() {
        XCTAssertEqual(DeckLinkOutput.match("2002", in: devices)?.name, "UltraStudio Monitor 3G")
        XCTAssertEqual(DeckLinkOutput.match("ultrastudio monitor 3g", in: devices)?.persistentID, 2002)
        // substring: the exact name wins over a substring hit
        XCTAssertEqual(DeckLinkOutput.match("express", in: devices)?.persistentID, 1001)
        XCTAssertNil(DeckLinkOutput.match("decklink 8k", in: devices))
        XCTAssertNil(DeckLinkOutput.match("first", in: []))
    }

    /// The SDI frame is the centred 16:9 of the program window, whatever
    /// display the window sits on (a 16:10 ALOLG pillarboxed the room, 2026-09-16).
    func testCentered16x9Crop() {
        XCTAssertEqual(DeckLinkOutput.centered16x9(in: CGSize(width: 1920, height: 1080)), CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(DeckLinkOutput.centered16x9(in: CGSize(width: 1920, height: 1280)), CGRect(x: 0, y: 100, width: 1920, height: 1080), "16:10: full width, bars cropped")
        XCTAssertEqual(DeckLinkOutput.centered16x9(in: CGSize(width: 2560, height: 1080)), CGRect(x: 320, y: 0, width: 1920, height: 1080), "ultrawide: full height, sides cropped")
        XCTAssertEqual(DeckLinkOutput.centered16x9(in: CGSize(width: 640, height: 360)), CGRect(x: 0, y: 0, width: 640, height: 360), "headless window is already 16:9")
        XCTAssertEqual(DeckLinkOutput.centered16x9(in: .zero), .zero)
    }
}
