//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import PDFKit
import ARCShowFormat
@testable import ArcPresenter

/// The ONE show deck in Presenter (decided 2026-09-17: one show deck, not individual
/// presentations, opened in Presenter): one tab, and a later version of it staged beside the live one on the matching page.
@MainActor
final class ShowDeckSwapTests: XCTestCase {
    var parent: URL!
    var folder: URL!
    private var deckManager: DeckManager!
    var dm: DeckManager { deckManager }
    var session: ShowFolderSession!

    override func setUp() async throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("show-deck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        SessionStore.fileURLOverride = nil
        folder = try ShowSpec.createShowFolder(named: "Demo", date: nil, under: parent)
        deckManager = DeckManager(previewEngine: SlideEngine(), previewCache: PageCache(), liveEngine: SlideEngine(), liveCache: PageCache(), timerEngine: TimerEngine())
        session = ShowFolderSession(deckManager: dm, displayManager: DisplayManager(), music: nil, persisting: false)
        session.autoApplyOverride = true
    }

    override func tearDown() async throws {
        session.close()
        SessionStore.fileURLOverride = nil
        try? FileManager.default.removeItem(at: parent)
    }

    /// A combined deck as ARC Capture writes it: `talks` = (id, pages); logo pages before, between and after.
    private func showDeck(_ n: Int, talks: [(String, Int)]) throws -> ShowSpec.Version {
        let rel = "arcdecks/Demo.show.v\(n).arcdeck"
        let url = folder.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var slides: [DeckManifest.Slide] = [], pages: [(source: String?, sourcePage: Int?, slideKey: String?, isLogo: Bool)] = []
        var parts: [DeckManifest.DeckInfo.Part] = []
        func logo(_ role: DeckManifest.Role) { var s = DeckManifest.Slide(slide: slides.count + 1, type: .image); s.role = role; slides.append(s); pages.append((nil, nil, nil, true)) }
        logo(.opening)
        for (i, talk) in talks.enumerated() {
            let first = slides.count + 1
            for p in 1...talk.1 {
                slides.append(DeckManifest.Slide(slide: slides.count + 1, type: .image, pptxSlide: p, source: "\(talk.0) Talk", sourcePage: p))
                pages.append(("\(talk.0) Talk", p, nil, false))
            }
            parts.append(.init(name: "\(talk.0) Talk", firstPage: first, lastPage: slides.count))
            logo(i < talks.count - 1 ? .between : .closing)
        }
        let doc = PDFDocument(); for _ in slides { doc.insert(PDFPage(), at: doc.pageCount) }
        XCTAssertTrue(doc.write(to: url.appendingPathComponent("slides.pdf")))
        var info = DeckManifest.DeckInfo(); info.title = "Demo"; info.parts = parts
        try DeckManifest(deck: info, slides: slides).write(to: url.appendingPathComponent("manifest.json"))
        return ShowSpec.Version(number: n, arcdeck: rel, capturedAt: Date(), slideHashes: ShowSpec.pageKeys(pages), verified: true)
    }

    private func item(_ n: Int, versions: [ShowSpec.Version]) -> ShowSpec.Item {
        ShowSpec.Item(id: ShowSpec.showDeckID, title: "Demo", source: "", kind: .arcdeck, status: .ready, versions: versions, current: n)
    }

    private func settle() async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, dm.decks.contains(where: { $0.isLoading }) { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func testAShowWithAShowDeckOpensAsOneTabNamedAfterTheShow() async throws {
        var spec = try ShowSpec.load(from: folder)
        // The presentations are in show.json too; Presenter does not open them.
        spec.items = [ShowSpec.Item(id: "1.01", title: "Talk", source: "decks/1.01 Talk.pptx", kind: .powerpoint, status: .ready,
                                    versions: [ShowSpec.Version(number: 1, arcdeck: "arcdecks/1.01 Talk.v1.arcdeck", capturedAt: Date(), verified: true)], current: 1)]
        spec.showDeck = item(1, versions: [try showDeck(1, talks: [("1.01", 3), ("1.02", 2)])])
        try spec.write(to: folder)
        let opened = await session.open(folder: folder, restoreState: false)
        await settle()
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(dm.decks.map(\.shownName), ["Demo"])
        XCTAssertEqual(dm.decks.first?.pageCount, 8, "logo, 3, logo, 2, logo")
        XCTAssertEqual(dm.decks.first?.sourceSlides, Array(1...8), "a combined deck is matched page for page, logo pages included")
    }

    func testAPresentationOfAShowWithAShowDeckIsNotATabOfItsOwn() async throws {
        var spec = try ShowSpec.load(from: folder)
        let talk = "arcdecks/1.01 Talk.v1.arcdeck"
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(talk), withIntermediateDirectories: true)
        spec.items = [ShowSpec.Item(id: "1.01", title: "Talk", source: "decks/1.01 Talk.pptx", kind: .powerpoint, status: .ready,
                                    versions: [ShowSpec.Version(number: 1, arcdeck: talk, capturedAt: Date(), verified: true)], current: 1)]
        try spec.write(to: folder)
        XCTAssertFalse(ShowFolderSession.isInsideTheShowDeck(folder.appendingPathComponent(talk)), "no show deck: a tab per presentation is how this show plays")
        let v1 = try showDeck(1, talks: [("1.01", 3)])
        spec.showDeck = item(1, versions: [v1])
        try spec.write(to: folder)
        XCTAssertTrue(ShowFolderSession.isInsideTheShowDeck(folder.appendingPathComponent(talk)))
        XCTAssertFalse(ShowFolderSession.isInsideTheShowDeck(folder.appendingPathComponent(v1.arcdeck)), "the show deck itself opens")
        XCTAssertFalse(ShowFolderSession.isInsideTheShowDeck(URL(fileURLWithPath: "/tmp/Some Other.arcdeck")), "a deck the operator opened by hand is theirs")
    }

    func testALateChangeIsStagedBesideTheLiveShowDeckOnTheHoldingSlideItStandsOn() async throws {
        var spec = try ShowSpec.load(from: folder)
        let v1 = try showDeck(1, talks: [("1.01", 3), ("1.02", 2)])
        spec.showDeck = item(1, versions: [v1])
        try spec.write(to: folder)
        _ = await session.open(folder: folder, restoreState: false)
        await settle()
        XCTAssertNotNil(dm.liveDeck, "the first deck opened is live")
        dm.liveEngine.jumpTo(page: 5)                     // the holding slide BETWEEN the two talks: where a show waits
        XCTAssertEqual(dm.liveEngine.currentIndex, 4)

        // 1.01 comes back with two more slides; Capture builds show deck v2.
        let v2 = try showDeck(2, talks: [("1.01", 5), ("1.02", 2)])
        spec = try ShowSpec.load(from: folder)
        spec.showDeck = item(2, versions: [v1, v2])
        try spec.write(to: folder)
        _ = await session.sync()
        await settle()
        XCTAssertEqual(dm.decks.count, 1, "live: only marked, never swapped on its own")
        XCTAssertTrue(try XCTUnwrap(session.items.first).newerVersionReady)

        let r = await session.update()
        guard case .staged(let version, let match) = r else { return XCTFail("expected staged, got \(r)") }
        XCTAssertEqual(version, 2)
        XCTAssertEqual(match, .init(page: 6, basis: .exact), "the holding slide after 1.01 moved from page 5 to page 7")
        XCTAssertEqual(dm.decks.count, 2, "the twin is beside it")
        XCTAssertEqual(dm.liveEngine.currentIndex, 4, "the program output did not move")

        // The presenter clicks into the next talk while the twin is staged: the twin follows.
        dm.liveEngine.jumpTo(page: 6)                     // 1.02 page 1
        try? await Task.sleep(for: .milliseconds(300))
        let twin = try XCTUnwrap(dm.decks.first { $0.url.lastPathComponent.contains(".v2.") })
        XCTAssertEqual(dm.effectiveIndex(of: twin), 7, "1.02 page 1 is page 8 of v2")
    }
}
