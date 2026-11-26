//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import PDFKit
import AppKit
import ARCShowFormat

/// V3 show folder: items from decks/, versioned captures of stills sources
/// (no PowerPoint needed), the ledger, preflight, per-slide hashes.
@MainActor
final class ShowFolderTests: XCTestCase {
    var parent: URL!

    override func setUp() {
        super.setUp()
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("shows-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: parent); super.tearDown() }

    private func writePDF(pages: Int, to url: URL) {
        let doc = PDFDocument(); for _ in 0..<pages { doc.insert(PDFPage(), at: doc.pageCount) }
        XCTAssertTrue(doc.write(to: url))
    }
    private func writePNG(to url: URL) throws {
        let img = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        let tiff = try XCTUnwrap(img.tiffRepresentation); let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    func testItemIDsFromFileNames() {
        XCTAssertEqual(ShowFolderStore.itemID(from: "1.06 Smith.pptx").id, "1.06")
        XCTAssertEqual(ShowFolderStore.itemID(from: "1.06 Smith.pptx").title, "Smith")
        XCTAssertEqual(ShowFolderStore.itemID(from: "2.10_Closing Remarks.pdf").id, "2.10")
        XCTAssertEqual(ShowFolderStore.itemID(from: "2.10_Closing Remarks.pdf").title, "Closing Remarks")
        XCTAssertEqual(ShowFolderStore.itemID(from: "Keynote.key").id, "Keynote")
    }

    /// The capture records the hash rescan compares. They drifted once (2026-09-17) and a Google deck from a
    /// Drive folder read "source changed" the moment it was captured.
    func testAGoogleItemsCaptureHashIsTheOneRescanCompares() throws {
        let store = try ShowFolderStore.create(name: "Links", date: nil, under: parent)
        let link = store.sub(.decks).appendingPathComponent("0.92 Static Slides.url")
        let url = "https://docs.google.com/presentation/d/abc/edit"
        try "[InternetShortcut]\nURL=\(url)\nModified=2026-07-14T21:06:20Z\n".write(to: link, atomically: true, encoding: .utf8)
        store.rescan()
        let item = try XCTUnwrap(store.spec.items.first { $0.id == "0.92" })
        XCTAssertEqual(item.kind, .googleSlides)
        XCTAssertEqual(store.linkFile(of: item)?.lastPathComponent, "0.92 Static Slides.url")
        let dated = ShowFolderStore.linkHash(source: url, linkFile: try String(contentsOf: link, encoding: .utf8))
        XCTAssertEqual(store.sourceHash(of: item), dated)
        XCTAssertNotEqual(store.sourceHash(of: item), SlideHasher.hex(Data(url.utf8)), "the bare URL is what the capture used to record")
    }

    /// The ONE show deck is versioned like any item, with a key per page, so Presenter can stage the next one
    /// beside a live one. It used to be rebuilt in place under one name.
    func testTheShowDeckIsANewVersionEveryTimeWithAKeyPerPage() async throws {
        let store = try ShowFolderStore.create(name: "One Deck", date: nil, under: parent)
        let decks = store.sub(.decks)
        writePDF(pages: 2, to: decks.appendingPathComponent("1.01 A.pdf"))
        writePDF(pages: 1, to: decks.appendingPathComponent("1.02 B.pdf"))
        store.rescan(); await store.capturePending()
        await store.buildStack()
        let v1 = try XCTUnwrap(store.spec.showDeck?.currentVersion)
        XCTAssertEqual(v1.arcdeck, "arcdecks/One Deck.show.v1.arcdeck")
        XCTAssertEqual(store.spec.mergedDeck, v1.arcdeck)
        XCTAssertTrue(v1.verified)
        let keys1 = try XCTUnwrap(v1.slideHashes)
        XCTAssertEqual(keys1.count, 6, "logo, A1, A2, logo, B1, logo")
        XCTAssertEqual(keys1.first, "logo|after:start"); XCTAssertEqual(keys1[3], "logo|after:1.01"); XCTAssertEqual(keys1.last, "logo|after:1.02")
        XCTAssertTrue(store.showDeckIsCurrent)
        XCTAssertEqual(store.spec.roster.map(\.id), [ShowSpec.showDeckID], "Presenter opens ONE tab")

        // A talk comes back with a page more: the show deck is out of date until it is built again, as v2.
        writePDF(pages: 3, to: decks.appendingPathComponent("1.01 A.pdf"))
        store.rescan(); await store.capturePending()
        XCTAssertFalse(store.showDeckIsCurrent)
        await store.buildStack()
        let deck = try XCTUnwrap(store.spec.showDeck)
        XCTAssertEqual(deck.current, 2); XCTAssertEqual(deck.versions.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder.appendingPathComponent(v1.arcdeck).path), "v1 is never replaced under a Presenter that has it open")
        let keys2 = try XCTUnwrap(deck.currentVersion?.slideHashes)
        XCTAssertEqual(keys2.count, 7)
        XCTAssertEqual(keys2.firstIndex(of: "logo|after:1.01"), 4, "the holding slide after the first talk moved one page down, and is found")
        XCTAssertEqual(keys2.last, keys1.last)
    }

    /// Sessions inside the ONE show deck: "S2.0 Holding Slide" is session 2's logo page, and the page where a
    /// session starts is labelled for the operator. Holding slides are never talks.
    func testASessionsOwnHoldingSlideAnnouncesItAndTheDividerIsLabelled() async throws {
        let store = try ShowFolderStore.create(name: "Two Sessions", date: nil, under: parent)
        let decks = store.sub(.decks)
        try writePNG(to: decks.appendingPathComponent("0.00 Holding Slide Show.png"))
        writePDF(pages: 1, to: decks.appendingPathComponent("1.01 A.pdf"))
        try writePNG(to: decks.appendingPathComponent("2.00 Holding Slide Afternoon.png"))
        writePDF(pages: 1, to: decks.appendingPathComponent("2.01 B.pdf"))
        writePDF(pages: 1, to: decks.appendingPathComponent("2.02 C.pdf"))
        store.rescan(); await store.capturePending()
        XCTAssertEqual(store.holdingItems.map(\.id), ["0.00", "2.00"])
        XCTAssertEqual(store.showDeckItems.map(\.id), ["1.01", "2.01", "2.02"], "a holding slide is the logo page, not a talk")
        await store.buildStack()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder.appendingPathComponent("bumper.png").path))
        XCTAssertNotNil(store.bumperURL(session: 2)); XCTAssertNil(store.bumperURL(session: 1), "session 1 has none: the show's stands in")
        let deck = try XCTUnwrap(store.showDeckURL)
        let manifest = try XCTUnwrap(DeckManifest.load(from: deck.appendingPathComponent("manifest.json")).manifest)
        let pages = manifest.slides.sorted { $0.slide < $1.slide }
        XCTAssertEqual(pages.map { $0.role?.rawValue ?? "talk" }, ["opening", "talk", "between", "talk", "between", "talk", "closing"])
        XCTAssertEqual(pages.map(\.title), ["SESSION 1", nil, "SESSION 2", nil, nil, nil, nil], "the page where a session starts says so; the one inside a session does not")
    }

    func testCreateRescanCaptureAndVersionOnChange() async throws {
        let store = try ShowFolderStore.create(name: "Test Show", date: "2026-10-02", under: parent)
        let decks = store.sub(.decks)
        writePDF(pages: 2, to: decks.appendingPathComponent("1.02 Handout.pdf"))
        try writePNG(to: decks.appendingPathComponent("1.01 Title.png"))
        try Data("x".utf8).write(to: decks.appendingPathComponent("notes.txt"))
        store.rescan()
        XCTAssertEqual(store.spec.orderedItems.map(\.id), ["1.01", "1.02"], "run order, text files ignored")
        XCTAssertEqual(store.spec.items.map(\.status), [.pending, .pending])
        XCTAssertEqual(store.pendingItems.count, 2)

        await store.capturePending()
        let handout = try XCTUnwrap(store.spec.items.first { $0.id == "1.02" })
        XCTAssertEqual(handout.status, .ready)
        XCTAssertEqual(handout.current, 1)
        XCTAssertEqual(handout.currentVersion?.arcdeck, "arcdecks/1.02 Handout.v1.arcdeck")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder.appendingPathComponent("arcdecks/1.02 Handout.v1.arcdeck/slides.pdf").path))
        XCTAssertEqual(handout.currentVersion?.slideHashes?.count, 2)
        XCTAssertTrue(handout.currentVersion?.verified ?? false)
        let title = try XCTUnwrap(store.spec.items.first { $0.id == "1.01" })
        XCTAssertEqual(title.status, .ready)

        // The presenter re-sends the handout with three pages.
        writePDF(pages: 3, to: decks.appendingPathComponent("1.02 Handout.pdf"))
        store.rescan()
        XCTAssertEqual(store.spec.items.first { $0.id == "1.02" }?.status, .updated, "a changed source is flagged")
        XCTAssertEqual(store.pendingItems.map(\.id), ["1.02"])
        await store.capturePending()
        let v2 = try XCTUnwrap(store.spec.items.first { $0.id == "1.02" })
        XCTAssertEqual(v2.status, .ready)
        XCTAssertEqual(v2.current, 2)
        XCTAssertEqual(v2.versions.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder.appendingPathComponent("arcdecks/1.02 Handout.v1.arcdeck").path), "v1 is never overwritten")
        XCTAssertEqual(v2.currentVersion?.slideHashes?.count, 3)

        // Reopen from disk: the ledger is in show.json.
        let again = try ShowFolderStore(folder: store.folder)
        XCTAssertEqual(again.spec.items.first { $0.id == "1.02" }?.current, 2)
        XCTAssertEqual(again.pendingItems.count, 0)

        let passed = await again.preflight()
        XCTAssertTrue(passed, again.preflightRows.filter { !$0.ok }.map(\.detail).joined(separator: "|"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: again.folder.appendingPathComponent("reports/preflight.json").path))
    }

    func testPreflightFlagsMissingSourceAndUncaptured() async throws {
        let store = try ShowFolderStore.create(name: "Bad Show", date: nil, under: parent)
        writePDF(pages: 1, to: store.sub(.decks).appendingPathComponent("1.01 A.pdf"))
        store.rescan()
        let passed = await store.preflight()
        XCTAssertFalse(passed)
        XCTAssertEqual(store.preflightRows.first { $0.id == "1.01" }?.detail, "not captured")
        await store.capturePending()
        try FileManager.default.removeItem(at: store.sub(.decks).appendingPathComponent("1.01 A.pdf"))
        store.rescan()
        XCTAssertTrue(store.spec.items[0].notes?.hasPrefix("source missing") ?? false)
        let passed2 = await store.preflight()
        XCTAssertFalse(passed2)
        XCTAssertTrue(store.preflightRows.first { $0.id == "1.01" }?.detail.hasPrefix("source missing") ?? false)
    }

    func testPptxSlideHashesChangeOnlyForEditedSlides() throws {
        func makePPTX(slide2: String) throws -> URL {
            let dir = parent.appendingPathComponent("pptx-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("ppt/slides/_rels"), withIntermediateDirectories: true)
            for (n, body) in [(1, "one"), (2, slide2), (3, "three")] {
                try "<p:sld>\(body)</p:sld>".write(to: dir.appendingPathComponent("ppt/slides/slide\(n).xml"), atomically: true, encoding: .utf8)
            }
            try "<Relationships/>".write(to: dir.appendingPathComponent("ppt/slides/_rels/slide2.xml.rels"), atomically: true, encoding: .utf8)
            let zip = parent.appendingPathComponent("deck-\(UUID().uuidString).pptx")
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); p.currentDirectoryURL = dir
            p.arguments = ["-q", "-r", zip.path, "ppt"]; p.standardOutput = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            return zip
        }
        let a = SlideHasher.pptxSlideHashes(try makePPTX(slide2: "two"))
        let b = SlideHasher.pptxSlideHashes(try makePPTX(slide2: "two edited"))
        XCTAssertEqual(a.count, 3); XCTAssertEqual(b.count, 3)
        XCTAssertEqual(a[0], b[0]); XCTAssertEqual(a[2], b[2]); XCTAssertNotEqual(a[1], b[1])
        XCTAssertEqual(SlideHasher.changedSlides(old: a, new: b), [2])
        // An inserted slide shifts nothing: the unchanged ones are still known.
        XCTAssertEqual(SlideHasher.changedSlides(old: a, new: [a[0], "newhash", a[1], a[2]]), [2])
    }

    /// Notes are keyed by the deck's PAGE: an opening logo page and a hidden slide both shift it against the source.
    func testSpeakerNotesAreWrittenByPage() throws {
        let dir = parent.appendingPathComponent("notes-src")
        for sub in ["ppt/slides/_rels", "ppt/notesSlides", "ppt/_rels"] { try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true) }
        try "<p:presentation><p:sldIdLst><p:sldId id=\"256\" r:id=\"rId1\"/><p:sldId id=\"257\" r:id=\"rId2\"/><p:sldId id=\"258\" r:id=\"rId3\"/></p:sldIdLst></p:presentation>"
            .write(to: dir.appendingPathComponent("ppt/presentation.xml"), atomically: true, encoding: .utf8)
        try ("<Relationships>" + (1...3).map { "<Relationship Id=\"rId\($0)\" Target=\"slides/slide\($0).xml\"/>" }.joined() + "</Relationships>")
            .write(to: dir.appendingPathComponent("ppt/_rels/presentation.xml.rels"), atomically: true, encoding: .utf8)
        for n in 1...3 {
            try "<p:sld/>".write(to: dir.appendingPathComponent("ppt/slides/slide\(n).xml"), atomically: true, encoding: .utf8)
            try "<Relationships><Relationship Id=\"rId9\" Target=\"../notesSlides/notesSlide\(n).xml\"/></Relationships>"
                .write(to: dir.appendingPathComponent("ppt/slides/_rels/slide\(n).xml.rels"), atomically: true, encoding: .utf8)
            try "<p:notes><p:sp><p:nvPr><p:ph type=\"body\"/></p:nvPr><a:p><a:r><a:t>Note \(n): Q&amp;A</a:t></a:r></a:p></p:sp></p:notes>"
                .write(to: dir.appendingPathComponent("ppt/notesSlides/notesSlide\(n).xml"), atomically: true, encoding: .utf8)
        }
        let pptx = parent.appendingPathComponent("Talk.pptx")
        let z = Process(); z.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); z.currentDirectoryURL = dir
        z.arguments = ["-q", "-r", pptx.path, "ppt"]; z.standardOutput = FileHandle.nullDevice; try z.run(); z.waitUntilExit()

        // The deck: opening logo page, slide 1, (slide 2 hidden: no page), slide 3, closing logo page.
        let deck = parent.appendingPathComponent("Talk.arcdeck"); try FileManager.default.createDirectory(at: deck, withIntermediateDirectories: true)
        var open = DeckManifest.Slide(slide: 1, type: .image); open.role = .opening
        var close = DeckManifest.Slide(slide: 4, type: .image); close.role = .closing
        try DeckManifest(slides: [open, .init(slide: 2, type: .image, pptxSlide: 1), .init(slide: 3, type: .image, pptxSlide: 3), close]).write(to: deck.appendingPathComponent("manifest.json"))
        XCTAssertEqual(DeckNotes.write(source: pptx, into: deck), 2)
        let notes = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: deck.appendingPathComponent("notes.json")))
        XCTAssertEqual(notes, ["2": "Note 1: Q&A", "3": "Note 3: Q&A"], "by page, entities resolved, the hidden slide's note left out")
        XCTAssertEqual(DeckNotes.write(source: parent.appendingPathComponent("x.pdf"), into: deck), 0)
    }

    func testThePreflightRaisesMediaThatNeverStarted() throws {
        let url = parent.appendingPathComponent("report.json")
        let report: [String: Any] = ["ok": true, "warnings": ["slide 3: movie runs 101 s, recorded in full",
            "slide 3: movie did not start (still on its poster frame 8 s after its click); moving on",
            "slide 20: playback stopped 58 s into the movie (picture and sound both still for 8 s); clip ends there"]]
        try JSONSerialization.data(withJSONObject: report).write(to: url)
        let raised = ShowFolderStore.mediaWarnings(inReport: url)
        XCTAssertEqual(raised.count, 2)
        XCTAssertTrue(raised[0].hasPrefix("slide 3: movie did not start"))
        XCTAssertEqual(ShowFolderStore.mediaWarnings(inReport: nil), [])
        XCTAssertEqual(ShowFolderStore.mediaWarnings(inReport: parent.appendingPathComponent("absent.json")), [])
    }

    /// A slide inserted second is slide4.xml on disk but position 2 in the
    /// show: the hashes follow p:sldIdLst, so index i is what `go to slide i` shows.
    func testPptxSlideHashesFollowPresentationOrderNotFileNumbers() throws {
        func makePPTX(order: [Int]?) throws -> URL {
            let dir = parent.appendingPathComponent("pptx-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("ppt/slides"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("ppt/_rels"), withIntermediateDirectories: true)
            for n in 1...4 { try "<p:sld>body \(n)</p:sld>".write(to: dir.appendingPathComponent("ppt/slides/slide\(n).xml"), atomically: true, encoding: .utf8) }
            if let order {
                let ids = order.enumerated().map { "<p:sldId id=\"\(256 + $0.offset)\" r:id=\"rId\($0.element + 10)\"/>" }.joined()
                try "<p:presentation><p:sldMasterIdLst><p:sldMasterId id=\"1\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>\(ids)</p:sldIdLst></p:presentation>"
                    .write(to: dir.appendingPathComponent("ppt/presentation.xml"), atomically: true, encoding: .utf8)
                let rels = (1...4).map { "<Relationship Id=\"rId\($0 + 10)\" Type=\"slide\" Target=\"slides/slide\($0).xml\"/>" }.joined()
                try "<Relationships><Relationship Id=\"rId1\" Type=\"slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>\(rels)</Relationships>"
                    .write(to: dir.appendingPathComponent("ppt/_rels/presentation.xml.rels"), atomically: true, encoding: .utf8)
            }
            let zip = parent.appendingPathComponent("deck-\(UUID().uuidString).pptx")
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); p.currentDirectoryURL = dir
            p.arguments = ["-q", "-r", zip.path, "ppt"]; p.standardOutput = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            return zip
        }
        let byFile = SlideHasher.pptxSlideHashes(try makePPTX(order: nil))
        XCTAssertEqual(byFile.count, 4, "no presentation.xml: file order is the fallback")
        let shown = SlideHasher.pptxSlideHashes(try makePPTX(order: [1, 4, 2, 3]))
        XCTAssertEqual(shown, [byFile[0], byFile[3], byFile[1], byFile[2]])
        XCTAssertEqual(SlideHasher.presentationOrder(
            presentationXML: "<p:sldIdLst><p:sldId id=\"256\" r:id=\"rId9\"/></p:sldIdLst>", relsXML: "<Relationships/>"), [], "an id that does not resolve")
    }

    func testPdfPageHashesSeeContentChanges() throws {
        let u1 = parent.appendingPathComponent("a.pdf"), u2 = parent.appendingPathComponent("b.pdf")
        writePDF(pages: 2, to: u1)
        let doc = PDFDocument(); doc.insert(PDFPage(), at: 0)
        doc.insert(PDFPage(image: NSImage(size: NSSize(width: 200, height: 100), flipped: false) { r in NSColor.blue.setFill(); r.fill(); return true })!, at: 1)
        XCTAssertTrue(doc.write(to: u2))
        let h1 = SlideHasher.pdfPageHashes(u1), h2 = SlideHasher.pdfPageHashes(u2)
        XCTAssertEqual(h1.count, 2); XCTAssertEqual(h2.count, 2)
        XCTAssertEqual(h1[0], h2[0], "an identical blank page hashes the same")
        XCTAssertNotEqual(h1[1], h2[1], "a picture page differs")
    }
}

// MARK: - Changed-slides recapture

@MainActor
final class RecaptureTests: XCTestCase {
    func testPlanReusesOnlySlidesWhosePredecessorIsUnchanged() {
        let old = ["a", "b", "c", "d", "e"]
        // Slide 3 edited.
        switch RecapturePlan.make(oldHashes: old, newHashes: ["a", "b", "C", "d", "e"]) {
        case .partial(let ranges, let changed, let reuse):
            XCTAssertEqual(changed, [3, 4], "slide 4's clip carries slide 3's builds and transition, so it is recaptured too")
            XCTAssertEqual(ranges, [2...5], "one range, started one slide early for the transition in and one late for the last changed slide's builds")
            XCTAssertEqual(reuse, [1: 1, 2: 2, 5: 5])
        default: XCTFail("expected partial")
        }
        // Re-saved, nothing changed.
        XCTAssertEqual(RecapturePlan.make(oldHashes: old, newHashes: old), .unchanged)
        // A slide inserted after 2: the later slides are unchanged pairs, so only the new one and its follower move.
        switch RecapturePlan.make(oldHashes: old, newHashes: ["a", "b", "X", "c", "d", "e"]) {
        case .partial(let ranges, let changed, let reuse):
            XCTAssertEqual(changed, [3, 4])
            XCTAssertEqual(ranges, [2...5])
            XCTAssertEqual(reuse[5], 4); XCTAssertEqual(reuse[6], 5); XCTAssertEqual(reuse[1], 1)
        default: XCTFail("expected partial")
        }
        // Two islands become two ranges; touching ones merge.
        switch RecapturePlan.make(oldHashes: Array(repeating: "z", count: 0) + ["a","b","c","d","e","f","g","h","i","j"],
                                  newHashes: ["A","b","c","d","e","F","g","h","i","j"]) {
        case .partial(let ranges, let changed, _):
            XCTAssertEqual(changed, [1, 2, 6, 7])
            XCTAssertEqual(ranges, [1...3, 5...8])
        default: XCTFail("expected partial")
        }
        // Most slides changed: capture the whole show.
        if case .full = RecapturePlan.make(oldHashes: old, newHashes: ["A", "B", "C", "D", "e"]) {} else { XCTFail("expected full") }
        if case .full = RecapturePlan.make(oldHashes: [], newHashes: old) {} else { XCTFail("no ledger = full") }
        // Hidden slides are never in the changed set.
        switch RecapturePlan.make(oldHashes: old, newHashes: ["a", "b", "C", "d", "e"], hidden: [3]) {
        case .partial(_, let changed, _): XCTAssertEqual(changed, [4])
        default: XCTFail("expected partial")
        }
    }

    func testMergeTakesReusedPagesFromOldAndChangedFromRanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func deck(_ name: String, pptx: [Int], clipOn: Set<Int>, text: String) throws -> URL {
            let u = dir.appendingPathComponent("\(name).arcdeck")
            try FileManager.default.createDirectory(at: u.appendingPathComponent("media"), withIntermediateDirectories: true)
            let pdf = PDFDocument()
            var slides: [DeckManifest.Slide] = []
            for (i, p) in pptx.enumerated() {
                pdf.insert(PDFPage(image: NSImage(size: NSSize(width: 160, height: 90), flipped: false) { r in
                    NSColor.white.setFill(); r.fill(); ("\(text)\(p)" as NSString).draw(at: .zero, withAttributes: [.font: NSFont.systemFont(ofSize: 40)]); return true })!, at: i)
                var s = DeckManifest.Slide(slide: i + 1, type: clipOn.contains(p) ? .video : .image, pptxSlide: p)
                if clipOn.contains(p) {
                    let rel = "media/slide_\(String(format: "%03d", i + 1)).mov"
                    try Data("\(name)-clip-\(p)".utf8).write(to: u.appendingPathComponent(rel)); s.file = rel; s.clicks = [1.0]
                }
                slides.append(s)
            }
            XCTAssertTrue(pdf.write(to: u.appendingPathComponent("slides.pdf")))
            try DeckManifest(slides: slides).write(to: u.appendingPathComponent("manifest.json"))
            return u
        }
        let old = try XCTUnwrap(IncrementalMerger.Source(deck: try deck("old", pptx: [1, 2, 3, 4, 5], clipOn: [2, 5], text: "old")))
        let range = try XCTUnwrap(IncrementalMerger.Source(deck: try deck("range", pptx: [2, 3, 4], clipOn: [3], text: "new")))
        let out = dir.appendingPathComponent("merged.arcdeck")
        try IncrementalMerger.merge(order: [1, 2, 3, 4, 5], reuse: [1: 1, 2: 2, 5: 5], old: old, ranges: [range], wanted: [3, 4], into: out)
        let m = try XCTUnwrap(DeckManifest.load(from: out.appendingPathComponent("manifest.json")).manifest)
        XCTAssertEqual(m.slides.map(\.slide), [1, 2, 3, 4, 5])
        XCTAssertEqual(m.slides.map(\.pptxSlide), [1, 2, 3, 4, 5])
        XCTAssertEqual(m.slides[1].file, "media/slide_002.mov")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("media/slide_002.mov"), encoding: .utf8), "old-clip-2", "reused clip comes from the old version")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("media/slide_003.mov"), encoding: .utf8), "range-clip-3", "changed clip comes from the range")
        XCTAssertNil(m.slides[3].file, "slide 4 is a still in the range")
        XCTAssertEqual(m.slides[4].file, "media/slide_005.mov")
        XCTAssertEqual(PDFDocument(url: out.appendingPathComponent("slides.pdf"))?.pageCount, 5)
        // A wanted slide no range captured is an error, never a silent gap.
        XCTAssertThrowsError(try IncrementalMerger.merge(order: [1, 2, 3, 4, 5, 6], reuse: [1: 1], old: old, ranges: [range], wanted: [6], into: dir.appendingPathComponent("bad.arcdeck")))
    }

    /// The merger used to copy only `file` and `entryFile`, so a version-3 slide arrived in the merged deck with
    /// its manifest still pointing at build clips and stills that had been left behind: every one of them a
    /// DeckVerifier problem. A build that is a CUT (no clip, still only) must survive as a cut, not throw.
    func testMergeCarriesBuildClipsAndStills() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("merge3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func writePNG(to url: URL) throws {
            let img = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
            let tiff = try XCTUnwrap(img.tiffRepresentation); let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        }
        func deck(_ name: String, pptx: [Int], buildsOn: Set<Int>) throws -> URL {
            let u = dir.appendingPathComponent("\(name).arcdeck")
            for sub in ["media", "stills"] {
                try FileManager.default.createDirectory(at: u.appendingPathComponent(sub), withIntermediateDirectories: true)
            }
            let pdf = PDFDocument()
            var slides: [DeckManifest.Slide] = []
            for (i, p) in pptx.enumerated() {
                pdf.insert(PDFPage(image: NSImage(size: NSSize(width: 160, height: 90), flipped: false) { r in
                    NSColor.white.setFill(); r.fill(); return true })!, at: i)
                var s = DeckManifest.Slide(slide: i + 1, type: .image, pptxSlide: p)
                if buildsOn.contains(p) {
                    let tag = String(format: "slide_%03d", i + 1)
                    let first = "stills/\(tag)_s00.png"
                    try writePNG(to: u.appendingPathComponent(first))
                    s.initialStill = first
                    // Build 1 has a clip. Build 2 is a CUT: still only.
                    let clip = "media/\(tag)_b01.mov"
                    try Data("\(name)-build-\(p)".utf8).write(to: u.appendingPathComponent(clip))
                    let s1 = "stills/\(tag)_s01.png", s2 = "stills/\(tag)_s02.png"
                    try writePNG(to: u.appendingPathComponent(s1))
                    try writePNG(to: u.appendingPathComponent(s2))
                    s.builds = [.init(file: clip, still: s1, duration: 0.4), .init(file: nil, still: s2)]
                }
                slides.append(s)
            }
            XCTAssertTrue(pdf.write(to: u.appendingPathComponent("slides.pdf")))
            try DeckManifest(slides: slides).write(to: u.appendingPathComponent("manifest.json"))
            return u
        }

        // Slide 2 carries builds and is REUSED from the old version, so its media only reaches the merged
        // deck if the merger copies it; slide 3 is recaptured and carries builds from the range.
        let old = try XCTUnwrap(IncrementalMerger.Source(deck: try deck("old", pptx: [1, 2, 3], buildsOn: [2])))
        let range = try XCTUnwrap(IncrementalMerger.Source(deck: try deck("range", pptx: [3], buildsOn: [3])))
        let out = dir.appendingPathComponent("merged3.arcdeck")
        try IncrementalMerger.merge(order: [1, 2, 3], reuse: [1: 1, 2: 2], old: old, ranges: [range], wanted: [3], into: out)

        let m = try XCTUnwrap(DeckManifest.load(from: out.appendingPathComponent("manifest.json")).manifest)
        let reused = m.slides[1], recaptured = m.slides[2]

        XCTAssertEqual(reused.initialStill, "stills/slide_002_s00.png")
        XCTAssertEqual(reused.builds?.count, 2)
        XCTAssertEqual(reused.builds?[0].file, "media/slide_002_b01.mov")
        XCTAssertEqual(reused.builds?[0].still, "stills/slide_002_s01.png")
        XCTAssertEqual(reused.builds?[0].duration, 0.4, "a build's duration is not lost in the move")
        XCTAssertNil(reused.builds?[1].file, "a CUT build stays a cut")
        XCTAssertEqual(reused.builds?[1].still, "stills/slide_002_s02.png")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("media/slide_002_b01.mov"), encoding: .utf8),
                       "old-build-2", "the reused slide's build clip came from the old version")

        // The range deck had this slide at page 1; in the merged deck it is page 3 and every path is renumbered.
        XCTAssertEqual(recaptured.builds?[0].file, "media/slide_003_b01.mov")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("media/slide_003_b01.mov"), encoding: .utf8),
                       "range-build-3", "the recaptured slide's build clip came from the range")

        // What DeckVerifier checks: every referenced file is really there.
        for slide in m.slides {
            for rel in slide.mediaFiles + slide.stillFiles {
                XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent(rel).path), "\(rel) missing from the merged deck")
            }
        }
    }
}
