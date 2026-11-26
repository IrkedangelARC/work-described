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

/// Putting one recaptured slide back into a finished deck (V3, plan 1.3).
@MainActor
final class SlideReplacerTests: XCTestCase {

    private var dir = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func solid(_ w: Int, _ h: Int, _ c: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus(); c.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill(); img.unlockFocus()
        return img
    }

    private func clip(at url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 36])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for f in 0..<8 {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            adaptor.append(FakeFrameSource.pixelBuffer(width: 64, height: 36, shade: UInt8(f * 25)),
                           withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 8))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "clip")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    /// A deck of `pages` pages; `clipOn` pages carry a clip and a build still.
    private func makeDeck(_ name: String, pages: Int, pptxFrom: Int = 1, clipOn: Set<Int> = [],
                          shade: CGFloat = 0.2) throws -> URL {
        let deck = dir.appendingPathComponent("\(name).arcdeck")
        try FileManager.default.createDirectory(at: deck.appendingPathComponent("media"), withIntermediateDirectories: true)
        let pdf = PDFDocument()
        var slides: [DeckManifest.Slide] = []
        for i in 1...pages {
            let colour = NSColor(calibratedHue: (CGFloat(i) * 0.11 + shade).truncatingRemainder(dividingBy: 1),
                                 saturation: 0.7, brightness: 0.9, alpha: 1)
            guard let page = PDFPage(image: solid(64, 36, colour)) else { throw XCTSkip("no page") }
            pdf.insert(page, at: pdf.pageCount)
            var e = DeckManifest.Slide(slide: i, type: clipOn.contains(i) ? .video : .image)
            e.pptxSlide = pptxFrom + i - 1
            if clipOn.contains(i) {
                let rel = "media/slide_\(String(format: "%03d", i)).mov"
                try clip(at: deck.appendingPathComponent(rel))
                e.file = rel
                let still = "media/slide_\(String(format: "%03d", i))_s0.png"
                try XCTUnwrap(solid(64, 36, colour).tiffRepresentation
                    .flatMap { NSBitmapImageRep(data: $0) }?
                    .representation(using: .png, properties: [:]))
                    .write(to: deck.appendingPathComponent(still))
                e.initialStill = still
            }
            slides.append(e)
        }
        XCTAssertTrue(pdf.write(to: deck.appendingPathComponent("slides.pdf")))
        try DeckManifest(slides: slides).write(to: deck.appendingPathComponent("manifest.json"))
        return deck
    }

    // MARK: -

    func testOnlyTheReplacedPageChanges() async throws {
        let deck = try makeDeck("Show", pages: 6, clipOn: [3])
        // The recapture: source slides 2 and 3, the second of which is wanted.
        let fresh = try makeDeck("Fresh", pages: 2, pptxFrom: 2, clipOn: [2], shade: 0.6)

        let before = SlideHasher.pdfPageHashes(deck.appendingPathComponent("slides.pdf"))
        let out = try await SlideReplacer.replace(page: 3, in: deck, withSlideFrom: fresh)

        XCTAssertTrue(out.verdict.ok, out.verdict.detail)
        XCTAssertEqual(out.pptxSlide, 3)
        XCTAssertEqual(out.changedPages, [3], "only the recaptured page's content moved")

        let after = SlideHasher.pdfPageHashes(deck.appendingPathComponent("slides.pdf"))
        XCTAssertEqual(before.count, after.count)
        for i in 0..<before.count where i != 2 {
            XCTAssertEqual(before[i], after[i], "page \(i + 1) should not have changed")
        }
        XCTAssertNotEqual(before[2], after[2], "page 3 should have changed")
    }

    func testTheNewPageBringsItsMediaAndTheOldPagesKeepTheirs() async throws {
        let deck = try makeDeck("Show", pages: 4, clipOn: [2, 3])
        let keptBytes = try Data(contentsOf: deck.appendingPathComponent("media/slide_002.mov"))
        let fresh = try makeDeck("Fresh", pages: 2, pptxFrom: 2, clipOn: [2], shade: 0.6)

        _ = try await SlideReplacer.replace(page: 3, in: deck, withSlideFrom: fresh)

        let m = try XCTUnwrap(DeckManifest.load(from: deck.appendingPathComponent("manifest.json")).manifest)
        let three = try XCTUnwrap(m.slides.first { $0.slide == 3 })
        XCTAssertEqual(three.type, .video)
        XCTAssertEqual(three.pptxSlide, 3)
        for rel in three.mediaFiles + three.stillFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: deck.appendingPathComponent(rel).path),
                          "\(rel) came with the new page")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: deck.appendingPathComponent("media/slide_003.mov").path),
                       "the page that was replaced took its old clip with it")
        XCTAssertEqual(try Data(contentsOf: deck.appendingPathComponent("media/slide_002.mov")), keptBytes,
                       "page 2's clip is untouched, byte for byte")
        XCTAssertEqual(m.slides.count, 4)
        XCTAssertEqual(m.slides.map(\.slide), [1, 2, 3, 4])
    }

    func testALogoPageCannotBeRecaptured() async throws {
        let deck = try makeDeck("Show", pages: 3)
        var m = try XCTUnwrap(DeckManifest.load(from: deck.appendingPathComponent("manifest.json")).manifest)
        m.slides[0].pptxSlide = nil
        m.slides[0].role = .opening
        try m.write(to: deck.appendingPathComponent("manifest.json"))

        XCTAssertNil(SlideReplacer.sourceSlide(forPage: 1, in: m))
        let fresh = try makeDeck("Fresh", pages: 1, pptxFrom: 1)
        do {
            _ = try await SlideReplacer.replace(page: 1, in: deck, withSlideFrom: fresh)
            XCTFail("a logo page has no source slide to recapture")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("logo page"), error.localizedDescription)
        }
    }

    func testARecaptureThatMissedTheSlideLeavesTheDeckAlone() async throws {
        let deck = try makeDeck("Show", pages: 4, clipOn: [2])
        let before = SlideHasher.pdfPageHashes(deck.appendingPathComponent("slides.pdf"))
        // The capture came back with slides 5 and 6: not the one asked for.
        let fresh = try makeDeck("Fresh", pages: 2, pptxFrom: 5)

        do {
            _ = try await SlideReplacer.replace(page: 3, in: deck, withSlideFrom: fresh)
            XCTFail("should refuse")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not produce source slide 3"), error.localizedDescription)
        }
        XCTAssertEqual(SlideHasher.pdfPageHashes(deck.appendingPathComponent("slides.pdf")), before,
                       "the deck is exactly as it was")
        XCTAssertFalse(FileManager.default.fileExists(atPath: deck.appendingPathExtension("bak").path),
                       "no backup left behind")
    }

    func testRemapRewritesEveryPathAnEntryNames() {
        var s = DeckManifest.Slide(slide: 2, type: .video)
        s.file = "media/a.mov"; s.entryFile = "media/a_in.mov"; s.initialStill = "media/a_s0.png"
        s.builds = [.init(file: "media/a_b1.mov", still: "media/a_s1.png"),
                    .init(file: nil, still: "media/a_s2.png")]
        let out = SlideReplacer.remap(s) { "new/" + URL(fileURLWithPath: $0).lastPathComponent }
        XCTAssertEqual(out.file, "new/a.mov")
        XCTAssertEqual(out.entryFile, "new/a_in.mov")
        XCTAssertEqual(out.initialStill, "new/a_s0.png")
        XCTAssertEqual(out.builds?.map(\.still), ["new/a_s1.png", "new/a_s2.png"])
        XCTAssertEqual(out.builds?.first?.file, "new/a_b1.mov")
        XCTAssertNil(out.builds?.last?.file)
        XCTAssertEqual(Set(out.mediaFiles + out.stillFiles).count, 6, "three clips and three stills, every path distinct after the remap")
    }
}
