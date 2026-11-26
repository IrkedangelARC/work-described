//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import PDFKit
import AVFoundation
import ARCShowFormat
@testable import ArcPresenter

/// Manifest version 3: one clip per build, a still per build state. The
/// presenter sets the pace and backs up ONE build (docs/PLAN_per_build_clips.md).
@MainActor
final class BuildNavigationTests: XCTestCase {
    var dir: URL!
    private var manager: DeckManager!
    /// Not the implicitly unwrapped optional: `dm.take()` on one is Swift's `Optional.take()`.
    var dm: DeckManager { manager }
    var deck: Deck!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("builds-\(UUID().uuidString)")
        let bundle = dir.appendingPathComponent("Talk.arcdeck")
        for sub in ["media", "stills"] { try FileManager.default.createDirectory(at: bundle.appendingPathComponent(sub), withIntermediateDirectories: true) }
        let doc = PDFDocument(); for _ in 0..<3 { doc.insert(PDFPage(), at: doc.pageCount) }
        XCTAssertTrue(doc.write(to: bundle.appendingPathComponent("slides.pdf")))
        // Page 2 (index 1) has three builds: four states.
        var builds: [DeckManifest.Build] = []
        for n in 1...3 {
            let clip = "media/slide_002_b0\(n).mov", still = "stills/slide_002_s0\(n).png"
            try Data("clip".utf8).write(to: bundle.appendingPathComponent(clip))
            try png(level: CGFloat(n) / 4).write(to: bundle.appendingPathComponent(still))
            builds.append(.init(file: clip, still: still, duration: 1))
        }
        try png(level: 0).write(to: bundle.appendingPathComponent("stills/slide_002_s00.png"))
        try DeckManifest(slides: [.init(slide: 1, type: .image), .init(slide: 2, type: .image, builds: builds, initialStill: "stills/slide_002_s00.png"),
                                  .init(slide: 3, type: .image)]).write(to: bundle.appendingPathComponent("manifest.json"))
        manager = DeckManager(previewEngine: SlideEngine(), previewCache: PageCache(), liveEngine: SlideEngine(), liveCache: PageCache(), timerEngine: TimerEngine())
        deck = try XCTUnwrap(dm.addDeck(url: bundle, targetSize: CGSize(width: 320, height: 180), kind: .arcdeck))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func png(level: CGFloat) throws -> Data {
        let image = NSImage(size: NSSize(width: 32, height: 18), flipped: false) { r in NSColor(white: level, alpha: 1).setFill(); r.fill(); return true }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
    private var still: NSImage? { dm.liveEngine.stateStill }
    private func isState(_ n: Int) -> Bool { still === deck.stateImage(page: 1, state: n) && still != nil }

    /// A page with builds whose clip is an online video Capture fetched for a slide that links to it (2026-09-19):
    /// the builds first, one per click, then the movie on the next click; on entry the state still, not the movie.
    func testAClickStartedSourceMovieOnABuildPagePlaysAfterTheBuilds() throws {
        let bundle = dir.appendingPathComponent("Link.arcdeck")
        for sub in ["media", "stills"] { try FileManager.default.createDirectory(at: bundle.appendingPathComponent(sub), withIntermediateDirectories: true) }
        let doc = PDFDocument(); for _ in 0..<3 { doc.insert(PDFPage(), at: doc.pageCount) }
        XCTAssertTrue(doc.write(to: bundle.appendingPathComponent("slides.pdf")))
        for n in 0...2 { try png(level: CGFloat(n) / 4).write(to: bundle.appendingPathComponent("stills/slide_002_s0\(n).png")) }
        try Data("movie".utf8).write(to: bundle.appendingPathComponent("media/slide_002.mp4"))
        var page = DeckManifest.Slide(slide: 2, type: .video, file: "media/slide_002.mp4", clicks: [0],
                                      builds: (1...2).map { .init(file: nil, still: "stills/slide_002_s0\($0).png") }, initialStill: "stills/slide_002_s00.png")
        page.sourceMovie = true; page.mediaStart = .inClickSequence
        page.media = [DeckManifest.Media(kind: .video, name: "slide_002.mp4", url: "https://www.youtube.com/watch?v=VIDEO_ID_01")]
        try DeckManifest(slides: [.init(slide: 1, type: .image), page, .init(slide: 3, type: .image)]).write(to: bundle.appendingPathComponent("manifest.json"))
        let link = try XCTUnwrap(dm.addDeck(url: bundle, targetSize: CGSize(width: 320, height: 180), kind: .arcdeck))
        XCTAssertTrue(link.movieAfterBuilds(page: 1)); XCTAssertFalse(link.movieAfterBuilds(page: 0))
        XCTAssertEqual(link.ownClickCount(page: 1), 1)
        dm.previewDeckSwitch(to: link.id); dm.take()
        dm.liveNext()   // onto page 2: state 0 still, no clip
        XCTAssertEqual(dm.liveEngine.currentIndex, 1)
        XCTAssertTrue(dm.liveEngine.stateStill === link.stateImage(page: 1, state: 0))
        XCTAssertNil(dm.liveEngine.presentedClip, "the movie's first frame is not the page")
        dm.liveNext(); XCTAssertEqual(link.buildStates[1], 1); XCTAssertNil(dm.liveEngine.presentedClip)
        dm.liveNext(); XCTAssertEqual(link.buildStates[1], 2); XCTAssertNil(dm.liveEngine.presentedClip)
        dm.liveNext()   // the click after the last build: the movie
        XCTAssertEqual(dm.liveEngine.currentIndex, 1, "still on the page")
        XCTAssertNotNil(dm.liveEngine.presentedClip, "the movie plays")
        dm.liveNext()   // and on
        XCTAssertEqual(dm.liveEngine.currentIndex, 2)
    }

    func testTheDeckReadsBuildsAndStatesAndTheTimelineCount() {
        XCTAssertEqual(deck.manifestVersion, 3)
        XCTAssertEqual(deck.buildCount(page: 1), 3); XCTAssertEqual(deck.buildCount(page: 0), 0)
        XCTAssertEqual(deck.timelineBuildCount(page: 1), 3)
        XCTAssertNotNil(deck.stateImage(page: 1, state: 0)); XCTAssertNotNil(deck.stateImage(page: 1, state: 2))
        XCTAssertNotNil(deck.stateImage(page: 1, state: 3), "the finished state has its own still: the PDF page is the slide as it first appears")
        XCTAssertNil(deck.stateImage(page: 1, state: 4)); XCTAssertNil(deck.stateImage(page: 0, state: 0), "no builds, no stills")
        XCTAssertTrue(deck.finishedImage(page: 1) === deck.stateImage(page: 1, state: 3))
        XCTAssertTrue(deck.loadWarnings.isEmpty)
    }

    /// An "Appear" has no clip (Capture found no animation in its recording): the click CUTS to its still. No
    /// player, no swap, nothing to flash or stutter (2026-09-17: a deck of Appear builds stuttered on every click).
    func testABuildWithNoClipIsACutToItsStill() throws {
        let bundle = dir.appendingPathComponent("Appear.arcdeck")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("stills"), withIntermediateDirectories: true)
        let doc = PDFDocument(); for _ in 0..<3 { doc.insert(PDFPage(), at: doc.pageCount) }
        XCTAssertTrue(doc.write(to: bundle.appendingPathComponent("slides.pdf")))
        var builds: [DeckManifest.Build] = []
        for n in 0...2 { try png(level: CGFloat(n) / 4).write(to: bundle.appendingPathComponent("stills/slide_002_s0\(n).png")) }
        for n in 1...2 { builds.append(.init(file: nil, still: "stills/slide_002_s0\(n).png")) }
        try DeckManifest(slides: [.init(slide: 1, type: .image), .init(slide: 2, type: .image, builds: builds, initialStill: "stills/slide_002_s00.png"),
                                  .init(slide: 3, type: .image)]).write(to: bundle.appendingPathComponent("manifest.json"))
        let cuts = try XCTUnwrap(dm.addDeck(url: bundle, targetSize: CGSize(width: 320, height: 180), kind: .arcdeck))
        dm.previewDeckSwitch(to: cuts.id); dm.take()
        XCTAssertEqual(cuts.buildCount(page: 1), 2); XCTAssertFalse(cuts.buildAnimates(page: 1, n: 1)); XCTAssertNil(cuts.buildPlayer(page: 1, n: 1))
        XCTAssertEqual(cuts.slideInfo(page: 1), ["2 BUILDS (ALL CUTS)"], "no length claimed for what has none")
        dm.liveNext()   // onto page 2
        XCTAssertTrue(dm.liveEngine.stateStill === cuts.stateImage(page: 1, state: 0))
        for n in 1...2 {
            dm.liveNext()
            XCTAssertEqual(dm.liveEngine.currentIndex, 1, "still a build, not a slide change")
            XCTAssertEqual(dm.liveBuild, n)
            XCTAssertNil(dm.liveEngine.presentedClip, "no clip is put on screen for a cut")
            XCTAssertTrue(dm.liveEngine.stateStill === cuts.stateImage(page: 1, state: n), "the build is there at once")
        }
        dm.livePrevious()   // back undoes ONE, as with a clip
        XCTAssertEqual(dm.liveBuild, 1)
        dm.liveNext(); dm.liveNext()
        XCTAssertEqual(dm.liveEngine.currentIndex, 2, "after the last build, the next slide")
    }

    func testForwardPlaysOneBuildPerClickAtThePresentersPace() {
        dm.liveNext()   // onto page 2: nothing built yet
        XCTAssertEqual(dm.liveEngine.currentIndex, 1); XCTAssertEqual(dm.liveBuild, 0); XCTAssertEqual(dm.liveBuildCount, 3)
        XCTAssertTrue(isState(0), "the slide as it appears, not the finished page")
        XCTAssertNil(dm.liveEngine.presentedClip)
        for n in 1...3 {
            dm.liveNext()
            XCTAssertEqual(dm.liveEngine.currentIndex, 1, "a build is not a slide change")
            XCTAssertEqual(dm.liveBuild, n)
            XCTAssertTrue(dm.liveEngine.presentedClip === deck.buildPlayer(page: 1, n: n), "build \(n) is its own clip, from its first frame")
            XCTAssertTrue(isState(n - 1), "the state being left stays under the clip while it readies")
        }
        dm.liveNext()   // builds done: the next slide
        XCTAssertEqual(dm.liveEngine.currentIndex, 2)
        XCTAssertNil(still)
    }

    func testBackUndoesOneBuildWithACutToThePreviousState() {
        dm.liveNext(); dm.liveNext(); dm.liveNext()          // page 2, build 2
        XCTAssertEqual(dm.liveBuild, 2)
        dm.livePrevious()
        XCTAssertEqual(dm.liveEngine.currentIndex, 1, "still on the slide")
        XCTAssertEqual(dm.liveBuild, 1)
        XCTAssertNil(dm.liveEngine.presentedClip, "a cut, not a clip played backwards")
        XCTAssertTrue(isState(1))
        dm.liveNext()                                        // and forward again replays build 2
        XCTAssertEqual(dm.liveBuild, 2)
        XCTAssertTrue(dm.liveEngine.presentedClip === deck.buildPlayer(page: 1, n: 2))
        dm.livePrevious(); dm.livePrevious()
        XCTAssertEqual(dm.liveBuild, 0); XCTAssertTrue(isState(0))
        dm.livePrevious()                                    // nothing left to undo: the previous slide
        XCTAssertEqual(dm.liveEngine.currentIndex, 0)
    }

    func testBackIntoASlideShowsItFinishedAndStepsItsBuildsDown() {
        for _ in 0..<5 { dm.liveNext() }                     // through page 2's builds onto page 3
        XCTAssertEqual(dm.liveEngine.currentIndex, 2)
        dm.livePrevious()
        XCTAssertEqual(dm.liveEngine.currentIndex, 1)
        XCTAssertEqual(dm.liveBuild, 3, "finished, as PowerPoint shows a slide it backs into")
        XCTAssertTrue(isState(3), "NOT the PDF page, which is the slide before any build")
        dm.livePrevious()
        XCTAssertEqual(dm.liveBuild, 2); XCTAssertTrue(isState(2))
    }

    func testAJumpStartsTheSlideUnbuiltAndATakeResumesWhereItWasLeft() {
        dm.liveJumpTo(page: 2)
        XCTAssertEqual(dm.liveBuild, 0); XCTAssertTrue(isState(0))
        dm.liveNext(); dm.liveNext()                         // build 2, then the operator takes it again (a restore does the same)
        dm.take()
        XCTAssertEqual(dm.liveBuild, 2, "not back to zero, not jumped to finished")
        XCTAssertTrue(isState(2))
    }

    func testTheBuildStateIsInTheShowStateAndTheControlAPI() throws {
        dm.liveNext(); dm.liveNext(); dm.liveNext()          // page 2, build 2
        XCTAssertTrue(dm.controlStateJSON.contains("\"build\":2,\"builds\":3"))
        let state = SessionStore.snapshot(ShowContext(deckManager: dm, timer: TimerEngine(), displayManager: DisplayManager()))
        XCTAssertEqual(state.decks.first?.currentIndex, 1)
        XCTAssertEqual(state.decks.first?.build, 2, "a relaunch comes back on the same build")
    }

    func testTheTimelineReadoutSaysWhatASlideHolds() {
        XCTAssertEqual(deck.slideInfo(page: 0), ["STILL"])
        XCTAssertEqual(deck.slideInfo(page: 1), ["3 BUILDS (3 ANIMATED, 3.0 s)"])
        deck.setCue(at: 2, duration: 300, label: "Q&A")
        XCTAssertEqual(deck.slideInfo(page: 1), ["3 BUILDS (3 ANIMATED, 3.0 s)", "TIMER CUE 5:00"])
        XCTAssertEqual(deck.slideInfo(page: 9), [], "no such page")
        XCTAssertEqual(Deck.clock(7.84), "7.8 s"); XCTAssertEqual(Deck.clock(77.2), "1:17")
    }

    /// A deck captured since 2026-09-17: logo pages around it, and a manifest that says what its media is.
    func testLogoPagesAreNotSourceSlidesAndTheManifestNamesTheMedia() throws {
        let bundle = dir.appendingPathComponent("Rich.arcdeck")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("media"), withIntermediateDirectories: true)
        let doc = PDFDocument(); for _ in 0..<4 { doc.insert(PDFPage(), at: doc.pageCount) }
        XCTAssertTrue(doc.write(to: bundle.appendingPathComponent("slides.pdf")))
        for f in ["media/slide_002.mov", "media/slide_003.mov"] { try Data("clip".utf8).write(to: bundle.appendingPathComponent(f)) }
        var open = DeckManifest.Slide(slide: 1, type: .image); open.role = .opening
        var close = DeckManifest.Slide(slide: 4, type: .image); close.role = .closing
        var way = DeckManifest.Slide(slide: 2, type: .video, file: "media/slide_002.mov", clicks: [0], entryClick: 0, transitionIn: true, pptxSlide: 1)
        way.title = "Agenda"; way.transitionEffect = "prstTrans:curtains"; way.transitionSeconds = 2
        var movie = DeckManifest.Slide(slide: 3, type: .video, file: "media/slide_003.mov", clicks: [0], entryClick: 0, pptxSlide: 3)
        movie.mediaStart = .whenClickedOn
        movie.media = [.init(kind: .video, name: "media1.mp4", seconds: 71.3, width: 320, height: 240, hasAudio: true)]
        var info = DeckManifest.DeckInfo(); info.captureApp = "ARC Capture"; info.sourceHiddenSlides = [2]
        try DeckManifest(deck: info, slides: [open, way, movie, close]).write(to: bundle.appendingPathComponent("manifest.json"))
        let rich = try XCTUnwrap(Deck(arcdeckURL: bundle))

        XCTAssertEqual(rich.sourceSlides, [0, 1, 3, 0], "a logo page is no slide of the source; version matching must never land on one")
        XCTAssertTrue(rich.isLogoPage(0)); XCTAssertFalse(rich.isLogoPage(1))
        XCTAssertEqual(rich.slideInfo(page: 0), ["LOGO PAGE (OPENING)"])
        XCTAssertFalse(rich.hasMedia(page: 1), "a clip that is only the way in is not media: no VIDEO transport, no PAUSED badge")
        XCTAssertEqual(rich.slideInfo(page: 1).first, "\u{201C}Agenda\u{201D}")
        XCTAssertTrue(rich.slideInfo(page: 1).contains { $0.hasPrefix("TRANSITION IN CURTAINS") })
        XCTAssertTrue(rich.hasMedia(page: 2))
        XCTAssertEqual(Array(rich.slideInfo(page: 2).suffix(2)), ["VIDEO 1:11 320\u{00D7}240 +SOUND", "STARTS ONLY WHEN CLICKED ON (a clicker cannot start it)"])
    }

    /// 2026-09-17: a transition into a looping video; the loop must not include the transition.
    func testTheWayInHandsOverToAMovieThatPlaysOnEntryAndOnlyTheMovieLoops() throws {
        let bundle = dir.appendingPathComponent("Loop.arcdeck")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("media"), withIntermediateDirectories: true)
        let doc = PDFDocument(); for _ in 0..<2 { doc.insert(PDFPage(), at: doc.pageCount) }
        XCTAssertTrue(doc.write(to: bundle.appendingPathComponent("slides.pdf")))
        for f in ["media/slide_002.mov", "media/slide_002_in.mov"] { try Data("clip".utf8).write(to: bundle.appendingPathComponent(f)) }
        let page = DeckManifest.Slide(slide: 2, type: .video, file: "media/slide_002.mov", entryFile: "media/slide_002_in.mov", entryClicks: [0], loop: true, transitionIn: true, pptxSlide: 2)
        try DeckManifest(version: 3, slides: [.init(slide: 1, type: .image, pptxSlide: 1), page]).write(to: bundle.appendingPathComponent("manifest.json"))
        let manager = DeckManager(previewEngine: SlideEngine(), previewCache: PageCache(), liveEngine: SlideEngine(), liveCache: PageCache(), timerEngine: TimerEngine())
        let loopDeck = try XCTUnwrap(manager.addDeck(url: bundle, targetSize: CGSize(width: 320, height: 180), kind: .arcdeck))
        let wayIn = try XCTUnwrap(loopDeck.entryPlayerAt(page: 1)), movie = try XCTUnwrap(loopDeck.playerAt(page: 1))
        XCTAssertTrue(movie is AVQueuePlayer, "a clip that is nothing but the loop wraps gaplessly")
        XCTAssertTrue(loopDeck.loopsAt(page: 1))

        manager.liveNext()
        XCTAssertTrue(manager.liveEngine.presentedClip === wayIn, "the transition plays once, as its own clip")
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: wayIn.currentItem)
        XCTAssertTrue(manager.liveEngine.presentedClip === movie, "and hands over to the movie, which is all that loops")
        // Having left the page, a late end-of-clip must not drag the movie back.
        manager.livePrevious()
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: wayIn.currentItem)
        XCTAssertFalse(manager.liveEngine.presentedClip === movie)
    }

    func testOnlyTheLivePageAndItsNeighbourKeepBuildPlayers() {
        dm.liveNext(); dm.liveNext()                         // page 2, build 1: a player exists
        XCTAssertFalse(deck.allClipPlayers.isEmpty)
        dm.liveJumpTo(page: 1)
        dm.liveJumpTo(page: 3)                               // pages 3 and 4 are kept: page 2's players go
        XCTAssertTrue(deck.allClipPlayers.isEmpty, "149 builds must not mean 149 open players")
    }
}
