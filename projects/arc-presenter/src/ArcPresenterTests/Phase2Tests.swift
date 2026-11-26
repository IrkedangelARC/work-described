//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import PDFKit
@testable import ArcPresenter

/// Stability plan phase 2: the main thread leaves the live path.
@MainActor
final class Phase2Tests: XCTestCase {

    // MARK: PowerPoint command queue (2.1)

    func testStaleRuleDropsOnlyWhenSomethingNewerWaits() {
        let now = Date()
        XCTAssertFalse(PowerPointCommandQueue.isStale(issued: now.addingTimeInterval(-2), now: now, queuedBehind: 0), "a lone delayed click still goes through")
        XCTAssertFalse(PowerPointCommandQueue.isStale(issued: now.addingTimeInterval(-0.1), now: now, queuedBehind: 3), "fresh clicks are never dropped")
        XCTAssertTrue(PowerPointCommandQueue.isStale(issued: now.addingTimeInterval(-0.5), now: now, queuedBehind: 1), "old with a newer one behind: dropped")
    }

    func testQueueRunsAScriptOffMainAndReportsLatency() async {
        let q = PowerPointCommandQueue()
        let done = expectation(description: "script ran")
        var thread: Thread?
        var result: String? = "unset"
        q.send("return 1 + 1", key: "math") { error in
            thread = Thread.current
            result = error
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertNil(result)
        XCTAssertFalse(thread?.isMainThread ?? true, "the script ran off the main thread")
        let stats = q.statsSnapshot
        XCTAssertEqual(stats.sent, 1)
        XCTAssertEqual(stats.pending, 0)
        XCTAssertEqual(stats.failed, 0)
    }

    func testQueueReportsACompileError() async {
        let q = PowerPointCommandQueue()
        let done = expectation(description: "error")
        var result: String?
        q.send("tell application id \"x\" to to to", key: "bad") { error in result = error; done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertNotNil(result)
        XCTAssertEqual(q.statsSnapshot.failed, 1)
    }

    // MARK: Page renderer (2.5)

    private func makeDocument(pages: Int, size: CGSize = CGSize(width: 400, height: 225)) -> PDFDocument {
        let doc = PDFDocument()
        for _ in 0..<pages { doc.insert(PDFPage(image: NSImage(size: size, flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true })!, at: doc.pageCount) }
        return doc
    }

    func testRenderNowFitsThePageIntoTheRequestedPixelSize() throws {
        let cache = PageRenderCache()
        let doc = makeDocument(pages: 2)
        let img = try XCTUnwrap(cache.renderNow(document: doc, page: 0, pixelSize: CGSize(width: 1920, height: 1280)))
        XCTAssertEqual(img.width, 1920)
        XCTAssertEqual(img.height, 1280)
        XCTAssertEqual(cache.stats.rendered, 1)
        // Same request again is a cache hit, no second render.
        _ = cache.renderNow(document: doc, page: 0, pixelSize: CGSize(width: 1920, height: 1280))
        XCTAssertEqual(cache.stats.rendered, 1)
        XCTAssertNil(cache.image(for: doc, page: 1, pixelSize: CGSize(width: 1920, height: 1280)), "an in-memory document has no URL, so nothing prefetches; the view falls back to renderNow")
    }

    func testPrefetchRendersNeighboursFromAFileOffMain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("deck.pdf")
        XCTAssertTrue(makeDocument(pages: 6).write(to: url))
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let cache = PageRenderCache()
        let size = CGSize(width: 640, height: 360)
        XCTAssertNil(cache.image(for: doc, page: 2, pixelSize: size), "first ask: nothing cached yet, prefetch kicked")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, cache.cached(doc, page: 1, pixelSize: size) == nil { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(cache.cached(doc, page: 2, pixelSize: size), "the current page landed")
        XCTAssertNotNil(cache.cached(doc, page: 3, pixelSize: size), "and the next one")
        XCTAssertNotNil(cache.cached(doc, page: 1, pixelSize: size), "and the previous one")
        XCTAssertLessThanOrEqual(cache.stats.cached, PageRenderCache.maxImages)
        try? FileManager.default.removeItem(at: dir)
    }

    func testRenderHonoursPageRotation() throws {
        let cache = PageRenderCache()
        let doc = makeDocument(pages: 1, size: CGSize(width: 400, height: 200))
        doc.page(at: 0)?.rotation = 90
        let img = try XCTUnwrap(cache.renderNow(document: doc, page: 0, pixelSize: CGSize(width: 200, height: 400)))
        XCTAssertEqual(img.width, 200); XCTAssertEqual(img.height, 400)
    }

    // MARK: Deck preload (2.4)

    func testLoadDeckParsesOffMainAndAddsTheDeck() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("deck.pdf")
        XCTAssertTrue(makeDocument(pages: 4).write(to: url))
        let dm = DeckManager(previewEngine: SlideEngine(), previewCache: PageCache(), liveEngine: SlideEngine(), liveCache: PageCache(), timerEngine: TimerEngine())
        let loaded = await dm.loadDeck(url: url, targetSize: CGSize(width: 320, height: 180), kind: .pdf)
        let deck = try XCTUnwrap(loaded)
        XCTAssertEqual(deck.pageCount, 4)
        XCTAssertEqual(dm.decks.count, 1)
        let loadedAgain = await dm.loadDeck(url: url, targetSize: CGSize(width: 320, height: 180), kind: .pdf)
        let again = try XCTUnwrap(loadedAgain)
        XCTAssertTrue(again === deck, "loading the same file again focuses the existing deck")
        try? FileManager.default.removeItem(at: dir)
    }
}
