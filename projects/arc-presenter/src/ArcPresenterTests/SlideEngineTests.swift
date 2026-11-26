//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import PDFKit
import AVFoundation
@testable import ArcPresenter

@MainActor
final class SlideEngineTests: XCTestCase {
    var engine: SlideEngine!

    override func setUp() {
        super.setUp()
        engine = SlideEngine()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertEqual(engine.pageCount, 0)
        XCTAssertFalse(engine.isLoaded)
        XCTAssertFalse(engine.isBlack)
        XCTAssertEqual(engine.jumpText, "")
    }

    // MARK: - Index clamp

    func testClampedIndexStaysInsideDeck() {
        XCTAssertEqual(SlideEngine.clampedIndex(239, pageCount: 123), 122)
        XCTAssertEqual(SlideEngine.clampedIndex(-4, pageCount: 123), 0)
        XCTAssertEqual(SlideEngine.clampedIndex(7, pageCount: 123), 7)
        XCTAssertEqual(SlideEngine.clampedIndex(5, pageCount: 0), 0)
    }

    func testLoadFromDeckClampsStaleIndex() {
        // A deck reloaded in place from a shorter file must not keep an
        // index past the new last page (Presenter showed "slide 239 of 123").
        engine.loadFromDeck(document: nil, index: 239, pageCount: 123, isBlack: false,
                            fileName: "x", jumpText: "")
        XCTAssertEqual(engine.currentIndex, 122)
    }

    func testNextPlayerIsTheFollowingPagesClip() {
        let p1 = AVPlayer(), p2 = AVPlayer()
        engine.loadFromDeck(document: nil, index: 0, pageCount: 3, isBlack: false,
                            fileName: "d", jumpText: "", isArcDeck: true,
                            slideVideoPlayers: [1: p1, 2: p2])
        XCTAssertNil(engine.currentPlayer)
        XCTAssertTrue(engine.nextPlayer === p1)
        engine.next()
        XCTAssertTrue(engine.currentPlayer === p1)
        XCTAssertTrue(engine.nextPlayer === p2)
        engine.next()
        XCTAssertNil(engine.nextPlayer, "no page after the last one")
    }

    // MARK: - Loading

    func testLoadPDF() {
        let url = createTestPDF(pageCount: 10)
        engine.loadPDF(url: url)

        XCTAssertTrue(engine.isLoaded)
        XCTAssertEqual(engine.pageCount, 10)
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertEqual(engine.currentPage, 1)
    }

    // MARK: - Navigation

    func testNextAndPrevious() {
        let url = createTestPDF(pageCount: 5)
        engine.loadPDF(url: url)

        engine.next()
        XCTAssertEqual(engine.currentIndex, 1)

        engine.next()
        XCTAssertEqual(engine.currentIndex, 2)

        engine.previous()
        XCTAssertEqual(engine.currentIndex, 1)
    }

    func testNextAtEnd() {
        let url = createTestPDF(pageCount: 3)
        engine.loadPDF(url: url)

        engine.goToLast()
        XCTAssertEqual(engine.currentIndex, 2)

        engine.next()
        XCTAssertEqual(engine.currentIndex, 2)
    }

    func testPreviousAtStart() {
        let url = createTestPDF(pageCount: 3)
        engine.loadPDF(url: url)

        engine.previous()
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testGoToFirstAndLast() {
        let url = createTestPDF(pageCount: 10)
        engine.loadPDF(url: url)

        engine.goToLast()
        XCTAssertEqual(engine.currentIndex, 9)

        engine.goToFirst()
        XCTAssertEqual(engine.currentIndex, 0)
    }

    // MARK: - Jump

    func testJumpTo() {
        let url = createTestPDF(pageCount: 10)
        engine.loadPDF(url: url)

        engine.jumpTo(page: 5)
        XCTAssertEqual(engine.currentIndex, 4)
    }

    func testJumpClampHigh() {
        let url = createTestPDF(pageCount: 10)
        engine.loadPDF(url: url)

        engine.jumpTo(page: 100)
        XCTAssertEqual(engine.currentIndex, 9)
    }

    func testJumpClampLow() {
        let url = createTestPDF(pageCount: 10)
        engine.loadPDF(url: url)

        engine.jumpTo(page: 0)
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testCommitJump() {
        let url = createTestPDF(pageCount: 10)
        engine.loadPDF(url: url)

        engine.jumpText = "7"
        engine.commitJump()
        XCTAssertEqual(engine.currentIndex, 6)
        XCTAssertEqual(engine.jumpText, "")
    }

    func testCommitJumpInvalid() {
        let url = createTestPDF(pageCount: 10)
        engine.loadPDF(url: url)

        engine.jumpText = "abc"
        engine.commitJump()
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertEqual(engine.jumpText, "")
    }

    // MARK: - Black

    func testToggleBlack() {
        XCTAssertFalse(engine.isBlack)
        engine.toggleBlack()
        XCTAssertTrue(engine.isBlack)
        engine.toggleBlack()
        XCTAssertFalse(engine.isBlack)
    }

    func testNavigationClearsBlack() {
        let url = createTestPDF(pageCount: 5)
        engine.loadPDF(url: url)

        engine.toggleBlack()
        XCTAssertTrue(engine.isBlack)

        engine.next()
        XCTAssertFalse(engine.isBlack)
    }

    func testJumpClearsBlack() {
        let url = createTestPDF(pageCount: 5)
        engine.loadPDF(url: url)

        engine.toggleBlack()
        XCTAssertTrue(engine.isBlack)

        engine.jumpTo(page: 3)
        XCTAssertFalse(engine.isBlack)
    }

    // MARK: - Unload

    func testUnload() {
        let url = createTestPDF(pageCount: 10)
        engine.loadPDF(url: url)
        engine.next()
        engine.toggleBlack()

        engine.unload()
        XCTAssertFalse(engine.isLoaded)
        XCTAssertEqual(engine.pageCount, 0)
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertFalse(engine.isBlack)
        XCTAssertNil(engine.pdfDocument)
    }

    // MARK: - Helpers

    private func createTestPDF(pageCount: Int) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).pdf")
        let pageRect = CGRect(x: 0, y: 0, width: 720, height: 405)

        var mediaBox = pageRect
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fatalError("Cannot create PDF context")
        }

        for _ in 0..<pageCount {
            context.beginPage(mediaBox: &mediaBox)
            context.endPage()
        }
        context.closePDF()

        return url
    }
}
