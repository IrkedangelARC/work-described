//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import PDFKit
@testable import ArcPresenter

/// Stability plan phase 3: show log, health rules, pre-show check.
@MainActor
final class Phase3Tests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("p3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testLogRotationKeepsFiveAndShiftsInOrder() throws {
        let dir = try tempDir()
        try "run A".write(to: dir.appendingPathComponent("show.log"), atomically: true, encoding: .utf8)
        try "run B".write(to: dir.appendingPathComponent("show.1.log"), atomically: true, encoding: .utf8)
        try "run E".write(to: dir.appendingPathComponent("show.4.log"), atomically: true, encoding: .utf8)
        ShowLog.rotate(at: dir, keep: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("show.log").path), "the current file moved aside")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("show.1.log"), encoding: .utf8), "run A")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("show.2.log"), encoding: .utf8), "run B")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("show.5.log").path), "the oldest beyond keep is gone (4 -> dropped, not 5)")
        // A second rotation with no new current file changes nothing.
        ShowLog.rotate(at: dir, keep: 5)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("show.1.log"), encoding: .utf8), "run A")
    }

    func testHealthRules() {
        XCTAssertEqual(HealthMonitor.diskLevel(freeGB: 50), .ok)
        XCTAssertEqual(HealthMonitor.diskLevel(freeGB: 5), .warn)
        XCTAssertEqual(HealthMonitor.diskLevel(freeGB: 1), .bad)
        XCTAssertEqual(HealthMonitor.lagLevel(ms: 20), .ok)
        XCTAssertEqual(HealthMonitor.lagLevel(ms: 200), .warn)
        XCTAssertEqual(HealthMonitor.lagLevel(ms: 900), .bad)
        XCTAssertEqual(HealthMonitor.clickerLevel(accessibility: false, tapAlive: false), .bad)
        XCTAssertEqual(HealthMonitor.clickerLevel(accessibility: true, tapAlive: false), .warn)
        XCTAssertEqual(HealthMonitor.clickerLevel(accessibility: true, tapAlive: true), .ok)
    }

    func testHealthJSONParses() throws {
        let h = HealthMonitor()
        h.refresh()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(h.json.utf8)) as? [String: Any])
        let chips = try XCTUnwrap(obj["chips"] as? [String: [String: Any]])
        for id in ["pgm", "mon", "sdi", "ppt", "clk", "disk"] { XCTAssertNotNil(chips[id], id) }
        XCTAssertNotNil(obj["uptime"])
        XCTAssertNotNil(obj["mainThreadLagMs"])
    }

    func testPreShowVerifyFlagsBadClipsAndPassesGoodDecks() async throws {
        let dir = try tempDir()
        // A PDF deck.
        let pdf = dir.appendingPathComponent("talk.pdf")
        let doc = PDFDocument(); doc.insert(PDFPage(), at: 0); doc.insert(PDFPage(), at: 1)
        XCTAssertTrue(doc.write(to: pdf))
        let good = await PreShowCheck.verify(deck: pdf, kind: "pdf")
        XCTAssertTrue(good.ok); XCTAssertEqual(good.detail, "2 pages")

        // An arcdeck whose clip is a stub file.
        let bundle = dir.appendingPathComponent("show.arcdeck")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("media"), withIntermediateDirectories: true)
        XCTAssertTrue(doc.write(to: bundle.appendingPathComponent("slides.pdf")))
        try Data("stub".utf8).write(to: bundle.appendingPathComponent("media/slide_001.mov"))
        let manifest: [String: Any] = ["version": 2, "slides": [["slide": 1, "type": "video", "file": "media/slide_001.mov"], ["slide": 2, "type": "video", "file": "media/slide_002.mov"]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: bundle.appendingPathComponent("manifest.json"))
        let bad = await PreShowCheck.verify(deck: bundle, kind: "arcdeck")
        XCTAssertFalse(bad.ok)
        XCTAssertTrue(bad.detail.contains("slide_001.mov not playable"), bad.detail)
        XCTAssertTrue(bad.detail.contains("slide_002.mov missing"), bad.detail)

        // No manifest at all.
        let noManifest = dir.appendingPathComponent("plain.arcdeck")
        try FileManager.default.createDirectory(at: noManifest, withIntermediateDirectories: true)
        XCTAssertTrue(doc.write(to: noManifest.appendingPathComponent("slides.pdf")))
        let nm = await PreShowCheck.verify(deck: noManifest, kind: "arcdeck")
        XCTAssertTrue(nm.ok, "no manifest = a legal stills deck (the shared verifier warns, Presenter loads it as stills)")
        try? FileManager.default.removeItem(at: dir)
    }

    func testEscapeBurstNeedsThreeWithinASecond() {
        let b = EscapeBurst()
        let t = Date()
        XCTAssertFalse(b.register(now: t))
        XCTAssertFalse(b.register(now: t.addingTimeInterval(0.3)))
        XCTAssertTrue(b.register(now: t.addingTimeInterval(0.6)), "third press inside the window")
        XCTAssertFalse(b.register(now: t.addingTimeInterval(0.7)), "the burst reset")
        XCTAssertFalse(b.register(now: t.addingTimeInterval(3)))
        XCTAssertFalse(b.register(now: t.addingTimeInterval(3.2)))
        XCTAssertFalse(b.register(now: t.addingTimeInterval(4.5)), "a press more than a second after the first does not count with it")
    }

    /// 2026-09-17: the chip explains the error on mouse hover.
    func testTheErrChipSaysWhatHappenedWhatItMeansAndWhatTheAppWasDoing() {
        let lines = ["2026-09-17 10:07:36.656 previous (key) -> deck",
                     "2026-09-17 10:07:36.658 live 3.01 Keynote slide 13 build 2 -> 1 of 10 (back)",
                     "2026-09-17 10:07:45.444 ERROR main thread lag 5632 ms",
                     "2026-09-17 10:07:48.412 ERROR main thread lag 1600 ms",
                     "2026-09-17 10:07:53.078 ERROR main thread lag 1266 ms",
                     "2026-09-17 10:07:53.203 DeckLink out: UltraStudio 4K Mini 1920x1080 @ 59.94",
                     "2026-09-17 10:07:56.085 PGM open on Projector 1920x1280"]
        let help = HealthMonitor.errorHelp(lines: lines, now: Date(), maxLagMs: 5632) ?? ""
        XCTAssertTrue(help.hasPrefix("LAST ERROR 10:07:53: main thread lag 1266 ms"), help)
        XCTAssertTrue(help.contains("3 errors this run, 3 in this burst from 10:07:45. Worst main thread lag this run: 5632 ms."), help)
        XCTAssertTrue(help.contains("MEANS: The app stopped responding"), help)
        XCTAssertTrue(help.contains("JUST BEFORE:\n  10:07:36  previous (key) -> deck"), help)
        XCTAssertTrue(help.contains("THEN:\n  10:07:53  DeckLink out"), help)
        XCTAssertTrue(help.contains("while SDI and the outputs were starting"), help)
        XCTAssertNil(HealthMonitor.errorHelp(lines: ["2026-09-17 10:07:36.656 previous (key) -> deck"], now: Date(), maxLagMs: 0), "no error, no hover")
        XCTAssertTrue(HealthMonitor.meaning(of: "CLIP ERROR Talk slide 4 media/x.mov: not playable").contains("shows its still"))
    }
}

/// The footer's plain words (2026-09-19: the section reworked to be clear at a glance).
final class HealthStateWordTests: XCTestCase {
    func testEveryChipHasAWordForEveryLevel() {
        for id in ["pgm", "mon", "sdi", "ppt", "clk"] {
            for level in [HealthMonitor.Level.ok, .warn, .bad, .off] {
                XCTAssertFalse(HealthMonitor.stateWord(id: id, level: level, detail: "").isEmpty, "\(id) at \(level)")
            }
        }
        XCTAssertEqual(HealthMonitor.stateWord(id: "clk", level: .bad, detail: "Accessibility NOT granted"), "NO ACCESS")
        XCTAssertEqual(HealthMonitor.stateWord(id: "ppt", level: .ok, detail: "PowerPoint LIVE on the program output"), "LIVE")
        XCTAssertEqual(HealthMonitor.stateWord(id: "ppt", level: .ok, detail: "parked and ready: x.pptx"), "READY")
        XCTAssertEqual(HealthMonitor.stateWord(id: "ppt", level: .warn, detail: "PowerPoint live but no fresh picture from its window"), "STALE")
        XCTAssertEqual(HealthMonitor.stateWord(id: "disk", level: .ok, detail: "381 GB free"), "381 GB")
        XCTAssertEqual(HealthMonitor.stateWord(id: "lag", level: .warn, detail: "", lagMs: 300), "300 MS")
        XCTAssertEqual(HealthMonitor.names["clk"], "CLICKER")
    }
}

final class SlideCounterWidthTests: XCTestCase {
    /// 28 pt counter since the one-row footer (2026-09-23): 17 pt a cell, 120 pt floor.
    func testTheCounterBoxGrowsWithTheDeck() {
        XCTAssertEqual(ARCTheme.counterWidth(pages: 52), 7 * 17 + 6, "\"52 / 52\" is seven cells")
        XCTAssertEqual(ARCTheme.counterWidth(pages: 367), 9 * 17 + 6, "\"367 / 367\" is nine cells")
        XCTAssertGreaterThan(ARCTheme.counterWidth(pages: 1024), ARCTheme.counterWidth(pages: 367))
        XCTAssertEqual(ARCTheme.counterWidth(pages: 0), 120, "a one-page deck keeps the floor")
    }
}
