//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import PDFKit
import AVFoundation
@testable import ArcPresenter

/// Regression tests for the stuck-audio bug: a playing arcdeck clip must be
/// paused by EVERY route away from it — navigation, tab switch, TAKE, and
/// deck close. AVPlayer.play() sets rate=1 even without valid media, so
/// rate assertions work against stub clip files.
@MainActor
final class PlaybackReconcileTests: XCTestCase {

    var dm: DeckManager!
    var previewEngine: SlideEngine!
    var liveEngine: SlideEngine!
    var tmpDir: URL!

    /// Throwing fixture accessor — a nil fixture fails the test instead of
    /// trapping the host (see settleAndReconcile note).
    private func manager(file: StaticString = #filePath, line: UInt = #line) throws -> DeckManager {
        try XCTUnwrap(dm, "DeckManager fixture is nil — setUp did not run", file: file, line: line)
    }

    override func setUp() {
        super.setUp()
        previewEngine = SlideEngine()
        liveEngine = SlideEngine()
        dm = DeckManager(previewEngine: previewEngine, previewCache: PageCache(),
                         liveEngine: liveEngine, liveCache: PageCache(),
                         timerEngine: TimerEngine())
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconcile-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    /// Builds a minimal real .arcdeck: 3 blank PDF pages, clips on slides 1+2.
    private func makeArcdeck(named name: String) throws -> URL {
        let bundle = tmpDir.appendingPathComponent("\(name).arcdeck")
        let media = bundle.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)

        let doc = PDFDocument()
        for _ in 0..<3 { doc.insert(PDFPage(), at: doc.pageCount) }
        guard doc.write(to: bundle.appendingPathComponent("slides.pdf")) else {
            throw NSError(domain: "test", code: 1)
        }
        // Stub clip files (existence is what Deck checks).
        try Data("stub".utf8).write(to: media.appendingPathComponent("slide_001.mov"))
        try Data("stub".utf8).write(to: media.appendingPathComponent("slide_002.mov"))
        let manifest: [String: Any] = ["version": 1, "slides": [
            ["slide": 1, "type": "video", "file": "media/slide_001.mov"],
            ["slide": 2, "type": "video", "file": "media/slide_002.mov"],
        ]]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: bundle.appendingPathComponent("manifest.json"))
        return bundle
    }

    private func addArcdeck(_ name: String) throws -> Deck {
        let url = try makeArcdeck(named: name)
        guard let deck = try manager().addDeck(url: url, targetSize: CGSize(width: 640, height: 360),
                                    kind: .arcdeck) else {
            throw NSError(domain: "test", code: 2)
        }
        return deck
    }

    // MARK: - The bug scenarios

    /// Settle async cache callbacks that stub-media decks spawn, then reconcile
    /// once (the app reconciles on every nav/take/tick) — asserts the GUARANTEED
    /// steady state rather than a mid-flight instant.
    ///
    /// Guarded, not force-unwrapped: a nil fixture here previously TRAPPED and
    /// took down the whole test host (field crash 2026-07-19, masked by the
    /// runner's retry). A test-infrastructure failure must fail the TEST.
    private func settleAndReconcile(file: StaticString = #filePath, line: UInt = #line) {
        guard let dm else {
            XCTFail("DeckManager fixture is nil — setUp did not run for this invocation", file: file, line: line)
            return
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        dm.reconcilePlayback()
    }

    func testLiveNavigationPausesPreviousClip() throws {
        let deck = try addArcdeck("nav")
        let clip0 = try XCTUnwrap(deck.slideVideoPlayers[0])
        clip0.play()
        XCTAssertEqual(clip0.rate, 1, "precondition: clip playing")

        try manager().liveNext()   // slide 1 -> 2
        settleAndReconcile()

        XCTAssertEqual(clip0.rate, 0, "clip left behind by live navigation must pause")
    }

    func testPreviewTabSwitchPausesAuditionedClip() throws {
        let deckA = try addArcdeck("tabA")
        let deckB = try addArcdeck("tabB")
        // Live stays on deckA slide 0; operator auditions deckA slide 2's clip
        // in preview (not the live clip), then switches tabs.
        let auditioned = try XCTUnwrap(deckA.slideVideoPlayers[1])
        auditioned.play()
        XCTAssertEqual(auditioned.rate, 1)

        try manager().previewDeckSwitch(to: deckB.id)
        settleAndReconcile()

        XCTAssertEqual(auditioned.rate, 0, "auditioned clip must not survive a tab switch")
    }

    func testPreviewNavigationDoesNotKillLiveClip() throws {
        let deck = try addArcdeck("shared")
        // Live is on slide 0 with its clip playing (the program audio).
        let liveClip = try XCTUnwrap(deck.slideVideoPlayers[0])
        liveClip.play()

        // Operator navigates PREVIEW away (offline navigation). Assert
        // immediately: preview nav must not touch the live clip synchronously.
        try XCTUnwrap(previewEngine, "engine fixture nil").jumpTo(page: 3)

        XCTAssertEqual(liveClip.rate, 1, "preview navigation must NOT kill live program audio")
    }

    func testTakeSilencesOldLiveDeckClip() throws {
        let deckA = try addArcdeck("takeA")
        let deckB = try addArcdeck("takeB")
        let oldLiveClip = try XCTUnwrap(deckA.slideVideoPlayers[0])
        oldLiveClip.play()

        try manager().previewDeckSwitch(to: deckB.id)
        oldLiveClip.play()   // restart to isolate take()'s effect
        try manager().take()            // deckB goes live
        settleAndReconcile()

        XCTAssertEqual(oldLiveClip.rate, 0, "old live deck's clip must pause on TAKE")
    }

    func testRemoveDeckPausesItsClips() throws {
        let deck = try addArcdeck("close")
        let clip = try XCTUnwrap(deck.slideVideoPlayers[0])
        clip.play()

        try manager().removeDeck(deckID: deck.id)
        settleAndReconcile()

        XCTAssertEqual(clip.rate, 0, "closing a deck must stop its audio")
    }

    func testFilmstripJumpPausesOrphan() throws {
        let deck = try addArcdeck("jump")
        let clip0 = try XCTUnwrap(deck.slideVideoPlayers[0])
        clip0.play()

        // Filmstrip clicks call the engine directly — the historical leak path.
        try XCTUnwrap(liveEngine, "engine fixture nil").jumpTo(page: 3)
        settleAndReconcile()

        XCTAssertEqual(clip0.rate, 0, "direct engine jump must still pause the orphaned clip")
    }
}
