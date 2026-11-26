//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import AppKit
import AVFoundation
import CoreMedia
import PDFKit
import ARCShowFormat
@testable import ArcCaptureTests

/// Per-slide checkpointing and resume (V3, plan 1.1/1.2): what is written
/// while a run is going, what a crashed run leaves behind, and what a second
/// run makes of it. No PowerPoint, no screen.
@MainActor
final class CheckpointTests: XCTestCase {

    private var dir = FileManager.default.temporaryDirectory
    private var source = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = dir.appendingPathComponent("Fake.pptx")
        FileManager.default.createFile(atPath: source.path, contents: Data("deck".utf8))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: helpers

    private func solid(_ w: Int, _ h: Int, _ c: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus(); c.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill(); img.unlockFocus()
        return img
    }

    /// A one-second black clip in a temp file, standing in for a recording.
    private func clip() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 36])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for f in 0..<10 {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            adaptor.append(FakeFrameSource.pixelBuffer(width: 64, height: 36, shade: UInt8(f * 20)),
                           withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 10))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "clip")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 10)
        return url
    }

    private func result(id: Int, pptx: Int, clip: URL? = nil) -> CaptureResult {
        var r = CaptureResult(id: id, pptxSlide: pptx, slideType: clip == nil ? .image : .video,
                              image: solid(64, 36, .red), videoURL: clip, capturedAt: Date(),
                              settleMs: 250, motionFrames: clip == nil ? 0 : 40, endedBy: "settled")
        if clip != nil { r.clicks = [0.2, 0.8]; r.entryClick = 0 }
        return r
    }

    // MARK: the store

    func testASlideIsOnDiskAndItsBitmapIsReleased() throws {
        let cp = try CaptureCheckpoint(baseName: "Fake", in: dir, source: source)
        let movie = try clip()
        let stored = try cp.append(result(id: 1, pptx: 1, clip: movie))

        XCTAssertTrue(stored.isCheckpointed, "the 2x bitmap is gone and the page is a file")
        XCTAssertNotNil(stored.thumb, "the filmstrip still has something to draw")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cp.dir.appendingPathComponent("pages/slide_001.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cp.dir.appendingPathComponent("media/slide_001.mov").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path), "the clip was moved out of /tmp, not copied")
        XCTAssertEqual(stored.videoURL, cp.dir.appendingPathComponent("media/slide_001.mov"))
        XCTAssertNotNil(stored.image.tiffRepresentation, "the page reads back from disk when the writer asks")

        let p = try XCTUnwrap(CaptureCheckpoint.readProgress(at: cp.dir))
        XCTAssertEqual(p.slides.count, 1)
        XCTAssertEqual(p.lastPptxSlide, 1)
        XCTAssertEqual(p.source, source.path)
    }

    func testRestoreRebuildsEverySlideTheDeckNeeds() throws {
        let cp = try CaptureCheckpoint(baseName: "Fake", in: dir, source: source)
        _ = try cp.append(result(id: 1, pptx: 1))
        _ = try cp.append(result(id: 2, pptx: 2, clip: try clip()))
        _ = try cp.append(result(id: 3, pptx: 3))

        let restored = try XCTUnwrap(CaptureCheckpoint.restore(from: cp.dir))
        XCTAssertEqual(restored.slides.count, 3)
        XCTAssertEqual(restored.slides.map(\.pptxSlide), [1, 2, 3])
        XCTAssertEqual(restored.slides.map(\.slideType), [.image, .video, .image])
        XCTAssertEqual(restored.slides[1].clicks, [0.2, 0.8])
        XCTAssertEqual(restored.slides[1].entryClick, 0)
        XCTAssertTrue(restored.slides.allSatisfy(\.isCheckpointed))
        XCTAssertTrue(restored.slides.allSatisfy { $0.thumb != nil })
        XCTAssertEqual(restored.progress.lastPptxSlide, 3)
    }

    func testRestoreStopsAtTheFirstSlideWhoseFilesAreGone() throws {
        let cp = try CaptureCheckpoint(baseName: "Fake", in: dir, source: source)
        for n in 1...3 { _ = try cp.append(result(id: n, pptx: n)) }
        try FileManager.default.removeItem(at: cp.dir.appendingPathComponent("pages/slide_002.jpg"))

        let restored = try XCTUnwrap(CaptureCheckpoint.restore(from: cp.dir))
        XCTAssertEqual(restored.slides.count, 1, "slide 2 is unreadable, so 2 and 3 are both given up")
    }

    func testAnEditedDeckIsNotResumed() throws {
        let cp = try CaptureCheckpoint(baseName: "Fake", in: dir, source: source)
        _ = try cp.append(result(id: 1, pptx: 1))
        XCTAssertNotNil(CaptureCheckpoint.findResumable(source: source, baseName: "Fake", in: dir))

        try Data("deck, edited since the crash".utf8).write(to: source)
        XCTAssertNil(CaptureCheckpoint.findResumable(source: source, baseName: "Fake", in: dir),
                     "splicing new slides onto pages of the old deck would be silent corruption")
    }

    func testAFreshRunClearsWhatAnOlderRunLeft() throws {
        let first = try CaptureCheckpoint(baseName: "Fake", in: dir, source: source)
        for n in 1...3 { _ = try first.append(result(id: n, pptx: n)) }

        let second = try CaptureCheckpoint(baseName: "Fake", in: dir, source: source, resuming: false)
        XCTAssertEqual(second.progress.slides.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.dir.appendingPathComponent("pages/slide_002.jpg").path))

        let third = try CaptureCheckpoint(baseName: "Fake", in: dir, source: source, resuming: true)
        XCTAssertEqual(third.progress.slides.count, 0, "there is nothing left to resume")
    }

    // MARK: the session

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

    func testARunThatFinishesLeavesNoPartialAndHoldsNoBitmaps() async throws {
        let driver = FakeDriver(slides: 4), frames = FakeFrameSource()
        wire(driver, frames)
        let s = makeSession(driver, frames)
        let rep = try await s.run()

        XCTAssertTrue(rep.ok, rep.error ?? "")
        XCTAssertEqual(s.slides.count, 4)
        XCTAssertTrue(s.slides.allSatisfy(\.isCheckpointed), "every slide let its 2x bitmap go during the run")
        let left = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".arcdeck.partial") }
        XCTAssertTrue(left.isEmpty, "a verified deck has no partial left beside it: \(left)")
    }

    func testACrashedRunIsPickedUpOnTheSlideAfterTheLastOneCaptured() async throws {
        // What a crash at slide 2 of 5 leaves on disk.
        let cp = try CaptureCheckpoint(baseName: "Fake", in: dir, source: source)
        _ = try cp.append(result(id: 1, pptx: 1))
        _ = try cp.append(result(id: 2, pptx: 2, clip: try clip()))

        let driver = FakeDriver(slides: 5), frames = FakeFrameSource()
        wire(driver, frames)
        let s = makeSession(driver, frames)
        s.resumeRequested = true
        let rep = try await s.run()

        XCTAssertTrue(rep.ok, rep.error ?? "")
        XCTAssertEqual(driver.startedFrom, 3, "the show reopened on the slide after the last one captured")
        XCTAssertEqual(s.slides.count, 5)
        XCTAssertEqual(s.slides.map(\.pptxSlide), [1, 2, 3, 4, 5], "the restored slides and the new ones are one deck")
        XCTAssertEqual(s.resumedFromPptx, 3)
        let deck = try XCTUnwrap(s.outputURL)
        let verdict = await DeckVerifier.verify(arcdeck: deck)
        XCTAssertTrue(verdict.ok, verdict.detail)
        XCTAssertEqual(verdict.pages, 7, "five slides between the two logo pages")
    }

    func testADriverThatIgnoresTheStartingSlideDoesNotProduceADoubledDeck() async throws {
        // The real PowerPoint failure: `starting slide` is accepted, reads
        // back, and the show opens on slide 1 regardless. Before the position
        // check, this wrote the restored slides AND a second copy of the deck.
        let cp = try CaptureCheckpoint(baseName: "Fake", in: dir, source: source)
        for n in 1...2 { _ = try cp.append(result(id: n, pptx: n)) }

        let driver = FakeDriver(slides: 4), frames = FakeFrameSource()
        driver.ignoresStartingSlide = true
        wire(driver, frames)
        let s = makeSession(driver, frames)
        s.resumeRequested = true
        let rep = try await s.run()

        XCTAssertTrue(rep.ok, rep.error ?? "")
        XCTAssertEqual(driver.startedFrom, 3, "it did ask for slide 3")
        XCTAssertEqual(s.slides.count, 4, "the restored slides were given up, not spliced onto a second pass")
        XCTAssertEqual(s.slides.map(\.pptxSlide), [1, 2, 3, 4])
        XCTAssertNil(s.resumedFromPptx)
        XCTAssertTrue(rep.warnings.contains { $0.contains("opened the show on slide 1, not 3") })
        let verdict = await DeckVerifier.verify(arcdeck: try XCTUnwrap(s.outputURL))
        XCTAssertTrue(verdict.ok, verdict.detail)
        XCTAssertEqual(verdict.pages, 6, "four slides between the two logo pages, not ten")
    }

    func testResumeWithNothingToResumeCapturesFromTheStart() async throws {
        let driver = FakeDriver(slides: 3), frames = FakeFrameSource()
        wire(driver, frames)
        let s = makeSession(driver, frames)
        s.resumeRequested = true
        let rep = try await s.run()

        XCTAssertTrue(rep.ok, rep.error ?? "")
        XCTAssertEqual(s.slides.count, 3)
        XCTAssertNil(s.resumedFromPptx)
        XCTAssertTrue(rep.warnings.contains { $0.contains("nothing to resume") })
    }

    func testAPartialThatIsAlreadyCompleteGivesTheLastSlideBack() async throws {
        // The run died after the last slide but before the deck was written.
        let cp = try CaptureCheckpoint(baseName: "Fake", in: dir, source: source)
        for n in 1...3 { _ = try cp.append(result(id: n, pptx: n)) }

        let driver = FakeDriver(slides: 3), frames = FakeFrameSource()
        wire(driver, frames)
        let s = makeSession(driver, frames)
        s.resumeRequested = true
        let rep = try await s.run()

        XCTAssertTrue(rep.ok, rep.error ?? "")
        XCTAssertEqual(driver.startedFrom, 3, "the show has to open on a slide, so the last one is captured again")
        XCTAssertEqual(s.slides.map(\.pptxSlide), [1, 2, 3])
    }

    // MARK: the writer

    func testTheDeckPDFIsBuiltFromTheCheckpointedPages() throws {
        let cp = try CaptureCheckpoint(baseName: "Fake", in: dir, source: source)
        var slides: [CaptureResult] = []
        for n in 1...3 { slides.append(try cp.append(result(id: n, pptx: n))) }
        XCTAssertTrue(slides.allSatisfy(\.isCheckpointed))

        let out = try DeckWriter.write(slides: slides, baseName: "Fake", into: dir, keepPNGs: false)
        let pdf = try XCTUnwrap(PDFDocument(url: out.deckURL.appendingPathComponent("slides.pdf")))
        XCTAssertEqual(pdf.pageCount, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.deckURL.appendingPathComponent(".pages").path),
                       "the scratch pages are cleaned up")
    }

    func testAPageThatWasNeverCheckpointedStillReachesThePDF() throws {
        // The logo pages are made at write time and have no file behind them.
        let slides = [result(id: 1, pptx: 1), result(id: 2, pptx: 2)]
        let out = try DeckWriter.write(slides: slides, baseName: "Bumpered", into: dir, keepPNGs: false)
        let pdf = try XCTUnwrap(PDFDocument(url: out.deckURL.appendingPathComponent("slides.pdf")))
        XCTAssertEqual(pdf.pageCount, 2)
    }
}

// MARK: - Show window placement beside a live Presenter (one-Mac show)

final class ShowWindowPlacementTests: XCTestCase {
    typealias C = ShowWindowPlacement.Candidate
    func testIntakeMacWithNoPresenterUsesTheSecondDisplay() {
        let pick = ShowWindowPlacement.choose([C(uuid: "A", isMain: true, isPresenterOutput: false), C(uuid: "B", isMain: false, isPresenterOutput: false)])
        XCTAssertEqual(pick?.uuid, "B")
    }
    func testShowMacNeverPutsTheShowOnTheProgramDisplay() {
        let pick = ShowWindowPlacement.choose([C(uuid: "OP", isMain: true, isPresenterOutput: false), C(uuid: "PGM", isMain: false, isPresenterOutput: true)])
        XCTAssertEqual(pick?.uuid, "OP", "the operator display, partly covered, never the program display")
    }
    func testThreeDisplaysPicksTheOneThatIsNotAnOutput() {
        let pick = ShowWindowPlacement.choose([C(uuid: "OP", isMain: true, isPresenterOutput: false), C(uuid: "PGM", isMain: false, isPresenterOutput: true), C(uuid: "MON", isMain: false, isPresenterOutput: true), C(uuid: "SPARE", isMain: false, isPresenterOutput: false)])
        XCTAssertEqual(pick?.uuid, "SPARE")
    }
    func testEveryDisplayAnOutputIsRefused() {
        XCTAssertNil(ShowWindowPlacement.choose([C(uuid: "OP", isMain: true, isPresenterOutput: true), C(uuid: "PGM", isMain: false, isPresenterOutput: true)]))
    }
}
