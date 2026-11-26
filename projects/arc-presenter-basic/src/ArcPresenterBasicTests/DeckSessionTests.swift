//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcPresenterBasic

@MainActor
final class DeckSessionTests: XCTestCase {
    var session: DeckSession!

    override func setUp() {
        super.setUp()
        session = DeckSession()
    }

    func testInitialStateIsEmpty() {
        XCTAssertFalse(session.liveEngine.isLoaded)
        XCTAssertFalse(session.hasBrowseDeck)
        XCTAssertEqual(session.mode, .live)
    }

    func testFirstOpenLoadsToLive() {
        let url = makePDF(pages: 5)
        XCTAssertTrue(session.openPDF(url: url))

        XCTAssertTrue(session.liveEngine.isLoaded)
        XCTAssertEqual(session.liveEngine.pageCount, 5)
        XCTAssertFalse(session.hasBrowseDeck)
        XCTAssertEqual(session.mode, .live)
    }

    func testSecondOpenLoadsToBrowseAndSwitchesMode() {
        let live = makePDF(pages: 5)
        let other = makePDF(pages: 12)
        session.openPDF(url: live)
        session.openPDF(url: other)

        XCTAssertTrue(session.liveEngine.isLoaded)
        XCTAssertEqual(session.liveEngine.pageCount, 5)
        XCTAssertTrue(session.hasBrowseDeck)
        XCTAssertEqual(session.browseEngine?.pageCount, 12)
        XCTAssertEqual(session.mode, .browse)
    }

    func testActiveEngineMatchesMode() {
        let live = makePDF(pages: 5)
        let other = makePDF(pages: 12)
        session.openPDF(url: live)
        session.openPDF(url: other)

        XCTAssertEqual(session.activeEngine.pageCount, 12)
        session.switchToLive()
        XCTAssertEqual(session.activeEngine.pageCount, 5)
        session.switchToBrowse()
        XCTAssertEqual(session.activeEngine.pageCount, 12)
    }

    func testSendBrowseToOutputPromotesAndClearsBrowse() {
        let live = makePDF(pages: 5)
        let other = makePDF(pages: 12)
        session.openPDF(url: live)
        session.openPDF(url: other)
        session.liveEngine.next()
        XCTAssertEqual(session.liveEngine.currentIndex, 1)

        session.sendBrowseToOutput()

        XCTAssertEqual(session.liveEngine.pageCount, 12)
        XCTAssertEqual(session.liveEngine.currentIndex, 0)
        XCTAssertFalse(session.hasBrowseDeck)
        XCTAssertEqual(session.mode, .live)
    }

    func testCloseBrowseDropsOnlyBrowse() {
        let live = makePDF(pages: 5)
        let other = makePDF(pages: 12)
        session.openPDF(url: live)
        session.openPDF(url: other)
        session.liveEngine.next()

        session.closeBrowse()

        XCTAssertTrue(session.liveEngine.isLoaded)
        XCTAssertEqual(session.liveEngine.pageCount, 5)
        XCTAssertEqual(session.liveEngine.currentIndex, 1)
        XCTAssertFalse(session.hasBrowseDeck)
        XCTAssertEqual(session.mode, .live)
    }

    func testToggleModeNoOpWithoutBrowse() {
        session.openPDF(url: makePDF(pages: 5))
        session.toggleMode()
        XCTAssertEqual(session.mode, .live)
    }

    func testToggleModeFlipsWithBrowse() {
        session.openPDF(url: makePDF(pages: 5))
        session.openPDF(url: makePDF(pages: 12))
        XCTAssertEqual(session.mode, .browse)
        session.toggleMode()
        XCTAssertEqual(session.mode, .live)
        session.toggleMode()
        XCTAssertEqual(session.mode, .browse)
    }

    func testResetClearsEverything() {
        session.openPDF(url: makePDF(pages: 5))
        session.openPDF(url: makePDF(pages: 12))

        session.reset()

        XCTAssertFalse(session.liveEngine.isLoaded)
        XCTAssertFalse(session.hasBrowseDeck)
        XCTAssertEqual(session.mode, .live)
    }

    func testInvalidPDFOpenFailsCleanly() {
        let bad = FileManager.default.temporaryDirectory
            .appendingPathComponent("bogus_\(UUID().uuidString).pdf")
        try? Data("nope".utf8).write(to: bad)

        XCTAssertFalse(session.openPDF(url: bad))
        XCTAssertFalse(session.liveEngine.isLoaded)
        XCTAssertFalse(session.hasBrowseDeck)
    }

    func testInvalidBrowseOpenLeavesLiveIntact() {
        let live = makePDF(pages: 5)
        session.openPDF(url: live)
        let bad = FileManager.default.temporaryDirectory
            .appendingPathComponent("bogus_\(UUID().uuidString).pdf")
        try? Data("nope".utf8).write(to: bad)

        XCTAssertFalse(session.openPDF(url: bad))
        XCTAssertEqual(session.liveEngine.pageCount, 5)
        XCTAssertFalse(session.hasBrowseDeck)
        XCTAssertEqual(session.mode, .live)
    }

    // MARK: - Helpers

    private func makePDF(pages: Int) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds_\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 720, height: 405)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            fatalError("Cannot create PDF context")
        }
        for _ in 0..<pages {
            ctx.beginPage(mediaBox: &box)
            ctx.endPage()
        }
        ctx.closePDF()
        return url
    }
}
