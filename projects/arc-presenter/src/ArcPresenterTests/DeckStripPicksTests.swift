//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import PDFKit
@testable import ArcPresenter

/// The header strip: LIVE pinned + two picks (+ the previewed deck when it is not a pick).
@MainActor
final class DeckStripPicksTests: XCTestCase {

    // MARK: Pure rules

    func testAtMostTwoPicksAndAThirdIsRefused() {
        var p = DeckStripPicks()
        XCTAssertEqual(p.toggle("b", live: "a"), .picked)
        XCTAssertEqual(p.toggle("c", live: "a"), .picked)
        XCTAssertEqual(p.toggle("d", live: "a"), .full, "a third check is refused, nothing is unchecked")
        XCTAssertEqual(p.picks, ["b", "c"])
        XCTAssertEqual(p.toggle("b", live: "a"), .unpicked)
        XCTAssertEqual(p.toggle("d", live: "a"), .picked)
        XCTAssertEqual(p.picks, ["c", "d"], "pick order")
    }

    func testTheLiveDeckIsNeverAPick() {
        var p = DeckStripPicks()
        XCTAssertEqual(p.toggle("a", live: "a"), .isLive)
        p.opened("a", live: "a")
        XCTAssertTrue(p.picks.isEmpty)
        p.set(["a", "b"], open: ["a", "b"], live: "a")
        XCTAssertEqual(p.picks, ["b"])
    }

    func testOpenedDecksFillFreeSlotsOnly() {
        var p = DeckStripPicks()
        for k in ["b", "c", "d"] { p.opened(k, live: "a") }
        XCTAssertEqual(p.picks, ["b", "c"])
    }

    func testThePreviewedDeckIsNeverHidden() {
        let p = DeckStripPicks(picks: ["b", "c"])
        let open = ["a", "b", "c", "d"]
        XCTAssertEqual(p.strip(open: open, live: "a", preview: "b"), ["b", "c"], "a picked preview adds nothing")
        XCTAssertEqual(p.strip(open: open, live: "a", preview: "d"), ["b", "c", "d"], "an unpicked preview is an extra tab")
        XCTAssertEqual(p.strip(open: open, live: "a", preview: "a"), ["b", "c"], "live = preview: shown once, pinned")
    }

    func testATakeOfAPickSwapsItWithTheOldLiveDeck() {
        var p = DeckStripPicks(picks: ["b", "c"])
        p.liveChanged(from: "a", to: "c")
        XCTAssertEqual(p.picks, ["b", "a"], "the old live deck takes the new live deck's slot")
        p.liveChanged(from: "a", to: "d")
        XCTAssertEqual(p.picks, ["b", "a"], "a take of an unpicked deck leaves the picks alone")
    }

    func testClosingAndSetKeepOnlyOpenDecks() {
        var p = DeckStripPicks(picks: ["b", "c"])
        p.closed("b")
        XCTAssertEqual(p.picks, ["c"])
        p.set(["x", "c", "c", "d", "e"], open: ["a", "c", "d", "e"], live: "a")
        XCTAssertEqual(p.picks, ["c", "d"])
    }

    // MARK: DeckManager + session

    var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("strip-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        SessionStore.fileURLOverride = tmpDir.appendingPathComponent("session.json")
    }

    override func tearDown() {
        SessionStore.fileURLOverride = nil
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func makePDF(_ name: String) throws -> URL {
        let url = tmpDir.appendingPathComponent("\(name).pdf")
        let doc = PDFDocument()
        for _ in 0..<3 { doc.insert(PDFPage(), at: doc.pageCount) }
        guard doc.write(to: url) else { throw NSError(domain: "test", code: 1) }
        return url
    }

    @MainActor
    private func makeManager() -> DeckManager {
        DeckManager(previewEngine: SlideEngine(), previewCache: PageCache(),
                    liveEngine: SlideEngine(), liveCache: PageCache(), timerEngine: TimerEngine())
    }

    @MainActor
    private func settle(_ dm: DeckManager, until condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if !dm.decks.contains(where: { $0.isLoading }), condition() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    func testDeckManagerKeepsTheStrip() async throws {
        let size = CGSize(width: 320, height: 180)
        let dm = makeManager()
        let decks = try ["A", "B", "C", "D"].map { try XCTUnwrap(dm.addDeck(url: try makePDF($0), targetSize: size, kind: .pdf)) }
        await settle(dm) { true }
        XCTAssertEqual(dm.liveDeck?.fileName, "A.pdf")
        XCTAssertEqual(dm.stripPicks.picks.count, 2, "B and C picked themselves")
        XCTAssertEqual(dm.stripDecks.map(\.fileName), ["B.pdf", "C.pdf"])

        dm.previewDeckSwitch(to: decks[3].id)
        XCTAssertEqual(dm.stripDecks.map(\.fileName), ["B.pdf", "C.pdf", "D.pdf"], "the previewed D is shown")

        dm.previewDeckSwitch(to: decks[2].id)
        dm.take()
        XCTAssertEqual(dm.liveDeck?.fileName, "C.pdf")
        XCTAssertEqual(dm.stripDecks.map(\.fileName), ["B.pdf", "A.pdf"], "A took C's slot")

        dm.removeDeck(deckID: decks[1].id)
        XCTAssertEqual(dm.stripDecks.map(\.fileName), ["A.pdf"])
    }

    @MainActor
    func testPicksRoundTripThroughTheSession() async throws {
        let size = CGSize(width: 320, height: 180)
        let dm = makeManager()
        let urls = try ["A", "B", "C", "D"].map(makePDF)
        for u in urls { dm.addDeck(url: u, targetSize: size, kind: .pdf) }
        await settle(dm) { true }
        dm.setStripPicks([DeckManager.key(urls[3]), DeckManager.key(urls[1])])
        XCTAssertEqual(dm.stripDecks.map(\.fileName), ["D.pdf", "B.pdf"])
        SessionStore.save(deckManager: dm, timer: TimerEngine(), displayManager: DisplayManager())

        let dm2 = makeManager()
        XCTAssertTrue(SessionStore.restore(deckManager: dm2, timer: TimerEngine(), displayManager: DisplayManager()))
        await settle(dm2) { dm2.decks.count == 4 && dm2.stripPicks.picks.count == 2 && dm2.stripDecks.first?.fileName == "D.pdf" }
        XCTAssertEqual(dm2.stripPicks.picks, [DeckManager.key(urls[3]), DeckManager.key(urls[1])], "by path, in pick order")
    }
}
