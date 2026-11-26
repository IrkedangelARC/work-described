//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import AppKit
import PDFKit
import ARCShowFormat
@testable import ArcCaptureTests

/// Verify before COMPLETE (V3, plan 1.4) and STOP AND KEEP (plan 1.5).
@MainActor
final class StopAndKeepTests: XCTestCase {

    private var dir = FileManager.default.temporaryDirectory
    private var source = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = dir.appendingPathComponent("Fake.pptx")
        FileManager.default.createFile(atPath: source.path, contents: Data("deck".utf8))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeSession(_ driver: FakeDriver, _ frames: FakeFrameSource) -> CaptureSession {
        let s = CaptureSession(driver: driver, frameSource: frames, recorder: VideoRecorder())
        s.sourceFile = source
        s.outputDirectory = dir
        s.dwellTime = 0.05
        return s
    }

    private func wire(_ driver: FakeDriver, _ frames: FakeFrameSource) {
        driver.onAdvance = { pos in Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            await frames.showSlide(pos, motionFrames: pos == 1 ? 0 : 20)
        } }
        driver.onBuildClick = { slide, _ in Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            await frames.showSlide(slide * 100 + Int.random(in: 1...99), motionFrames: 6, then: false)
        } }
    }

    // MARK: - 1.5 stop and keep

    func testStopAndKeepWritesAVerifiedDeckOfWhatWasCaptured() async throws {
        let driver = FakeDriver(slides: 8), frames = FakeFrameSource()
        wire(driver, frames)
        let s = makeSession(driver, frames)

        // Press STOP AND KEEP once three slides are in hand.
        let stopper = Task { @MainActor in
            while s.slides.count < 3, s.state != .error { try? await Task.sleep(for: .milliseconds(50)) }
            await s.stopAndKeep()
        }
        let rep = try await s.run()
        _ = await stopper.value

        XCTAssertTrue(rep.ok, rep.error ?? "")
        XCTAssertFalse(rep.complete, "the deck is short and says so")
        XCTAssertEqual(rep.endedBy, "stoppedByOperator")
        XCTAssertEqual(rep.verified, true, "short, but verified")
        XCTAssertLessThan(s.slides.count, 8)
        XCTAssertGreaterThanOrEqual(s.slides.count, 3)

        let deck = try XCTUnwrap(s.outputURL)
        let verdict = await DeckVerifier.verify(arcdeck: deck)
        XCTAssertTrue(verdict.ok, verdict.detail)
        let m = try XCTUnwrap(DeckManifest.load(from: deck.appendingPathComponent("manifest.json")).manifest)
        XCTAssertEqual(m.deck?.complete, false, "the deck itself carries the fact, for Presenter")
        XCTAssertEqual(m.slides.count, verdict.pages)
        XCTAssertTrue(rep.warnings.contains { $0.contains("the operator ended the show") })
    }

    func testStopAndKeepDoesNotComplainAboutTheSlidesItNeverReached() async throws {
        let driver = FakeDriver(slides: 8), frames = FakeFrameSource()
        wire(driver, frames)
        let s = makeSession(driver, frames)
        let stopper = Task { @MainActor in
            while s.slides.count < 3, s.state != .error { try? await Task.sleep(for: .milliseconds(50)) }
            await s.stopAndKeep()
        }
        let rep = try await s.run()
        _ = await stopper.value

        XCTAssertFalse(rep.warnings.contains { $0.contains("shown by the deck but not captured") },
                       "a deck cut short on purpose is not missing slides, it is short")
        XCTAssertFalse(rep.warnings.contains { $0.contains("PowerPoint reports") })
    }

    func testStopAndKeepWithNothingCapturedKeepsNothing() async throws {
        let driver = FakeDriver(slides: 4), frames = FakeFrameSource()
        let s = makeSession(driver, frames)   // nothing wired: no slide ever settles
        let run = Task { try await s.run() }
        try? await Task.sleep(for: .milliseconds(300))
        await s.stopAndKeep()
        let rep = try await run.value

        XCTAssertFalse(rep.ok)
        XCTAssertEqual(rep.error, "cancelled", "with no slides there is nothing to keep")
        XCTAssertNil(s.outputURL)
    }

    func testANormalRunIsStillMarkedComplete() async throws {
        let driver = FakeDriver(slides: 4), frames = FakeFrameSource()
        wire(driver, frames)
        let s = makeSession(driver, frames)
        let rep = try await s.run()

        XCTAssertTrue(rep.complete)
        XCTAssertEqual(rep.endedBy, "finished")
        let m = try XCTUnwrap(DeckManifest.load(from: try XCTUnwrap(s.outputURL).appendingPathComponent("manifest.json")).manifest)
        XCTAssertNil(m.deck?.complete, "a whole deck says nothing, so older readers are unaffected")
    }

    // MARK: - 1.4 verify before COMPLETE

    func testAPDFImportIsVerifiedBeforeItIsCalledComplete() async throws {
        let pdfURL = dir.appendingPathComponent("Pages.pdf")
        let doc = PDFDocument()
        for i in 0..<3 {
            let img = NSImage(size: NSSize(width: 64, height: 36))
            img.lockFocus()
            NSColor(calibratedHue: CGFloat(i) / 3, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 64, height: 36).fill()
            img.unlockFocus()
            if let page = PDFPage(image: img) { doc.insert(page, at: doc.pageCount) }
        }
        XCTAssertTrue(doc.write(to: pdfURL))

        let s = CaptureSession(driver: FakeDriver(slides: 3), frameSource: FakeFrameSource(), recorder: VideoRecorder())
        s.sourceFile = pdfURL
        s.outputDirectory = dir
        let rep = try await s.run()

        XCTAssertTrue(rep.ok, rep.error ?? "")
        XCTAssertEqual(rep.verified, true, "the PDF path used to report COMPLETE without opening the deck")
        XCTAssertEqual(rep.verifyDetail, "3 pages, 0 clips playable")
        XCTAssertTrue(rep.complete)
    }

    func testAPageCountThatDoesNotMatchTheRunIsAFailure() async throws {
        // The shared verifier only catches a manifest that overruns the PDF.
        // A deck a page short passes it, so Capture checks the count itself.
        let deck = dir.appendingPathComponent("Short.arcdeck")
        try FileManager.default.createDirectory(at: deck, withIntermediateDirectories: true)
        let doc = PDFDocument()
        for _ in 0..<2 {
            let img = NSImage(size: NSSize(width: 64, height: 36))
            img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 64, height: 36).fill(); img.unlockFocus()
            if let page = PDFPage(image: img) { doc.insert(page, at: doc.pageCount) }
        }
        XCTAssertTrue(doc.write(to: deck.appendingPathComponent("slides.pdf")))
        try DeckManifest(slides: [.init(slide: 1, type: .image), .init(slide: 2, type: .image)])
            .write(to: deck.appendingPathComponent("manifest.json"))

        let s = CaptureSession(driver: FakeDriver(slides: 3), frameSource: FakeFrameSource(), recorder: VideoRecorder())
        s.sourceFile = source
        let plain = await DeckVerifier.verify(arcdeck: deck)
        XCTAssertTrue(plain.ok, "the shared verifier is happy with it")
        let mine = await s.verifiedDeck(at: deck, expectedPages: 3)
        XCTAssertNil(mine, "but this run captured 3 pages, so the deck is wrong")
        XCTAssertEqual(s.state, .error)
        XCTAssertTrue((s.errorMessage ?? "").contains("2 pages where this run captured 3"), s.errorMessage ?? "")
    }
}
