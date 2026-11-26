//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import PDFKit
import ARCShowFormat
@testable import ArcPresenter

/// V5: the open show folder — decks in run order with item names, tab
/// markers for a newer version and a changed source, state in the folder.
@MainActor
final class ShowFolderSessionTests: XCTestCase {
    var parent: URL!

    override func setUp() {
        super.setUp()
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("show-session-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        SessionStore.fileURLOverride = nil
    }
    override func tearDown() {
        SessionStore.fileURLOverride = nil
        try? FileManager.default.removeItem(at: parent)
        super.tearDown()
    }

    private func makeArcdeck(_ name: String, pages: Int, in folder: URL) throws -> String {
        let rel = "arcdecks/\(name).arcdeck"
        let url = folder.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let doc = PDFDocument(); for _ in 0..<pages { doc.insert(PDFPage(), at: doc.pageCount) }
        XCTAssertTrue(doc.write(to: url.appendingPathComponent("slides.pdf")))
        try DeckManifest(slides: (1...pages).map { DeckManifest.Slide(slide: $0, type: .image) }).write(to: url.appendingPathComponent("manifest.json"))
        return rel
    }

    private func version(_ n: Int, _ rel: String) -> ShowSpec.Version {
        ShowSpec.Version(number: n, arcdeck: rel, capturedAt: Date(), verified: true)
    }

    private func settle(_ dm: DeckManager) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, dm.decks.contains(where: { $0.isLoading }) { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func testOpenLoadsReadyItemsInRunOrderWithItemNames() async throws {
        let folder = try ShowSpec.createShowFolder(named: "Demo", date: nil, under: parent)
        var spec = try ShowSpec.load(from: folder)
        let a = try makeArcdeck("1.10 Closing.v1", pages: 2, in: folder)
        let b = try makeArcdeck("1.9 Speaker.v1", pages: 3, in: folder)
        spec.items = [
            ShowSpec.Item(id: "1.10", title: "Closing", source: "decks/1.10 Closing.pdf", kind: .pdf, status: .ready, versions: [version(1, a)], current: 1),
            ShowSpec.Item(id: "1.9", title: "Speaker", source: "decks/1.9 Speaker.pptx", kind: .powerpoint, status: .ready, versions: [version(1, b)], current: 1),
            ShowSpec.Item(id: "1.11", title: "Late", source: "decks/1.11 Late.pptx", kind: .powerpoint, status: .pending),
        ]
        try spec.write(to: folder)

        let dm = DeckManager(previewEngine: SlideEngine(), previewCache: PageCache(), liveEngine: SlideEngine(), liveCache: PageCache(), timerEngine: TimerEngine())
        let session = ShowFolderSession(deckManager: dm, displayManager: DisplayManager(), music: nil, persisting: false)
        let opened = await session.open(folder: folder, restoreState: false)
        await settle(dm)
        XCTAssertEqual(opened, 2)
        XCTAssertEqual(dm.decks.map(\.shownName), ["1.9 Speaker", "1.10 Closing"], "run order, item names on the tabs")
        XCTAssertEqual(SessionStore.fileURL, folder.appendingPathComponent("state/session.json"), "the show's own state file")
        XCTAssertEqual(session.attention.map(\.id), ["1.11"], "the pending item wants attention")
        XCTAssertEqual(session.changesSummary, "1 awaiting capture")
        XCTAssertNil(session.state(for: dm.decks[0])?.newerVersionReady == true ? "x" : nil)

        // Capture writes v2 of Speaker and marks Closing's source updated.
        let b2 = try makeArcdeck("1.9 Speaker.v2", pages: 4, in: folder)
        spec = try ShowSpec.load(from: folder)
        spec.items[1].versions.append(version(2, b2)); spec.items[1].current = 2
        spec.items[0].status = .updated
        try spec.write(to: folder)
        _ = await session.sync()
        let speaker = try XCTUnwrap(session.state(for: dm.decks[0]))
        XCTAssertEqual(speaker.loadedVersion, 1); XCTAssertEqual(speaker.currentVersion, 2)
        XCTAssertTrue(speaker.newerVersionReady, "marked, not swapped: the swap is the operator's")
        XCTAssertEqual(dm.decks.count, 2, "no second Speaker tab")
        XCTAssertEqual(session.state(for: dm.decks[1])?.status, .updated)
        XCTAssertEqual(session.changesSummary, "1 new version, 2 awaiting capture")

        // The late deck arrives: a new tab at its run-order position.
        let c = try makeArcdeck("1.11 Late.v1", pages: 1, in: folder)
        spec = try ShowSpec.load(from: folder)
        spec.items[2].status = .ready; spec.items[2].versions = [version(1, c)]; spec.items[2].current = 1
        try spec.write(to: folder)
        let more = await session.sync()
        await settle(dm)
        XCTAssertEqual(more, 1)
        XCTAssertEqual(dm.decks.map(\.shownName), ["1.9 Speaker", "1.10 Closing", "1.11 Late"])

        session.close()
        XCTAssertNil(SessionStore.fileURLOverride)
        XCTAssertFalse(session.isOpen)
    }

    func testDeckOrderKeepsUnlistedDecksAfter() throws {
        let dm = DeckManager(previewEngine: SlideEngine(), previewCache: PageCache(), liveEngine: SlideEngine(), liveCache: PageCache(), timerEngine: TimerEngine())
        let dir = parent!
        var urls: [URL] = []
        for n in ["x", "y", "z"] {
            let u = dir.appendingPathComponent("\(n).pdf"); let d = PDFDocument(); d.insert(PDFPage(), at: 0); XCTAssertTrue(d.write(to: u)); urls.append(u)
        }
        let decks = urls.compactMap { dm.addDeck(url: $0, targetSize: CGSize(width: 320, height: 180), kind: .pdf) }
        dm.setDeckOrder([decks[2].id, decks[0].id])
        XCTAssertEqual(dm.decks.map(\.fileName), ["z.pdf", "x.pdf", "y.pdf"])
    }
    // MARK: 1b: a version is READY only once its files are on this disk

    func testNewerVersionIsDownloadingUntilItsFilesAreLocal() async throws {
        let folder = try ShowSpec.createShowFolder(named: "Demo", date: nil, under: parent)
        var spec = try ShowSpec.load(from: folder)
        let a = try makeArcdeck("1.9 Speaker.v1", pages: 3, in: folder)
        spec.items = [ShowSpec.Item(id: "1.9", title: "Speaker", source: "decks/1.9 Speaker.pptx", kind: .powerpoint, status: .ready, versions: [version(1, a)], current: 1)]
        try spec.write(to: folder)
        let dm = DeckManager(previewEngine: SlideEngine(), previewCache: PageCache(), liveEngine: SlideEngine(), liveCache: PageCache(), timerEngine: TimerEngine())
        let session = ShowFolderSession(deckManager: dm, displayManager: DisplayManager(), music: nil, persisting: false)
        _ = await session.open(folder: folder, restoreState: false)
        await settle(dm)
        XCTAssertEqual(dm.decks.count, 1)

        // v2 arrives the way iCloud delivers it: show.json first, the deck's files later.
        let b = try makeArcdeck("1.9 Speaker.v2", pages: 4, in: folder)
        session.fileCheck = { url in url.lastPathComponent.hasSuffix("v2.arcdeck") ? .init(local: 1, total: 3) : .init(local: 2, total: 2) }
        spec = try ShowSpec.load(from: folder)
        spec.items[0].versions.append(version(2, b)); spec.items[0].current = 2
        try spec.write(to: folder)
        _ = await session.sync()
        var speaker = try XCTUnwrap(session.state(for: dm.decks[0]))
        XCTAssertFalse(speaker.newerVersionReady, "not offered while its files are still arriving")
        XCTAssertTrue(speaker.newerVersionDownloading)
        XCTAssertEqual(speaker.localFiles, 1); XCTAssertEqual(speaker.totalFiles, 3)
        XCTAssertEqual(session.changesSummary, "1 downloading")
        XCTAssertEqual(session.shortAttention, "1 DOWNLOADING")
        let r = await session.update(itemID: "1.9")
        guard case .refused(let why) = r else { return XCTFail("a STAGE while downloading must be refused, got \(r)") }
        XCTAssertTrue(why.contains("still downloading"), why)
        XCTAssertEqual(dm.decks.count, 1, "nothing was opened")

        // The files land.
        session.fileCheck = { _ in .init(local: 3, total: 3) }
        _ = await session.sync()
        speaker = try XCTUnwrap(session.state(for: dm.decks[0]))
        XCTAssertTrue(speaker.newerVersionReady)
        XCTAssertFalse(speaker.newerVersionDownloading)
        XCTAssertEqual(session.changesSummary, "1 new version")
    }

    func testInPlaceOverwriteOfShowJSONIsSeenWithoutASyncCall() async throws {
        let folder = try ShowSpec.createShowFolder(named: "Demo", date: nil, under: parent)
        var spec = try ShowSpec.load(from: folder)
        let a = try makeArcdeck("1.9 Speaker.v1", pages: 3, in: folder)
        spec.items = [ShowSpec.Item(id: "1.9", title: "Speaker", source: "decks/1.9 Speaker.pptx", kind: .powerpoint, status: .ready, versions: [version(1, a)], current: 1)]
        try spec.write(to: folder)
        let dm = DeckManager(previewEngine: SlideEngine(), previewCache: PageCache(), liveEngine: SlideEngine(), liveCache: PageCache(), timerEngine: TimerEngine())
        let session = ShowFolderSession(deckManager: dm, displayManager: DisplayManager(), music: nil, persisting: false)
        session.pollInterval = 0.2
        _ = await session.open(folder: folder, restoreState: false)
        await settle(dm)

        // The bytes ShowSpec would write, delivered the way scp delivers them:
        // the existing show.json truncated and rewritten in place (same vnode).
        let b = try makeArcdeck("1.9 Speaker.v2", pages: 4, in: folder)
        spec = try ShowSpec.load(from: folder)
        spec.items[0].versions.append(version(2, b)); spec.items[0].current = 2
        let scratch = try ShowSpec.createShowFolder(named: "Scratch", date: nil, under: parent)
        try spec.write(to: scratch)
        let bytes = try Data(contentsOf: scratch.appendingPathComponent("show.json"))
        let fh = try FileHandle(forWritingTo: folder.appendingPathComponent("show.json"))
        try fh.truncate(atOffset: 0); try fh.write(contentsOf: bytes); try fh.close()

        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, session.state(for: dm.decks[0])?.newerVersionReady != true { try? await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(session.state(for: dm.decks[0])?.newerVersionReady == true, "an in-place write must be noticed without POST /show/sync")
    }
    func testMaterializationChecksWhatTheManifestNamesNotWhatIsThere() throws {
        let folder = try ShowSpec.createShowFolder(named: "Demo", date: nil, under: parent)
        let rel = try makeArcdeck("1.9 Speaker.v1", pages: 2, in: folder)
        let deck = folder.appendingPathComponent(rel)
        XCTAssertEqual(Materialization.check(deck, requestDownload: false), .init(local: 2, total: 2), "manifest + slides.pdf, both here")
        // The manifest names a clip that has not arrived yet.
        var m = try XCTUnwrap(DeckManifest.load(from: deck.appendingPathComponent("manifest.json")).manifest)
        m.slides[0].file = "media/slide_001.mov"
        try m.write(to: deck.appendingPathComponent("manifest.json"))
        let r = Materialization.check(deck, requestDownload: false)
        XCTAssertEqual(r.local, 2); XCTAssertEqual(r.total, 3); XCTAssertFalse(r.isLocal); XCTAssertEqual(r.missing, ["media/slide_001.mov"])
        // No manifest at all is not local either (the directory is still filling).
        try FileManager.default.removeItem(at: deck.appendingPathComponent("manifest.json"))
        XCTAssertFalse(Materialization.check(deck, requestDownload: false).isLocal)
    }
    // MARK: step 5: the crash guard's launch arguments
    func testCrashGuardArgumentsNameTheParentDisplayAppAndPort() {
        let a = CrashGuard.arguments(parent: 4242, display: 69734400, app: URL(fileURLWithPath: "/Users/you/Desktop/ARC Presenter.app"), apiPort: 8760)
        XCTAssertEqual(a, ["--parent", "4242", "--app", "/Users/you/Desktop/ARC Presenter.app", "--api", "8760", "--display", "69734400"])
        XCTAssertFalse(CrashGuard.arguments(parent: 1, display: nil, app: URL(fileURLWithPath: "/a"), apiPort: 1).contains("--display"))
    }
    func testLastFrameStoreRoundTripsAnImage() throws {
        let w = 64, h = 36
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let img = try XCTUnwrap(ctx.makeImage())
        let url = parent.appendingPathComponent("lf.bgra")
        LastFrameStore.writeNow(img)
        try FileManager.default.copyItem(at: LastFrameStore.url, to: url)
        let back = try XCTUnwrap(LastFrameStore.read(from: url))
        XCTAssertEqual(back.width, w); XCTAssertEqual(back.height, h); XCTAssertEqual(back.pixels.count, back.bytesPerRow * h)
        XCTAssertEqual(back.pixels[0], 255, "blue in BGRA: first byte is B")
        XCTAssertNotNil(LastFrameStore.image(from: url))
        XCTAssertTrue(CrashGuard.arguments(parent: 1, display: 2, app: URL(fileURLWithPath: "/a"), apiPort: 1, sdi: 77, fps: 50).suffix(4) == ["--sdi", "77", "--fps", "50.0"])
    }
}
