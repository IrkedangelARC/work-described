//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import PDFKit
@testable import ArcPresenterBasic

@MainActor
final class SlideEngineTests: XCTestCase {
    var engine: SlideEngine!

    override func setUp() {
        super.setUp()
        engine = SlideEngine()
    }

    func testInitialState() {
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertEqual(engine.pageCount, 0)
        XCTAssertFalse(engine.isLoaded)
        XCTAssertFalse(engine.isBlack)
        XCTAssertEqual(engine.jumpText, "")
        XCTAssertNil(engine.sourceURL)
    }

    func testLoadPDF() {
        let url = makePDF(pages: 10)
        XCTAssertTrue(engine.loadPDF(url: url))
        XCTAssertTrue(engine.isLoaded)
        XCTAssertEqual(engine.pageCount, 10)
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertEqual(engine.currentPage, 1)
        XCTAssertEqual(engine.sourceURL, url)
    }

    func testLoadInvalidPDFFailsCleanly() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not_a_pdf_\(UUID().uuidString).pdf")
        try? Data("not a pdf".utf8).write(to: url)
        XCTAssertFalse(engine.loadPDF(url: url))
        XCTAssertFalse(engine.isLoaded)
    }

    func testNextAndPrevious() {
        engine.loadPDF(url: makePDF(pages: 5))
        engine.next()
        XCTAssertEqual(engine.currentIndex, 1)
        engine.next()
        XCTAssertEqual(engine.currentIndex, 2)
        engine.previous()
        XCTAssertEqual(engine.currentIndex, 1)
    }

    func testNextAtEnd() {
        engine.loadPDF(url: makePDF(pages: 3))
        engine.goToLast()
        XCTAssertEqual(engine.currentIndex, 2)
        engine.next()
        XCTAssertEqual(engine.currentIndex, 2)
    }

    func testPreviousAtStart() {
        engine.loadPDF(url: makePDF(pages: 3))
        engine.previous()
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testGoToFirstAndLast() {
        engine.loadPDF(url: makePDF(pages: 10))
        engine.goToLast()
        XCTAssertEqual(engine.currentIndex, 9)
        engine.goToFirst()
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testJumpTo() {
        engine.loadPDF(url: makePDF(pages: 10))
        engine.jumpTo(page: 5)
        XCTAssertEqual(engine.currentIndex, 4)
    }

    func testJumpClampHigh() {
        engine.loadPDF(url: makePDF(pages: 10))
        engine.jumpTo(page: 100)
        XCTAssertEqual(engine.currentIndex, 9)
    }

    func testJumpClampLow() {
        engine.loadPDF(url: makePDF(pages: 10))
        engine.jumpTo(page: 0)
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testCommitJump() {
        engine.loadPDF(url: makePDF(pages: 10))
        engine.jumpText = "7"
        engine.commitJump()
        XCTAssertEqual(engine.currentIndex, 6)
        XCTAssertEqual(engine.jumpText, "")
    }

    func testCommitJumpInvalid() {
        engine.loadPDF(url: makePDF(pages: 10))
        engine.jumpText = "abc"
        engine.commitJump()
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertEqual(engine.jumpText, "")
    }

    func testToggleBlack() {
        XCTAssertFalse(engine.isBlack)
        engine.toggleBlack()
        XCTAssertTrue(engine.isBlack)
        engine.toggleBlack()
        XCTAssertFalse(engine.isBlack)
    }

    func testNavigationClearsBlack() {
        engine.loadPDF(url: makePDF(pages: 5))
        engine.toggleBlack()
        XCTAssertTrue(engine.isBlack)
        engine.next()
        XCTAssertFalse(engine.isBlack)
    }

    func testJumpClearsBlack() {
        engine.loadPDF(url: makePDF(pages: 5))
        engine.toggleBlack()
        engine.jumpTo(page: 3)
        XCTAssertFalse(engine.isBlack)
    }

    func testUnload() {
        engine.loadPDF(url: makePDF(pages: 10))
        engine.next()
        engine.toggleBlack()
        engine.unload()
        XCTAssertFalse(engine.isLoaded)
        XCTAssertEqual(engine.pageCount, 0)
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertFalse(engine.isBlack)
        XCTAssertNil(engine.pdfDocument)
        XCTAssertNil(engine.sourceURL)
    }

    // MARK: - Helpers

    private func makePDF(pages: Int) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).pdf")
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
