//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import PDFKit
import AVFoundation
@testable import ArcPresenter

/// Contract tests for the .arcdeck reader — the format boundary between the
/// Assimilator (writer) and Presenter (reader). Locks in the v1 contract and
/// the forward-compatibility the Assimilator now relies on: manifests carry
/// extra keys ("origins" since Assimilator v2.0.0; an embedded database is
/// planned) that this reader must ignore, never reject.
@MainActor
final class DeckReaderTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arcdeck-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Build an .arcdeck fixture: N-page slides.pdf, optional manifest JSON
    /// string, optional dummy media files (paths relative to the bundle).
    private func makeArcdeck(pages: Int, manifest: String?,
                             media: [String] = []) throws -> URL {
        let bundle = try tempDir().appendingPathComponent("Fixture.arcdeck")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let doc = PDFDocument()
        for _ in 0..<pages { doc.insert(PDFPage(), at: doc.pageCount) }
        XCTAssertTrue(doc.write(to: bundle.appendingPathComponent("slides.pdf")))
        if let manifest {
            try manifest.data(using: .utf8)!
                .write(to: bundle.appendingPathComponent("manifest.json"))
        }
        for rel in media {
            let url = bundle.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("stub".utf8).write(to: url)
        }
        return bundle
    }

    func testWellFormedArcdeckLoadsWithVideoMapping() throws {
        let bundle = try makeArcdeck(
            pages: 5,
            manifest: #"{"version":1,"slides":[{"slide":3,"type":"video","file":"media/slide_003.mov"}]}"#,
            media: ["media/slide_003.mov"])
        let deck = Deck(arcdeckURL: bundle)
        XCTAssertNotNil(deck)
        XCTAssertEqual(deck?.pageCount, 5)
        // Manifest is 1-based; internal pages are 0-based.
        XCTAssertTrue(deck?.hasVideoAt(page: 2) ?? false)
        XCTAssertFalse(deck?.hasVideoAt(page: 3) ?? true)
        XCTAssertNotNil(deck?.playerAt(page: 2))
    }

    /// Capture's STOP AND KEEP writes `deck.complete: false` on a show it ended early. The deck is
    /// verified and sound, it is just not the whole show, so Presenter loads it and marks it SHORT.
    /// Only `false` counts: every deck written before the field exists reads nil and must stay whole,
    /// which is the case that would silently mark the entire back catalogue short if this got it wrong.
    func testShortDeckIsFlaggedAndOnlyFalseCounts() throws {
        let short = try makeArcdeck(pages: 3, manifest: #"{"version":3,"deck":{"complete":false},"slides":[]}"#)
        let whole = try makeArcdeck(pages: 3, manifest: #"{"version":3,"deck":{"complete":true},"slides":[]}"#)
        let silent = try makeArcdeck(pages: 3, manifest: #"{"version":3,"deck":{},"slides":[]}"#)
        let older = try makeArcdeck(pages: 3, manifest: #"{"version":2,"slides":[]}"#)
        let noManifest = try makeArcdeck(pages: 3, manifest: nil)

        XCTAssertEqual(Deck(arcdeckURL: short)?.isShortDeck, true)
        XCTAssertEqual(Deck(arcdeckURL: whole)?.isShortDeck, false)
        XCTAssertEqual(Deck(arcdeckURL: silent)?.isShortDeck, false, "a whole deck writes nothing there")
        XCTAssertEqual(Deck(arcdeckURL: older)?.isShortDeck, false, "a deck older than the field is not short")
        XCTAssertEqual(Deck(arcdeckURL: noManifest)?.isShortDeck, false, "no manifest is not a short deck")

        // Short is a label on a deck that still works: it loads and plays like any other.
        XCTAssertEqual(Deck(arcdeckURL: short)?.pageCount, 3)
    }

    func testExtraManifestKeysAreIgnoredNotRejected() throws {
        // Assimilator v2.0.0 writes "origins"; an embedded "database" key is
        // planned (H4). The reader must load such decks exactly as v1.
        let bundle = try makeArcdeck(
            pages: 3,
            manifest: """
            {"version":1,
             "slides":[{"slide":1,"type":"video","file":"media/slide_001.mov"}],
             "origins":[{"slide":1,"deck":"1.01 X.pptx","file":"/a/b.pptx","sourceSlide":4}],
             "database":{"formatVersion":2}}
            """,
            media: ["media/slide_001.mov"])
        let deck = Deck(arcdeckURL: bundle)
        XCTAssertNotNil(deck)
        XCTAssertTrue(deck?.hasVideoAt(page: 0) ?? false)
    }

    func testMissingMediaFileIsSkippedSilently() throws {
        let bundle = try makeArcdeck(
            pages: 4,
            manifest: #"{"version":1,"slides":[{"slide":2,"type":"video","file":"media/slide_002.mov"}]}"#,
            media: [])   // manifest references a clip that does not exist
        let deck = Deck(arcdeckURL: bundle)
        XCTAssertNotNil(deck, "a missing clip must degrade to a static slide, not kill the deck")
        XCTAssertFalse(deck?.hasVideoAt(page: 1) ?? true)
    }

    func testMalformedManifestStillLoadsDeck() throws {
        let bundle = try makeArcdeck(pages: 2, manifest: "{not json at all")
        let deck = Deck(arcdeckURL: bundle)
        XCTAssertNotNil(deck, "a broken manifest must never take the show down")
        XCTAssertEqual(deck?.pageCount, 2)
        XCTAssertFalse(deck?.hasVideoAt(page: 0) ?? true)
    }

    func testNoManifestLoadsAsStaticDeck() throws {
        let bundle = try makeArcdeck(pages: 3, manifest: nil)
        let deck = Deck(arcdeckURL: bundle)
        XCTAssertNotNil(deck)
        XCTAssertEqual(deck?.pageCount, 3)
    }

    func testMissingSlidesPdfFailsCleanly() throws {
        let bundle = try tempDir().appendingPathComponent("Empty.arcdeck")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        XCTAssertNil(Deck(arcdeckURL: bundle))
    }

    // MARK: - Speaker notes (Assimilator 2.1.1 writes notes.json in the bundle)

    func testNotesJsonInsideBundleLoadsByPage() throws {
        let bundle = try makeArcdeck(pages: 4, manifest: #"{"version":1,"slides":[]}"#)
        try #"{"1":"Welcome","3":"Second point\ncontinues"}"#.data(using: .utf8)!
            .write(to: bundle.appendingPathComponent("notes.json"))
        let deck = Deck(arcdeckURL: bundle)
        XCTAssertNotNil(deck)
        XCTAssertEqual(deck?.noteFor(page: 1), "Welcome")
        XCTAssertNil(deck?.noteFor(page: 2))
        XCTAssertEqual(deck?.noteFor(page: 3), "Second point\ncontinues")
    }

    func testMalformedNotesJsonDoesNotBlockDeck() throws {
        let bundle = try makeArcdeck(pages: 2, manifest: nil)
        try Data("{oops".utf8).write(to: bundle.appendingPathComponent("notes.json"))
        let deck = Deck(arcdeckURL: bundle)
        XCTAssertNotNil(deck, "a broken notes file must never take the show down")
        XCTAssertNil(deck?.noteFor(page: 1))
    }

    func testPdfSidecarNotesLoad() throws {
        let dir = try tempDir()
        let pdf = dir.appendingPathComponent("Show.pdf")
        let doc = PDFDocument()
        doc.insert(PDFPage(), at: 0); doc.insert(PDFPage(), at: 1)
        XCTAssertTrue(doc.write(to: pdf))
        try #"{"2":"closing remarks"}"#.data(using: .utf8)!
            .write(to: dir.appendingPathComponent("Show.notes.json"))
        let deck = Deck(url: pdf)
        XCTAssertEqual(deck?.noteFor(page: 2), "closing remarks")
        XCTAssertNil(deck?.noteFor(page: 1))
    }

    func testNotesReachTheEngineOnSync() throws {
        let bundle = try makeArcdeck(pages: 2, manifest: nil)
        try #"{"2":"live note"}"#.data(using: .utf8)!
            .write(to: bundle.appendingPathComponent("notes.json"))
        let engine = SlideEngine()
        let live = SlideEngine()
        let dm = DeckManager(previewEngine: engine, previewCache: PageCache(),
                             liveEngine: live, liveCache: PageCache(),
                             timerEngine: TimerEngine())
        let deck = dm.addDeck(url: bundle, targetSize: CGSize(width: 320, height: 180), kind: .arcdeck)
        XCTAssertNotNil(deck)
        XCTAssertTrue(live.hasNotes)
        XCTAssertNil(live.currentNote)
        dm.liveNext()
        XCTAssertEqual(live.currentNote, "live note")
        deck?.cancelBuild()
    }

    func testNonVideoManifestEntriesIgnored() throws {
        let bundle = try makeArcdeck(
            pages: 3,
            manifest: #"{"version":1,"slides":[{"slide":1,"type":"audio","file":"media/a.mov"},{"slide":2,"type":"video"}]}"#,
            media: ["media/a.mov"])
        let deck = Deck(arcdeckURL: bundle)
        XCTAssertNotNil(deck)
        XCTAssertFalse(deck?.hasVideoAt(page: 0) ?? true, "non-video types are not clips")
        XCTAssertFalse(deck?.hasVideoAt(page: 1) ?? true, "entry without file is ignored")
    }

    /// Manifest version 2 (ARC Capture 2026-09-12): "clicks" are clip times
    /// of every click recorded in the clip, "entryClick" the index of the one
    /// that entered the slide. Slide 2's clip here holds slide 1's two builds
    /// (0.4, 2.1), the leave click (4.0) and slide 2's own movie click (6.5).
    func testVersion2ClickSegments() throws {
        let bundle = try makeArcdeck(
            pages: 3,
            manifest: """
            {"version":2,"slides":[
              {"slide":1,"type":"image"},
              {"slide":2,"type":"video","file":"media/slide_002.mov","clicks":[0.4,2.1,4.0,6.5],"entryClick":2},
              {"slide":3,"type":"video","file":"media/slide_003.mov","clicks":[1.0],"entryClick":0,"transition":true}]}
            """,
            media: ["media/slide_002.mov", "media/slide_003.mov"])
        let deck = try XCTUnwrap(Deck(arcdeckURL: bundle))
        XCTAssertEqual(deck.manifestVersion, 2)
        // Page 1 (index 1): two builds of page 0 at its head, one own click.
        XCTAssertEqual(deck.buildClickCount(page: 1), 2)
        XCTAssertEqual(deck.ownClickCount(page: 1), 1)
        XCTAssertEqual(deck.buildSegment(page: 1, n: 0), Deck.Segment(start: 0.4, end: 2.1))
        XCTAssertEqual(deck.buildSegment(page: 1, n: 1), Deck.Segment(start: 2.1, end: 4.0))
        XCTAssertNil(deck.buildSegment(page: 1, n: 2), "the leave click is not a build")
        XCTAssertEqual(deck.entrySegment(page: 1), Deck.Segment(start: 4.0, end: 6.5), "entry holds before the movie click")
        XCTAssertEqual(deck.ownSegment(page: 1, n: 0), Deck.Segment(start: 6.5, end: nil), "movie click plays to the end")
        XCTAssertNil(deck.ownSegment(page: 1, n: 1))
        // Page 2: a bare transition, entry plays to the end, no clicks of its own.
        XCTAssertEqual(deck.buildClickCount(page: 2), 0)
        XCTAssertEqual(deck.ownClickCount(page: 2), 0)
        XCTAssertEqual(deck.entrySegment(page: 2), Deck.Segment(start: 1.0, end: nil))
        // Page 0 is a still: no segments at all.
        XCTAssertNil(deck.entrySegment(page: 0))
        XCTAssertEqual(deck.ownClickCount(page: 0), 0)
    }

    /// "entryFile" (ARC Capture 2026-09-12): the way into a page is its own
    /// clip, the previous page's builds at its head (marks 0.4, 2.1) and the
    /// leaving click last (4.0); the main clip holds only the page's own click.
    func testEntryClipIsSeparateObject() throws {
        let bundle = try makeArcdeck(
            pages: 2,
            manifest: """
            {"version":2,"slides":[
              {"slide":1,"type":"image"},
              {"slide":2,"type":"video","file":"media/slide_002.mov","clicks":[0.05],
               "entryFile":"media/slide_002_in.mov","entryClicks":[0.4,2.1,4.0]}]}
            """,
            media: ["media/slide_002.mov", "media/slide_002_in.mov"])
        let deck = try XCTUnwrap(Deck(arcdeckURL: bundle))
        XCTAssertNotNil(deck.entryPlayerAt(page: 1))
        XCTAssertTrue(deck.isTransitionAt(page: 1), "a page with an entry clip is drawn with the TRN marker")
        XCTAssertEqual(deck.buildClickCount(page: 1), 2)
        XCTAssertEqual(deck.buildSegment(page: 1, n: 0), Deck.Segment(start: 0.4, end: 2.1, entry: true))
        XCTAssertEqual(deck.buildSegment(page: 1, n: 1), Deck.Segment(start: 2.1, end: 4.0, entry: true))
        XCTAssertNil(deck.buildSegment(page: 1, n: 2))
        XCTAssertEqual(deck.entrySegment(page: 1), Deck.Segment(start: 4.0, end: nil, entry: true), "entry plays the transition to its end and holds")
        XCTAssertEqual(deck.ownClickCount(page: 1), 1)
        XCTAssertEqual(deck.ownSegment(page: 1, n: 0), Deck.Segment(start: 0.05, end: nil), "the own click plays the main clip")
        XCTAssertEqual(deck.allClipPlayers.count, 2)
    }

    func testAutoAdvanceIsParsedForStillsAndClips() throws {
        let bundle = try makeArcdeck(
            pages: 3,
            manifest: #"{"version":2,"slides":[{"slide":1,"type":"image","autoAdvance":2},{"slide":2,"type":"video","file":"media/slide_002.mov","autoAdvance":0},{"slide":3,"type":"image"}]}"#,
            media: ["media/slide_002.mov"])
        let deck = try XCTUnwrap(Deck(arcdeckURL: bundle))
        XCTAssertEqual(deck.autoAdvances[0], 2)
        XCTAssertEqual(deck.autoAdvances[1], 0)
        XCTAssertNil(deck.autoAdvances[2])
    }

    /// Version 1 decks keep their behaviour: no click data, entry plays whole.
    func testVersion1HasNoSegments() throws {
        let bundle = try makeArcdeck(
            pages: 2,
            manifest: #"{"version":1,"slides":[{"slide":2,"type":"video","file":"media/slide_002.mov"}]}"#,
            media: ["media/slide_002.mov"])
        let deck = try XCTUnwrap(Deck(arcdeckURL: bundle))
        XCTAssertEqual(deck.manifestVersion, 1)
        XCTAssertEqual(deck.entrySegment(page: 1), Deck.Segment(start: 0, end: nil))
        XCTAssertEqual(deck.ownClickCount(page: 1), 0)
        XCTAssertEqual(deck.buildClickCount(page: 1), 0)
    }

    /// Version 2 loop pages use a plain player (the pre-loop clicks must play
    /// once); version 1 keeps the gapless AVPlayerLooper queue.
    func testVersion2LoopPageIsPlainPlayer() throws {
        let bundle = try makeArcdeck(
            pages: 2,
            manifest: #"{"version":2,"slides":[{"slide":2,"type":"video","file":"media/slide_002.mov","loop":true,"loopStart":3.1,"clicks":[0.5,2.0],"entryClick":0}]}"#,
            media: ["media/slide_002.mov"])
        let deck = try XCTUnwrap(Deck(arcdeckURL: bundle))
        XCTAssertTrue(deck.loopsAt(page: 1))
        XCTAssertFalse(deck.playerAt(page: 1) is AVQueuePlayer)
        XCTAssertEqual(deck.playerAt(page: 1)?.actionAtItemEnd, AVPlayer.ActionAtItemEnd.none)
        XCTAssertEqual(deck.loopStarts[1], 3.1)
    }

    func testLoopFlagIsHonouredAndAbsentByDefault() throws {
        let bundle = try makeArcdeck(
            pages: 3,
            manifest: """
            {"version":1,"slides":[
              {"slide":2,"type":"video","file":"media/slide_002.mov","loop":true},
              {"slide":3,"type":"video","file":"media/slide_003.mov"}]}
            """,
            media: ["media/slide_002.mov", "media/slide_003.mov"])
        let deck = try XCTUnwrap(Deck(arcdeckURL: bundle))
        XCTAssertTrue(deck.loopsAt(page: 1))
        XCTAssertFalse(deck.loopsAt(page: 2))
        XCTAssertFalse(deck.loopsAt(page: 0))
        XCTAssertTrue(deck.playerAt(page: 1) is AVQueuePlayer, "looping page is driven by AVPlayerLooper")
        XCTAssertFalse(deck.playerAt(page: 2) is AVQueuePlayer)
        XCTAssertEqual(deck.playerAt(page: 2)?.actionAtItemEnd, AVPlayer.ActionAtItemEnd.pause)
    }
}
