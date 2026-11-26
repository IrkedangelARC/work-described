//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import AVFoundation
import PDFKit
import ARCShowFormat
@testable import ArcCaptureTests

// MARK: - FrameAnalysis: the thresholds are the behaviour

final class FrameAnalysisTests: XCTestCase {

    func testIdenticalFramesAreSettledAndNotChanged() {
        let a = [UInt8](repeating: 120, count: 3000)
        XCTAssertEqual(FrameAnalysis.difference(a, a), 0)
        XCTAssertTrue(FrameAnalysis.isSettledPair(a, a))
        XCTAssertFalse(FrameAnalysis.isChangedPair(a, a))
        XCTAssertTrue(FrameAnalysis.isDuplicateSlide(a, a))
    }

    func testBlackToWhiteIsMaximal() {
        let a = [UInt8](repeating: 0, count: 3000)
        let b = [UInt8](repeating: 255, count: 3000)
        XCTAssertEqual(FrameAnalysis.difference(a, b), 1.0, accuracy: 1e-6)
        XCTAssertFalse(FrameAnalysis.isSettledPair(a, b))
        XCTAssertTrue(FrameAnalysis.isChangedPair(a, b))
    }

    /// A small change sits between the two thresholds: it counts as a changed
    /// frame for motion but does not break a settle. That gap is what lets a
    /// subtle build animation register without the slide never settling.
    func testSubtleChangeIsMotionButStillSettles() {
        var a = [UInt8](repeating: 100, count: 3000)
        let b = a
        for i in stride(from: 0, to: 3000, by: 100) { a[i] = 200 }     // 1% of samples move by 100
        let d = FrameAnalysis.difference(a, b)
        XCTAssertGreaterThanOrEqual(d, FrameAnalysis.motionCountThreshold)
        XCTAssertLessThan(d, FrameAnalysis.settleThreshold)
        XCTAssertTrue(FrameAnalysis.isChangedPair(a, b))
        XCTAssertTrue(FrameAnalysis.isSettledPair(a, b))
        XCTAssertFalse(FrameAnalysis.isDuplicateSlide(a, b), "same template, different slide must not read as a repeat")
    }

    func testEmptyIsNeverIdentical() {
        XCTAssertEqual(FrameAnalysis.difference([], []), 1.0)
        XCTAssertFalse(FrameAnalysis.isDuplicateSlide(nil, [1, 2, 3]))
    }

    func testFingerprintSamplesGrid() {
        let w = 640, h = 360, bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        for y in 0..<h { for x in 0..<w { let o = y * bpr + x * 4; bytes[o] = UInt8(x % 256); bytes[o + 1] = 7; bytes[o + 2] = UInt8(y % 256) } }
        let fp = bytes.withUnsafeBufferPointer { FrameAnalysis.fingerprint(base: $0.baseAddress!, width: w, height: h, bytesPerRow: bpr) }
        XCTAssertEqual(fp.count, 320 * 180 * 3)
        XCTAssertEqual(fp[1], 7)
    }
}

// MARK: - PPTXAnalyzer on a synthetic deck

final class PPTXAnalyzerTests: XCTestCase {

    /// Builds a minimal .pptx zip: N slide XMLs, rels for some, one tiny video.
    private func makeDeck(slides: Int, videoOn: [Int], mediaName: String = "media1.mp4") throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("deck-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("ppt/slides/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("ppt/media"), withIntermediateDirectories: true)
        for n in 1...slides {
            let sld = (n == 4) ? "<p:sld xmlns:p=\"x\" show=\"0\"/>" : "<p:sld/>"
            try sld.write(to: root.appendingPathComponent("ppt/slides/slide\(n).xml"), atomically: true, encoding: .utf8)
            let target = videoOn.contains(n) ? "<Relationship Id=\"rId2\" Type=\"video\" Target=\"../media/\(mediaName)\"/>" : ""
            try "<Relationships>\(target)</Relationships>".write(to: root.appendingPathComponent("ppt/slides/_rels/slide\(n).xml.rels"), atomically: true, encoding: .utf8)
        }
        // A 1-second silent MP4 via AVAssetWriter so ffprobe has a real duration to report.
        try writeTinyVideo(to: root.appendingPathComponent("ppt/media/\(mediaName)"))
        let zip = fm.temporaryDirectory.appendingPathComponent("deck-\(UUID().uuidString).pptx")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = root
        p.arguments = ["-q", "-r", zip.path, "ppt"]
        try p.run(); p.waitUntilExit()
        try? fm.removeItem(at: root)
        return zip
    }

    private func writeTinyVideo(to url: URL) throws {
        let r = VideoRecorder()
        try r.startRecording(to: url, width: 64, height: 64)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
        for i in 0..<30 { r.appendFrame(pb!, timestamp: CMTime(value: CMTimeValue(i), timescale: 30)) }
        let sem = DispatchSemaphore(value: 0)
        Task { _ = try? await r.stopRecording(); sem.signal() }
        sem.wait()
    }

    func testCountsSlidesAndFindsVideoByExactTarget() throws {
        try XCTSkipUnless(PPTXAnalyzer.ffprobeURL != nil, "ffprobe not installed")
        let deck = try makeDeck(slides: 6, videoOn: [3, 5])
        defer { try? FileManager.default.removeItem(at: deck) }
        let a = PPTXAnalyzer.analyze(deck)
        XCTAssertEqual(a.slideCount, 6)
        XCTAssertEqual(a.hiddenSlides, [4])
        XCTAssertTrue(PPTXAnalyzer.mediaStartsOnEntry(#"<p:cTn nodeType="mainSeq"><p:cTn nodeType="withEffect"><p:cMediaNode vol="1"/>"#))
        XCTAssertFalse(PPTXAnalyzer.mediaStartsOnEntry(#"<p:cTn nodeType="withEffect"><p:cTn nodeType="clickEffect"><p:cMediaNode vol="1"/>"#))
        XCTAssertFalse(PPTXAnalyzer.mediaStartsOnEntry("<p:sld/>"))
        XCTAssertEqual(PPTXAnalyzer.clickCount(#"<p:timing><p:seq concurrent="1"><p:cTn nodeType="mainSeq"><p:cTn nodeType="clickEffect"/><p:cTn nodeType="withEffect"/><p:cTn nodeType="clickEffect"/></p:cTn></p:seq><p:seq concurrent="1"><p:cTn nodeType="interactiveSeq"><p:cTn nodeType="clickEffect"/></p:cTn></p:seq></p:timing>"#), 2)
        XCTAssertEqual(PPTXAnalyzer.clickCount("<p:sld/>"), 0)
        XCTAssertEqual(a.visibleSlideCount, 5)
        XCTAssertEqual(a.videoSlides, [3, 5])
        XCTAssertEqual(a.slideDurations.count, 2)
        XCTAssertEqual(a.slideDurations[3] ?? 0, 1.0, accuracy: 0.2)
        XCTAssertTrue(a.warnings.isEmpty, "\(a.warnings)")
    }

    /// media1.mp4 must not claim a slide that references media11.mp4.
    func testNoSubstringMatch() throws {
        try XCTSkipUnless(PPTXAnalyzer.ffprobeURL != nil, "ffprobe not installed")
        let deck = try makeDeck(slides: 2, videoOn: [2], mediaName: "media11.mp4")
        defer { try? FileManager.default.removeItem(at: deck) }
        // Add a second slide rels that references media1.mp4, which does not exist as a file.
        let a = PPTXAnalyzer.analyze(deck)
        XCTAssertEqual(a.videoSlides, [2])
    }

    func testGarbageInputIsEmptyNotFatal() {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).pptx")
        try? "not a zip".write(to: junk, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: junk) }
        let a = PPTXAnalyzer.analyze(junk)
        XCTAssertEqual(a.slideCount, 0)
        XCTAssertTrue(a.videoSlides.isEmpty)
    }

    func testSlideNumberParsing() {
        XCTAssertEqual(PPTXAnalyzer.slideNumber(fromSlideFile: "slide12.xml"), 12)
        XCTAssertEqual(PPTXAnalyzer.slideNumber(fromSlideFile: "slide3.xml.rels"), 3)
        XCTAssertNil(PPTXAnalyzer.slideNumber(fromSlideFile: "slideLayout1.xml"))
        XCTAssertNil(PPTXAnalyzer.slideNumber(fromSlideFile: "notes1.xml"))
    }
}

// MARK: - PDFAssembler / VideoRecorder / DeckWriter contracts

final class OutputTests: XCTestCase {

    private func solid(_ w: Int, _ h: Int, _ c: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus(); c.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill(); img.unlockFocus()
        return img
    }

    func testPDFHasOnePagePerImage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try PDFAssembler.assemble(images: [solid(320, 180, .red), solid(320, 180, .blue), solid(320, 180, .green)], to: url)
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 3)
    }

    func testPDFRefusesEmpty() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).pdf")
        XCTAssertThrowsError(try PDFAssembler.assemble(images: [], to: url))
    }

    func testRecorderWritesPlayableClip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = VideoRecorder()
        try r.startRecording(to: url, width: 128, height: 72)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_32BGRA, nil, &pb)
        for i in 0..<60 { r.appendFrame(pb!, timestamp: CMTime(value: CMTimeValue(i), timescale: 30)) }
        XCTAssertEqual(r.droppedFrames, 0, "encoder must take every frame when fed at ~real time")
        XCTAssertThrowsError(try r.startRecording(to: url, width: 1, height: 1)) { _ in }   // already recording
        let out = try await r.stopRecording()
        let asset = AVURLAsset(url: out)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let d = try await asset.load(.duration).seconds
        XCTAssertEqual(d, 2.0, accuracy: 0.15)
    }

    func testDeckWriterLayoutAndManifest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appendingPathComponent("clip.mov")
        try "fake".write(to: clip, atomically: true, encoding: .utf8)
        let slides = [
            CaptureResult(id: 1, pptxSlide: 1, slideType: .image, image: solid(64, 36, .red), videoURL: nil, capturedAt: Date(), settleMs: 300, motionFrames: 0, endedBy: "settled"),
            CaptureResult(id: 2, pptxSlide: 2, slideType: .video, image: solid(64, 36, .blue), videoURL: clip, capturedAt: Date(), settleMs: 4000, motionFrames: 90, endedBy: "settled"),
        ]
        let out = try DeckWriter.write(slides: slides, baseName: "Test", into: dir, keepPNGs: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.deckURL.appendingPathComponent("slides.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.deckURL.appendingPathComponent("media/slide_002.mov").path))
        XCTAssertEqual(out.clipFiles[2], "media/slide_002.mov")
        XCTAssertNil(out.pdfURL, "mixed decks do not get the loose pdf")
        XCTAssertNotNil(out.folderURL)
        let m = try JSONSerialization.jsonObject(with: Data(contentsOf: out.deckURL.appendingPathComponent("manifest.json"))) as! [String: Any]
        XCTAssertEqual(m["version"] as? Int, 2)
        let entries = m["slides"] as! [[String: Any]]
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1]["file"] as? String, "media/slide_002.mov")
        XCTAssertEqual(entries[0]["pptxSlide"] as? Int, 1)
        XCTAssertEqual(PDFDocument(url: out.deckURL.appendingPathComponent("slides.pdf"))?.pageCount, 2)
    }

    /// advTm slides carry their delay into the manifest (V2 hardening, 2026-09-12).
    func testDeckWriterWritesAutoAdvance() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let img = NSImage(size: NSSize(width: 64, height: 36)); img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 64, height: 36).fill(); img.unlockFocus()   // a drawn bitmap: PDFAssembler refuses an empty image
        var a = CaptureResult(id: 1, pptxSlide: 1, slideType: .image, image: img, videoURL: nil, capturedAt: Date(), settleMs: 0, motionFrames: 0, endedBy: "settled")
        a.autoAdvance = 2.0
        let b = CaptureResult(id: 2, pptxSlide: 2, slideType: .image, image: img, videoURL: nil, capturedAt: Date(), settleMs: 0, motionFrames: 0, endedBy: "settled")
        let out = try DeckWriter.write(slides: [a, b], baseName: "Adv", into: dir, keepPNGs: false)
        let m = try JSONSerialization.jsonObject(with: Data(contentsOf: out.deckURL.appendingPathComponent("manifest.json"))) as! [String: Any]
        let entries = m["slides"] as! [[String: Any]]
        XCTAssertEqual(entries[0]["autoAdvance"] as? Double, 2.0)
        XCTAssertNil(entries[1]["autoAdvance"])
    }

    func testStaticDeckGetsLoosePDF() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let slides = [CaptureResult(id: 1, pptxSlide: 1, slideType: .image, image: solid(64, 36, .red), videoURL: nil, capturedAt: Date(), settleMs: 1, motionFrames: 0, endedBy: "settled")]
        let out = try DeckWriter.write(slides: slides, baseName: "Static", into: dir, keepPNGs: false)
        XCTAssertNotNil(out.pdfURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Static.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.deckURL.appendingPathComponent("media").path))
    }

    func testReportRoundTrip() throws {
        let rep = CaptureReport(appVersion: "1.1.0", source: "/x/deck.pptx", output: "/x/deck.arcdeck", ok: true, error: nil,
                                startedAt: Date(), finishedAt: Date(), analysis: PPTXAnalysis(slideCount: 3, hiddenSlides: [], videoSlides: [2], autoPlaySlides: [], clickCounts: [:], autoAdvanceSlides: [:], loopingSlides: [], slideDurations: [2: 4.5], warnings: []),
                                expectedSlides: 3, slides: [.init(index: 1, pptxSlide: 1, type: .image, file: nil, settleMs: 250, motionFrames: 0, durationS: nil, endedBy: "settled")],
                                warnings: [], timingsMs: ["launch": 1000])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rep-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try rep.write(to: url)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(CaptureReport.self, from: Data(contentsOf: url))
        XCTAssertEqual(back.slides.count, 1)
        XCTAssertEqual(back.analysis.videoSlides, [2])
        XCTAssertTrue(back.ok)
    }
}

// MARK: - HeadlessRunner argument parsing

final class HeadlessArgsTests: XCTestCase {
    func testParseGoodArgs() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID().uuidString).pptx")
        try "x".write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        switch HeadlessRunner.parse(["app", "--headless", "--in", f.path, "--out", "/tmp/o", "--dwell", "0.5", "--timeout", "42", "--keep-pngs"]) {
        case .success(let o):
            XCTAssertEqual(o.input.path, f.path); XCTAssertEqual(o.outputDir?.path, "/tmp/o")
            XCTAssertEqual(o.dwell, 0.5); XCTAssertEqual(o.timeout, 42); XCTAssertTrue(o.keepPNGs)
        case .failure(let e): XCTFail(e.message)
        }
    }
    func testParseRejectsMissingInputAndUnknownFlag() {
        if case .success = HeadlessRunner.parse(["app", "--headless"]) { XCTFail("missing --in accepted") }
        if case .success = HeadlessRunner.parse(["app", "--headless", "--bogus"]) { XCTFail("unknown flag accepted") }
    }

    /// Everything the source says about a slide is kept for the manifest.
    func testTheAnalyzerReadsTitlesTransitionNamesAndHowMediaStarts() {
        let sp = #"<p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>Q&amp;A </a:t></a:r><a:r><a:t>Session</a:t></a:r></a:p></p:txBody></p:sp>"#
        XCTAssertEqual(PPTXAnalyzer.title("<p:sld><p:sp><p:txBody><a:t>body</a:t></p:txBody></p:sp>\(sp)</p:sld>"), "Q&A Session")
        XCTAssertNil(PPTXAnalyzer.title("<p:sld><p:sp><a:t>no placeholder</a:t></p:sp></p:sld>"))
        let twoLines = #"<p:sp><p:nvPr><p:ph type="ctrTitle"/></p:nvPr><a:p><a:r><a:t>Sample Title</a:t></a:r></a:p><a:p><a:r><a:t>Audio Plays</a:t></a:r><a:br/><a:r><a:t>Here</a:t></a:r></a:p></p:sp>"#
        XCTAssertEqual(PPTXAnalyzer.title(twoLines), "Sample Title Audio Plays Here", "a new paragraph or a line break is a space")
        XCTAssertEqual(PPTXAnalyzer.transitionEffect(#"<p:transition><p:wipe dir="r"/></p:transition>"#), "wipe", "no attributes on the tag is the common form")
        XCTAssertEqual(PPTXAnalyzer.transitionEffect(#"<p:transition spd="slow" p14:dur="2000"><p15:prstTrans prst="curtains"/></p:transition>"#), "prstTrans:curtains")
        XCTAssertNil(PPTXAnalyzer.transitionEffect("<p:transition/>"), "self-closing means none")
        let node = #"<p:video><p:cMediaNode vol="80000"><p:cTn id="9"/></p:cMediaNode></p:video>"#
        func timing(_ main: String, _ rest: String = "") -> String { "<p:timing><p:seq><p:cTn nodeType=\"mainSeq\">\(main)</p:cTn></p:seq>\(rest)\(node)</p:timing>" }
        XCTAssertEqual(PPTXAnalyzer.mediaStart(timing(#"<p:cTn presetClass="mediacall" nodeType="clickEffect"/>"#)), .inClickSequence)
        XCTAssertEqual(PPTXAnalyzer.mediaStart(timing(#"<p:cTn presetClass="mediacall" nodeType="afterEffect"/>"#)), .onEntry)
        XCTAssertEqual(PPTXAnalyzer.mediaStart(timing("", #"<p:seq><p:cTn nodeType="interactiveSeq"><p:cTn presetClass="mediacall" nodeType="clickEffect"/></p:cTn></p:seq>"#)), .whenClickedOn,
                       "PowerPoint's default insert: only a click ON the picture plays it")
        XCTAssertNil(PPTXAnalyzer.mediaStart("<p:sld/>"))
        let probed = PPTXAnalyzer.parseProbe(#"{"streams":[{"codec_type":"video","codec_name":"h264","width":320,"height":240},{"codec_type":"audio","codec_name":"aac"}],"format":{"duration":"71.340917"}}"#)
        XCTAssertEqual(probed?.seconds, 71.340917); XCTAssertEqual(probed?.width, 320); XCTAssertEqual(probed?.audioCodec, "aac"); XCTAssertEqual(probed?.hasAudio, true)
    }

    /// 2026-09-17: a deck that ended on a ten-build slide came out with none and read "ready".
    func testADeckWithFewerBuildsThanItsSourceSaysSo() {
        var logo = DeckManifest.Slide(slide: 1, type: .image); logo.role = .opening
        let built = DeckManifest.Slide(slide: 2, type: .image, pptxSlide: 1, builds: [.init(file: "a", still: "b"), .init(file: "c", still: "d")], initialStill: "s")
        let bare = DeckManifest.Slide(slide: 3, type: .image, pptxSlide: 2)
        let m = DeckManifest(slides: [logo, built, bare])
        XCTAssertEqual(CaptureSession.buildShortfalls(manifest: m, sourceBuilds: [1: 2, 2: 10]), ["slide 2: the source has 10 builds, the deck has 0; it would stay bare"])
        XCTAssertEqual(CaptureSession.buildShortfalls(manifest: m, sourceBuilds: [1: 3]), ["slide 1: the source has 3 builds, the deck has 2; it would stay part built"])
        XCTAssertEqual(CaptureSession.buildShortfalls(manifest: m, sourceBuilds: [1: 2, 2: 0]), [])
        XCTAssertEqual(PPTXAnalyzer.mediaClickCount(#"<p:timing><p:cTn nodeType="mainSeq"><p:cTn presetClass="mediacall" nodeType="clickEffect"/><p:cTn presetClass="entr" nodeType="clickEffect"/></p:cTn></p:seq></p:timing>"#), 1)
    }

    /// 2026-09-17: a deck with a passed-over slide read "ready".
    func testAShownSlideWithoutAPageFailsTheCapture() {
        XCTAssertEqual(CaptureSession.missingSlides(slideCount: 19, hidden: [], range: nil, captured: Array(1...15) + [17, 18, 19]), [16])
        XCTAssertEqual(CaptureSession.missingSlides(slideCount: 18, hidden: [12], range: nil, captured: Array(1...11) + Array(13...18)), [], "a hidden slide has no page")
        XCTAssertEqual(CaptureSession.missingSlides(slideCount: 40, hidden: [], range: 5...7, captured: [5, 7]), [6], "a range recapture owes only its range")
        XCTAssertEqual(CaptureSession.missingSlides(slideCount: 0, hidden: [], range: nil, captured: [1, 2]), [], "no analyzer count: no claim")
        XCTAssertEqual(CaptureSession.missingSlides(slideCount: 9, hidden: [], range: nil, captured: []), [], "a driver without slide numbers: no claim")
    }

    /// 2026-09-17: `--new-show` without `--headless` opened the GUI and made nothing.
    func testEveryCommandFlagIsAHeadlessRequest() {
        for flag in ["--headless", "--watch", "--analyze", "--show", "--new-show", "--show-folder", "--verify", "--split-builds"] {
            XCTAssertTrue(HeadlessRunner.isRequested(in: ["app", flag, "x"]), flag)
        }
        XCTAssertFalse(HeadlessRunner.isRequested(in: ["app"]))
        XCTAssertFalse(HeadlessRunner.isRequested(in: ["app", "-NSDocumentRevisionsDebugMode", "YES"]), "Xcode's own launch arguments")
    }
}
