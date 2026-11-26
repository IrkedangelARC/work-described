//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import PDFKit
import ARCShowFormat
@testable import ArcPresenter

/// V5 step 5: page matching between versions by slide hash.
final class VersionMatchTests: XCTestCase {
    private func m(_ page: Int, _ old: [String]?, _ new: [String]?, oldSlides: [Int] = [], newSlides: [Int] = [], pages: Int? = nil) -> VersionMatch.Result {
        VersionMatch.match(page: page, oldHashes: old, newHashes: new, oldSlides: oldSlides, newSlides: newSlides,
                           newPageCount: pages ?? (newSlides.isEmpty ? (new?.count ?? 3) : newSlides.count))
    }

    func testUnchangedSlideKeepsItsPlace() {
        XCTAssertEqual(m(2, ["a", "b", "c", "d"], ["a", "b", "c", "d"]), .init(page: 2, basis: .exact))
    }

    func testSlidesInsertedAheadShiftTheMatch() {
        XCTAssertEqual(m(2, ["a", "b", "c"], ["a", "x", "y", "b", "c"]), .init(page: 4, basis: .exact))
        XCTAssertEqual(m(2, ["a", "b", "c"], ["b", "c"]), .init(page: 1, basis: .exact), "a slide removed ahead")
    }

    func testTheCurrentSlideEditedIsPlacedFromItsNeighbour() {
        XCTAssertEqual(m(1, ["a", "b", "c"], ["a", "B", "c"]), .init(page: 1, basis: .neighbour))
        XCTAssertEqual(m(1, ["a", "b", "c"], ["x", "a", "B", "c"]), .init(page: 2, basis: .neighbour), "edited AND shifted")
        XCTAssertEqual(m(0, ["a", "b"], ["A", "b"]), .init(page: 0, basis: .neighbour), "no predecessor: from the one after")
        XCTAssertEqual(m(1, ["a", "b", "c"], ["a", "c"]), .init(page: 1, basis: .neighbour), "deleted: what follows its predecessor")
    }

    func testAMovedSlideIsStillTheSameSlide() {
        XCTAssertEqual(m(0, ["a", "b", "c", "d"], ["b", "c", "d", "a"]), .init(page: 3, basis: .exact))
    }

    func testDuplicateHashesStayInOrder() {
        // Two identical section slides: the second stays the second.
        XCTAssertEqual(m(3, ["s", "a", "b", "s", "c"], ["s", "a", "x", "b", "s", "c"]), .init(page: 4, basis: .exact))
    }

    func testHiddenSlidesHaveAHashAndNoPage() {
        // Old: slide 2 hidden, pages = slides 1,3,4. New: a slide inserted first, still hidden.
        let r = m(1, ["a", "h", "c", "d"], ["n", "a", "h", "c", "d"], oldSlides: [1, 3, 4], newSlides: [1, 2, 4, 5])
        XCTAssertEqual(r, .init(page: 2, basis: .exact), "page 1 = slide 3 = hash c -> new slide 4 -> page 2")
        // The matched slide became hidden: the next page, flagged.
        let h = m(1, ["a", "b", "c"], ["a", "b", "c"], oldSlides: [1, 2, 3], newSlides: [1, 3])
        XCTAssertEqual(h, .init(page: 1, basis: .neighbour))
    }

    func testNoLedgerFallsBackToTheSameNumberClamped() {
        XCTAssertEqual(m(7, nil, ["a", "b"], pages: 2), .init(page: 1, basis: .index))
        XCTAssertEqual(m(1, [], [], pages: 5), .init(page: 1, basis: .index))
        XCTAssertEqual(m(1, ["a", "b"], ["x", "y"], pages: 2), .init(page: 1, basis: .index), "nothing in common")
    }
}

/// V5 step 5: a newer version never yanks a live deck; a deck that is not
/// live is replaced in place.
@MainActor
final class VersionSwapTests: XCTestCase {
    var parent: URL!
    var folder: URL!
    private var deckManager: DeckManager!
    /// NOT the implicitly unwrapped optional itself: `dm.take()` on an
    /// `Optional` is Swift's own `Optional.take()`, which empties the variable
    /// and takes nothing (it cost three crashed test hosts, 2026-09-17).
    var dm: DeckManager { deckManager }
    var session: ShowFolderSession!

    override func setUp() async throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("version-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        SessionStore.fileURLOverride = nil
        folder = try ShowSpec.createShowFolder(named: "Swap", date: nil, under: parent)
        deckManager = DeckManager(previewEngine: SlideEngine(), previewCache: PageCache(), liveEngine: SlideEngine(), liveCache: PageCache(), timerEngine: TimerEngine())
        session = ShowFolderSession(deckManager: dm, displayManager: DisplayManager(), music: nil, persisting: false)
        session.autoApplyOverride = true
        // Two items: 1.01 opens first and is LIVE, 1.02 is not.
        var spec = try ShowSpec.load(from: folder)
        spec.items = [
            ShowSpec.Item(id: "1.01", title: "Live", source: "decks/1.01 Live.pptx", kind: .powerpoint, status: .ready,
                          versions: [try version(1, "1.01 Live", hashes: ["a", "b", "c", "d"])], current: 1),
            ShowSpec.Item(id: "1.02", title: "Later", source: "decks/1.02 Later.pptx", kind: .powerpoint, status: .ready,
                          versions: [try version(1, "1.02 Later", hashes: ["p", "q", "r"])], current: 1),
        ]
        try spec.write(to: folder)
        let opened = await session.open(folder: folder, restoreState: false)
        XCTAssertEqual(opened, 2)
        await settle()
        XCTAssertEqual(dm.liveDeck?.shownName, "1.01 Live")
    }

    override func tearDown() async throws {
        session.close()
        SessionStore.fileURLOverride = nil
        try? FileManager.default.removeItem(at: parent)
    }

    private func version(_ n: Int, _ name: String, hashes: [String], verified: Bool = true) throws -> ShowSpec.Version {
        let rel = "arcdecks/\(name).v\(n).arcdeck"
        let url = folder.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let doc = PDFDocument(); for _ in hashes { doc.insert(PDFPage(), at: doc.pageCount) }
        XCTAssertTrue(doc.write(to: url.appendingPathComponent("slides.pdf")))
        try DeckManifest(slides: (1...hashes.count).map { DeckManifest.Slide(slide: $0, type: .image, pptxSlide: $0) }).write(to: url.appendingPathComponent("manifest.json"))
        return ShowSpec.Version(number: n, arcdeck: rel, capturedAt: Date(), slideHashes: hashes, verified: verified)
    }

    /// Capture announces a new version of an item.
    private func announce(_ itemIndex: Int, _ v: ShowSpec.Version) async throws {
        var spec = try ShowSpec.load(from: folder)
        spec.items[itemIndex].versions.append(v); spec.items[itemIndex].current = v.number
        try spec.write(to: folder)
        _ = await session.sync()
        await settle()
    }

    private func settle() async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, dm.decks.contains(where: { $0.isLoading }) { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func item(_ id: String) throws -> ShowFolderSession.ItemState { try XCTUnwrap(session.items.first { $0.id == id }) }

    func testADeckThatIsNotLiveIsReplacedInPlaceOnTheMatchingSlide() async throws {
        let later = try XCTUnwrap(dm.decks.first { $0.shownName == "1.02 Later" })
        later.currentIndex = 2   // parked on "r"
        try await announce(1, try version(2, "1.02 Later", hashes: ["p", "new", "q", "r"]))
        XCTAssertEqual(dm.decks.map(\.shownName), ["1.01 Live", "1.02 Later"], "same tab, same position, no twin")
        let fresh = try XCTUnwrap(dm.decks.last)
        XCTAssertTrue(fresh.url.lastPathComponent.contains(".v2."))
        XCTAssertEqual(fresh.currentIndex, 3, "r moved from page 3 to page 4")
        XCTAssertEqual(try item("1.02").loadedVersion, 2)
        XCTAssertFalse(try item("1.02").newerVersionReady)
        XCTAssertEqual(dm.liveDeck?.shownName, "1.01 Live", "the live deck is untouched")
        XCTAssertTrue(session.attention.isEmpty)
    }

    func testThePreferenceOffOnlyMarksADeckThatIsNotLive() async throws {
        session.autoApplyOverride = false
        try await announce(1, try version(2, "1.02 Later", hashes: ["p", "q", "r", "s"]))
        XCTAssertTrue(try item("1.02").newerVersionReady)
        XCTAssertEqual(try item("1.02").loadedVersion, 1)
        let r = await session.update(itemID: "1.02")
        XCTAssertEqual(r, .applied(version: 2))
        XCTAssertEqual(dm.decks.count, 2)
    }

    func testAnUnverifiedVersionIsNeverOffered() async throws {
        try await announce(1, try version(2, "1.02 Later", hashes: ["p"], verified: false))
        XCTAssertFalse(try item("1.02").newerVersionReady)
        XCTAssertEqual(try item("1.02").loadedVersion, 1)
        let r = await session.update(itemID: "1.02")
        guard case .refused = r else { return XCTFail("\(r)") }
    }

    func testTheLiveDeckIsOnlyMarkedThenStagedThenTakenThenTheOldOneRetires() async throws {
        session.retireDelay = 0.4
        dm.liveJumpTo(page: 3)   // live on "c"
        try await announce(0, try version(2, "1.01 Live", hashes: ["a", "x", "b", "c", "d"]))
        XCTAssertEqual(dm.decks.count, 2, "marked, not swapped")
        XCTAssertTrue(try item("1.01").newerVersionReady)
        XCTAssertEqual(dm.liveDeck?.url.lastPathComponent, "1.01 Live.v1.arcdeck")

        // STAGE: a twin tab in preview on the matching page; the program is untouched.
        let staged = await session.update()   // nil = the live deck's item
        XCTAssertEqual(staged, .staged(version: 2, match: .init(page: 3, basis: .exact)))
        XCTAssertEqual(dm.decks.map(\.shownName), ["1.01 Live v1", "1.01 Live v2", "1.02 Later"], "the twin sits beside the live tab")
        XCTAssertEqual(dm.liveDeck?.url.lastPathComponent, "1.01 Live.v1.arcdeck")
        XCTAssertEqual(dm.liveEngine.currentIndex, 2)
        XCTAssertEqual(dm.previewDeck?.url.lastPathComponent, "1.01 Live.v2.arcdeck")
        XCTAssertEqual(dm.previewDeck?.currentIndex, 3)
        let st = try item("1.01")
        XCTAssertEqual(st.stagedVersion, 2); XCTAssertEqual(st.loadedVersion, 1)
        XCTAssertEqual(session.role(for: try XCTUnwrap(dm.previewDeck))?.role, .staged)
        XCTAssertFalse(session.attention.isEmpty, "a staged twin still wants the operator")

        // The ordinary TAKE: the new version is in use, the old one retires.
        dm.take()
        _ = await session.sync(loadMissing: false)
        XCTAssertEqual(dm.liveDeck?.url.lastPathComponent, "1.01 Live.v2.arcdeck")
        XCTAssertEqual(dm.liveEngine.currentIndex, 3)
        XCTAssertEqual(try item("1.01").loadedVersion, 2)
        XCTAssertEqual(try item("1.01").retiringDeckIDs.count, 1)
        XCTAssertEqual(dm.decks.count, 3, "still open for the take-back")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(dm.decks.map(\.shownName), ["1.01 Live", "1.02 Later"], "retired, and the name loses its version")
        XCTAssertTrue(session.attention.isEmpty)
    }

    /// Drill B, 2026-09-17: the presenter clicked on after STAGE and the twin
    /// stayed behind, so a TAKE would have moved the room back a slide.
    func testTheStagedTwinFollowsTheLiveSlide() async throws {
        dm.liveJumpTo(page: 2)   // live on "b"
        try await announce(0, try version(2, "1.01 Live", hashes: ["a", "x", "b", "C", "d"]))   // one inserted, "c" edited
        let staged = await session.update()
        XCTAssertEqual(staged, .staged(version: 2, match: .init(page: 2, basis: .exact)))
        let twin = try XCTUnwrap(dm.previewDeck)

        dm.liveNext()            // the presenter goes to "c", which v2 edited
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(dm.effectiveIndex(of: twin), 3, "placed from its neighbour")
        XCTAssertEqual(session.matches[twin.id], .init(page: 3, basis: .neighbour))
        dm.liveNext()            // and on to "d"
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(session.matches[twin.id], .init(page: 4, basis: .exact))
        XCTAssertEqual(dm.liveEngine.currentIndex, 3, "the program only ever moved by the clicker")

        dm.take()
        XCTAssertEqual(dm.liveDeck?.id, twin.id)
        XCTAssertEqual(dm.liveEngine.currentIndex, 4, "the room stays on d")
    }

    func testTakingTheOldVersionBackCancelsItsRetirement() async throws {
        session.retireDelay = 0.4
        try await announce(0, try version(2, "1.01 Live", hashes: ["a", "b", "c", "d", "e"]))
        let swapped = await session.update(itemID: "1.01", take: true)
        XCTAssertEqual(swapped, .swapped(version: 2, match: .init(page: 0, basis: .exact)))
        XCTAssertEqual(dm.liveDeck?.url.lastPathComponent, "1.01 Live.v2.arcdeck")
        // The operator goes back before the old tab closes.
        let old = try XCTUnwrap(dm.decks.first { $0.url.lastPathComponent == "1.01 Live.v1.arcdeck" })
        dm.previewDeckSwitch(to: old.id); dm.take()
        _ = await session.sync(loadMissing: false)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(dm.liveDeck?.id, old.id, "the live deck is never closed")
        XCTAssertEqual(try item("1.01").loadedVersion, 1)
        XCTAssertEqual(try item("1.01").stagedVersion, 2, "and the new one reads staged again")
        XCTAssertEqual(dm.decks.count, 3)
    }

    func testStagedThenTheItemLeavesTheProgramKeepsTheNewVersionOnly() async throws {
        try await announce(0, try version(2, "1.01 Live", hashes: ["a", "b", "c", "d"]))
        _ = await session.update(itemID: "1.01")
        XCTAssertEqual(dm.decks.count, 3)
        let later = try XCTUnwrap(dm.decks.first { $0.shownName == "1.02 Later" })
        dm.previewDeckSwitch(to: later.id); dm.take()
        _ = await session.sync(loadMissing: false)
        XCTAssertEqual(dm.decks.map(\.url.lastPathComponent), ["1.01 Live.v2.arcdeck", "1.02 Later.v1.arcdeck"])
        XCTAssertEqual(try item("1.01").loadedVersion, 2)
    }

    func testTimerCuesFollowTheirSlides() async throws {
        let later = try XCTUnwrap(dm.decks.first { $0.shownName == "1.02 Later" })
        later.timerCues = [TimerCue(slideNumber: 3, duration: 300, label: "Q&A")]
        try await announce(1, try version(2, "1.02 Later", hashes: ["n", "p", "q", "r"]))
        XCTAssertEqual(dm.decks.last?.timerCues.map(\.slideNumber), [4])
    }
}
