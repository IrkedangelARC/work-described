//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import PDFKit
import ARCShowFormat

/// One clip per build, a still per build state: the cuts are checked to the
/// frame on a clip whose colour changes every second.
final class BuildSplitterTests: XCTestCase {
    var dir: URL!
    /// Second n of the test clip is this grey level (0...255), far enough apart to survive H.264.
    static let levels: [UInt8] = [20, 70, 120, 170, 220, 250]
    static let fps: Int32 = 30

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    /// `moving`: a bar crosses the frame, one step per frame, so every stretch of the clip holds MOTION (an
    /// animation). Without it the clip is flat grey that steps once a second: cuts, as PowerPoint's "Appear" records.
    private func makeClip(_ url: URL, seconds: Int = 6, moving: Bool = true) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 120]])   // sparse keyframes, like a real capture
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for f in 0..<(seconds * Int(Self.fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            let buffer = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            let grey = Self.levels[f / Int(Self.fps)]
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(grey), CVPixelBufferGetDataSize(buffer))
            if moving, let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                // 16 px of 320 (5 %): the frame's mean stays nearest its second's grey level, which is what the tests read.
                let stride = CVPixelBufferGetBytesPerRow(buffer), x0 = (f * 7) % 300, ink: UInt8 = grey < 128 ? 255 : 0
                for y in 0..<180 { memset(base + y * stride + x0 * 4, Int32(ink), 16 * 4) }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: Self.fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    /// The same flat, stepping picture as a still, PLUS a 440 Hz tone at about -20 dBFS: a slide that
    /// plays sound. The picture comes from `makeClip`, the tone from AVAudioFile, and a passthrough
    /// export muxes them: an AVAssetWriter fed two inputs by polling stalled the suite for six minutes.
    private func makeClipWithTone(_ url: URL, seconds: Int = 3) async throws {
        let picture = url.deletingLastPathComponent().appendingPathComponent("picture-\(UUID().uuidString).mov")
        try await makeClip(picture, seconds: seconds, moving: false)
        let toneURL = url.deletingLastPathComponent().appendingPathComponent("tone-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let file = try AVAudioFile(forWriting: toneURL, settings: format.settings)
        let n = AVAudioFrameCount(48000 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        buf.frameLength = n
        for i in 0..<Int(n) { buf.floatChannelData![0][i] = Float(0.1 * sin(2 * .pi * 440 * Double(i) / 48000)) }
        try file.write(from: buf)
        let comp = AVMutableComposition()
        let v = AVURLAsset(url: picture), a = AVURLAsset(url: toneURL)
        let videoTracks = try await v.loadTracks(withMediaType: .video), audioTracks = try await a.loadTracks(withMediaType: .audio)
        let vt = try XCTUnwrap(videoTracks.first), at = try XCTUnwrap(audioTracks.first)
        let dur = try await v.load(.duration)
        try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vt, at: .zero)
        try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: at, at: .zero)
        let export = try XCTUnwrap(AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: url, as: .mov)
    }

    func testAStillPictureWithSoundIsNotACut() async throws {
        let silent = dir.appendingPathComponent("silent.mov"), tone = dir.appendingPathComponent("tone.mov")
        // One second each: one grey level, one picture. (Three seconds step through three levels: three pictures, no cut.)
        try await makeClip(silent, seconds: 1, moving: false)
        try await makeClipWithTone(tone, seconds: 1)
        let silentPeak = await AudioProbe.peak(silent)
        XCTAssertNil(silentPeak, "no audio track: nothing to read")
        let tonePeak = await AudioProbe.peak(tone)
        let p = try XCTUnwrap(tonePeak)
        XCTAssertGreaterThan(p, 0.05, "a -20 dBFS tone reads well above the floor"); XCTAssertLessThan(p, 0.2)
        let toneHasSound = await AudioProbe.hasSound(tone), silentHasSound = await AudioProbe.hasSound(silent)
        XCTAssertTrue(toneHasSound); XCTAssertFalse(silentHasSound)
        // Both pictures are cuts to MotionProbe; only the silent one may lose its clip.
        let toneVerdict = await MotionProbe.probe(tone), silentVerdict = await MotionProbe.probe(silent)
        XCTAssertTrue(try XCTUnwrap(toneVerdict).isCut)
        XCTAssertTrue(try XCTUnwrap(silentVerdict).isCut)
    }

    /// A still picture with sound is kept as a clip AND the page's recording is kept for the review
    /// queue, with a sidecar naming the doubt (R10) and the click marks (docs/PLAN_review_queue.md).
    func testAKeptClipLeavesTheRecordingAndASidecarForReview() async throws {
        let deck = dir.appendingPathComponent("rec.arcdeck"), out = dir.appendingPathComponent("rec-out.arcdeck")
        try FileManager.default.createDirectory(at: deck.appendingPathComponent("media"), withIntermediateDirectories: true)
        try await makeClipWithTone(deck.appendingPathComponent("media/slide_002.mov"), seconds: 5)
        try DeckManifest(slides: [DeckManifest.Slide(slide: 1, type: .image, pptxSlide: 1),
                                  DeckManifest.Slide(slide: 2, type: .video, file: "media/slide_002.mov", clicks: [1.0, 2.0, 4.0], entryClick: 2, pptxSlide: 2)])
            .write(to: deck.appendingPathComponent("manifest.json"))
        let summary = try await BuildSplitter.convert(deck: deck, into: out) { _ in }
        XCTAssertEqual(summary.cuts, 0, "sound on every piece: nothing is cut")
        XCTAssertEqual(summary.kept, 1); XCTAssertGreaterThanOrEqual(summary.flags, 1)
        // Page 2's clip holds slide 1's builds, so the recording is filed under the page that owns them.
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("review/slide_001.recording.mov").path))
        let sc = try JSONDecoder().decode(ReviewSidecar.self, from: Data(contentsOf: out.appendingPathComponent("review/slide_001.json")))
        XCTAssertEqual(sc.slide, 1); XCTAssertEqual(sc.recording, "review/slide_001.recording.mov"); XCTAssertEqual(sc.marks, [1.0, 2.0, 4.0])
        XCTAssertTrue(sc.flags.contains { $0.rule == "R10" }, "\(sc.flags)")
        // A clean silent deck keeps nothing.
        let quiet = dir.appendingPathComponent("quiet.arcdeck"), quietOut = dir.appendingPathComponent("quiet-out.arcdeck")
        try FileManager.default.createDirectory(at: quiet.appendingPathComponent("media"), withIntermediateDirectories: true)
        try await makeClip(quiet.appendingPathComponent("media/slide_002.mov"), moving: true)
        try DeckManifest(slides: [DeckManifest.Slide(slide: 1, type: .image, pptxSlide: 1),
                                  DeckManifest.Slide(slide: 2, type: .video, file: "media/slide_002.mov", clicks: [1.0, 2.0, 4.0], entryClick: 2, pptxSlide: 2)])
            .write(to: quiet.appendingPathComponent("manifest.json"))
        let q = try await BuildSplitter.convert(deck: quiet, into: quietOut) { _ in }
        XCTAssertEqual(q.kept, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: quietOut.appendingPathComponent("review").path))
    }

    /// A flagged slide keeps its recording with the marks whatever the probes think: the reviewer needs the
    /// picture and a mark for every click, even when every click was a plain cut.
    func testAFlaggedSlideKeepsItsRecordingAndMarksEvenWhenEveryClickIsACut() async throws {
        let deck = dir.appendingPathComponent("flag.arcdeck"), out = dir.appendingPathComponent("flag-out.arcdeck")
        try FileManager.default.createDirectory(at: deck.appendingPathComponent("media"), withIntermediateDirectories: true)
        try await makeClip(deck.appendingPathComponent("media/slide_002.mov"), moving: false)          // grey steps: cuts, no sound
        try await makeClip(deck.appendingPathComponent("media/slide_003.mov"), moving: true)           // a movie page of its own
        try DeckManifest(slides: [DeckManifest.Slide(slide: 1, type: .image, pptxSlide: 1),
                                  DeckManifest.Slide(slide: 2, type: .video, file: "media/slide_002.mov", clicks: [1.0, 2.0, 4.0], entryClick: 2, pptxSlide: 2),
                                  DeckManifest.Slide(slide: 3, type: .video, file: "media/slide_003.mov", clicks: [0.5], pptxSlide: 3)])
            .write(to: deck.appendingPathComponent("manifest.json"))
        // With no pptx the builds are undeclared, so a silent cut is the splitter's own R6 doubt: slide 1 is kept either way.
        let quiet = try await BuildSplitter.convert(deck: deck, into: out) { _ in }
        XCTAssertEqual(quiet.kept, 1, "slide 1 for the splitter's own doubt; the movie page is not")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("review/slide_003.json").path))
        let out2 = dir.appendingPathComponent("flag-out2.arcdeck")
        let sum = try await BuildSplitter.convert(deck: deck, into: out2, keepRecordingsFor: [1, 3]) { _ in }
        XCTAssertEqual(sum.kept, 2)
        let s1 = try JSONDecoder().decode(ReviewSidecar.self, from: Data(contentsOf: out2.appendingPathComponent("review/slide_001.json")))
        XCTAssertEqual(s1.marks, [1.0, 2.0, 4.0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: out2.appendingPathComponent("review/slide_001.recording.mov").path))
        let s3 = try JSONDecoder().decode(ReviewSidecar.self, from: Data(contentsOf: out2.appendingPathComponent("review/slide_003.json")))
        XCTAssertEqual(s3.marks, [0.5], "a movie page's own clip, with its click")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out2.appendingPathComponent("review/slide_003.recording.mov").path))
    }

    /// Phase 2: the review's decisions are cut from the KEPT recording on a rebuild, no probe asked,
    /// and the rebuilt page raises no doubt (the override survives a re-run).
    func testReviewDecisionsAreCutFromTheKeptRecordingOnRebuild() async throws {
        let deck = dir.appendingPathComponent("dec.arcdeck"), v1 = dir.appendingPathComponent("dec-v1.arcdeck"), v2 = dir.appendingPathComponent("dec-v2.arcdeck")
        try FileManager.default.createDirectory(at: deck.appendingPathComponent("media"), withIntermediateDirectories: true)
        try await makeClipWithTone(deck.appendingPathComponent("media/slide_002.mov"), seconds: 5)
        try DeckManifest(slides: [DeckManifest.Slide(slide: 1, type: .image, pptxSlide: 1),
                                  DeckManifest.Slide(slide: 2, type: .video, file: "media/slide_002.mov", clicks: [1.0, 2.0, 4.0], entryClick: 2, pptxSlide: 2)])
            .write(to: deck.appendingPathComponent("manifest.json"))
        let first = try await BuildSplitter.convert(deck: deck, into: v1) { _ in }
        XCTAssertEqual(first.kept, 1); XCTAssertEqual(first.flags, 2, "both clicks: a still with sound (R10)")
        let decided = [ReviewOverride(item: "t", slide: 1, click: 1, kind: .cut),
                       ReviewOverride(item: "t", slide: 1, click: 2, kind: .clip, in: 2.5, out: 3.5)]
        var lines: [String] = []
        let second = try await BuildSplitter.convert(deck: v1, into: v2, overrides: decided, rebuild: true) { lines.append($0) }
        XCTAssertEqual(second.flags, 0, "decided: no doubt raised again \(lines)")
        XCTAssertEqual(second.cuts, 1)
        let m = try XCTUnwrap(DeckManifest.load(from: v2.appendingPathComponent("manifest.json")).manifest)
        let builds = try XCTUnwrap(m.slides[0].builds)
        XCTAssertEqual(builds.count, 2)
        XCTAssertNil(builds[0].file, "click 1 is a cut")
        XCTAssertEqual(builds[1].file, "media/slide_001_b02.mov")
        XCTAssertEqual(builds[1].duration ?? 0, 1.0, accuracy: 0.15, "click 2 is the marked second")
        let sc = try JSONDecoder().decode(ReviewSidecar.self, from: Data(contentsOf: v2.appendingPathComponent("review/slide_001.json")))
        XCTAssertTrue(sc.flags.isEmpty); XCTAssertEqual(sc.marks, [1.0, 2.0, 4.0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: v2.appendingPathComponent("review/slide_001.recording.mov").path), "the recording stays for the next decision")
        // Page 2 was re-based on the first split and is left alone on the rebuild.
        let p2 = try XCTUnwrap(DeckManifest.load(from: v1.appendingPathComponent("manifest.json")).manifest?.slides[1])
        XCTAssertEqual(m.slides[1].clicks, p2.clicks); XCTAssertEqual(m.slides[1].entryClick, p2.entryClick)
        // Click 0 as a clip on a movie page: where its own clip stops.
        let v3 = dir.appendingPathComponent("dec-v3.arcdeck")
        _ = try await BuildSplitter.convert(deck: v1, into: v3, overrides: [ReviewOverride(item: "t", slide: 2, click: 0, kind: .clip, out: 0.6)], rebuild: true) { _ in }
        let m3 = try XCTUnwrap(DeckManifest.load(from: v3.appendingPathComponent("manifest.json")).manifest)
        XCTAssertEqual(m3.slides[1].stopAt, 0.6)
    }

    /// Mean grey level of a frame of a clip, or of a PNG.
    private func level(ofClip url: URL, at seconds: Double) async throws -> Int {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        return level(try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image)
    }
    private func level(ofImage url: URL) throws -> Int {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return level(try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil)))
    }
    private func level(_ image: CGImage) -> Int {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Int(px[0])
    }
    /// Which second of the source the clip shows at `seconds` (hoisted: XCTest's autoclosures cannot await).
    private func shown(_ url: URL, at seconds: Double) async throws -> Int { second(try await level(ofClip: url, at: seconds)) }
    /// Which second of the source a grey level belongs to.
    private func second(_ level: Int) -> Int { Self.levels.enumerated().min { abs(Int($0.element) - level) < abs(Int($1.element) - level) }!.offset }

    func testThePlanReadsBuildsStatesAndTheLeavingClickFromTheMarks() {
        let plan = BuildSplitter.Plan.make(marks: [1.0, 2.0, 4.5])
        XCTAssertEqual(plan?.builds, [.init(start: 1.0, end: 2.0), .init(start: 2.0, end: 4.5)], "two builds, then the click that leaves")
        XCTAssertEqual(plan?.stateTimes, [1.0, 2.0, 4.5]); XCTAssertEqual(plan?.leaveAt, 4.5)
        XCTAssertNil(BuildSplitter.Plan.make(marks: [1.6]), "only the leaving click: no builds")
        XCTAssertNil(BuildSplitter.Plan.make(marks: []))
        XCTAssertNil(BuildSplitter.Plan.make(marks: [1.0, 1.02, 3.0]), "a double mark is not a build")
    }

    func testACutStartsAndEndsOnTheFrameAndAStillIsTheFrameBeforeTheClick() async throws {
        let clip = dir.appendingPathComponent("source.mov"); try await makeClip(clip)
        let piece = dir.appendingPathComponent("piece.mov")
        let d = try await BuildSplitter.cut(source: clip, from: 2.0, to: 4.0, into: piece)
        XCTAssertEqual(d, 2.0, accuracy: 1.5 / Double(Self.fps), "to the frame")
        let v201 = try await shown(piece, at: 0)
        XCTAssertEqual(v201, 2, "the first frame is the first frame after the click, not the keyframe 2 s earlier")
        let v202 = try await shown(piece, at: 0.98)
        XCTAssertEqual(v202, 2)
        let v203 = try await shown(piece, at: 1.02)
        XCTAssertEqual(v203, 3)
        let v1 = try await shown(piece, at: d - 1.0 / Double(Self.fps))
        XCTAssertEqual(v1, 3, "and nothing of second 4 at the tail")

        let still = dir.appendingPathComponent("stills/s.png")
        try await BuildSplitter.still(source: clip, before: 2.0, into: still)
        XCTAssertEqual(second(try level(ofImage: still)), 1, "the state a click at 2.0 s leaves is the frame before it")
        try await BuildSplitter.still(source: clip, before: 6.0, into: still)
        XCTAssertEqual(second(try level(ofImage: still)), 5, "at the very end: the last frame")
    }

    /// A two-page deck as the walk writes it: slide 1's two builds sit at the
    /// head of page 2's clip, before the click that leaves.
    func testADeckIsConvertedWithTheBuildsMovedToTheirOwnSlide() async throws {
        let deck = dir.appendingPathComponent("Talk.arcdeck")
        try FileManager.default.createDirectory(at: deck.appendingPathComponent("media"), withIntermediateDirectories: true)
        let doc = PDFDocument(); doc.insert(PDFPage(), at: 0); doc.insert(PDFPage(), at: 1); XCTAssertTrue(doc.write(to: deck.appendingPathComponent("slides.pdf")))
        try await makeClip(deck.appendingPathComponent("media/slide_002.mov"))
        // second 0: slide 1 state 0 | click 1.0: build 1 | click 2.0: build 2 | click 4.0: leave | click 5.0: page 2's own click
        try DeckManifest(slides: [DeckManifest.Slide(slide: 1, type: .image, pptxSlide: 1),
                                  DeckManifest.Slide(slide: 2, type: .video, file: "media/slide_002.mov", clicks: [1.0, 2.0, 4.0, 5.0], entryClick: 2, pptxSlide: 2)])
            .write(to: deck.appendingPathComponent("manifest.json"))
        let out = dir.appendingPathComponent("Talk.builds.arcdeck")
        var lines: [String] = []
        let summary = try await BuildSplitter.convert(deck: deck, into: out) { lines.append($0) }
        XCTAssertEqual(summary, .init(slidesWithBuilds: 1, builds: 2, stills: 3, loopsSeparated: 0, cuts: 0, waysInCut: 0), "every stretch of this clip moves: nothing is a cut")
        XCTAssertEqual(lines.count, 1)

        let m = try XCTUnwrap(DeckManifest.load(from: out.appendingPathComponent("manifest.json")).manifest)
        XCTAssertEqual(m.version, 3)
        let one = try XCTUnwrap(m.slide(number: 1)), two = try XCTUnwrap(m.slide(number: 2))
        XCTAssertEqual(one.builds?.map(\.file), ["media/slide_001_b01.mov", "media/slide_001_b02.mov"], "owned by slide 1")
        XCTAssertEqual(one.initialStill, "stills/slide_001_s00.png")
        XCTAssertEqual(two.clicks, [0, 1.0], "page 2 keeps the way in and its own click, re-based to the leaving click")
        XCTAssertEqual(two.entryClick, 0)

        XCTAssertEqual(second(try level(ofImage: out.appendingPathComponent("stills/slide_001_s00.png"))), 0, "state 0")
        let v204 = try await shown(out.appendingPathComponent("media/slide_001_b01.mov"), at: 0)
        XCTAssertEqual(v204, 1, "build 1 starts on its click")
        XCTAssertEqual(second(try level(ofImage: out.appendingPathComponent("stills/slide_001_s01.png"))), 1, "state 1 = the end of build 1")
        let v205 = try await shown(out.appendingPathComponent("media/slide_001_b02.mov"), at: 0)
        XCTAssertEqual(v205, 2)
        XCTAssertEqual(second(try level(ofImage: out.appendingPathComponent("stills/slide_001_s02.png"))), 3, "state 2 = the frame before the leaving click")
        let v206 = try await shown(out.appendingPathComponent("media/slide_002.mov"), at: 0)
        XCTAssertEqual(v206, 4, "page 2's clip now starts at the leaving click")

        let verdict = await DeckVerifier.verify(arcdeck: out)
        XCTAssertTrue(verdict.ok, verdict.detail)
        XCTAssertEqual(DeckManifest.load(from: deck.appendingPathComponent("manifest.json")).manifest?.version, 2, "the source deck is untouched")
    }

    /// PowerPoint's "Appear" and a slide with no transition record NO motion, only a before and an after. They are
    /// cuts between stills: their clips go (on one client deck a 1 ms Appear was a 2.2 s clip and "no transition" a
    /// 7.5 s one, and every click was a video swap: 2026-09-17, "i think this is the problem").
    func testBuildsAndWaysInWithNoAnimationBecomeCutsBetweenStills() async throws {
        let deck = dir.appendingPathComponent("Appear.arcdeck")
        try FileManager.default.createDirectory(at: deck.appendingPathComponent("media"), withIntermediateDirectories: true)
        let doc = PDFDocument(); doc.insert(PDFPage(), at: 0); doc.insert(PDFPage(), at: 1); XCTAssertTrue(doc.write(to: deck.appendingPathComponent("slides.pdf")))
        try await makeClip(deck.appendingPathComponent("media/slide_002.mov"), moving: false)
        // The same marks as the animated deck: two builds on slide 1, then the way in to page 2 (no click of its own).
        try DeckManifest(slides: [DeckManifest.Slide(slide: 1, type: .image, pptxSlide: 1),
                                  DeckManifest.Slide(slide: 2, type: .video, file: "media/slide_002.mov", clicks: [1.0, 2.0, 4.0], entryClick: 2, pptxSlide: 2)])
            .write(to: deck.appendingPathComponent("manifest.json"))
        let out = dir.appendingPathComponent("Appear.builds.arcdeck")
        var lines: [String] = []
        let summary = try await BuildSplitter.convert(deck: deck, into: out) { lines.append($0) }
        XCTAssertEqual(summary.builds, 2); XCTAssertEqual(summary.cuts, 2, "both builds are flat grey with at most one step: cuts")
        let m = try XCTUnwrap(DeckManifest.load(from: out.appendingPathComponent("manifest.json")).manifest)
        let one = try XCTUnwrap(m.slide(number: 1)), two = try XCTUnwrap(m.slide(number: 2))
        XCTAssertNil(one.builds?[0].file, "no clip: Presenter cuts to the still")
        XCTAssertEqual(one.builds?[0].still, "stills/slide_001_s01.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("media/slide_001_b01.mov").path))
        XCTAssertEqual(second(try level(ofImage: out.appendingPathComponent("stills/slide_001_s01.png"))), 1, "the still still says what the build looks like")
        // Build 2 runs from second 2 into second 3: one step in the MIDDLE of it, which is a cut too (no frame is in between).
        XCTAssertNil(one.builds?[1].file)
        // Page 2's way in (seconds 4 and 5) is one step: the page becomes a still.
        XCTAssertEqual(two.type, .image); XCTAssertNil(two.file)
        XCTAssertEqual(summary.waysInCut, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("media/slide_002.mov").path))
        let verdict = await DeckVerifier.verify(arcdeck: out)
        XCTAssertTrue(verdict.ok, verdict.detail)
    }

    /// The show deck is built FROM decks whose builds are cuts: the combiner carries the still and no clip.
    /// (It force-unwrapped the clip path and crashed on the first such deck.)
    func testADeckOfCutBuildsCombinesIntoAShowDeck() async throws {
        let deck = dir.appendingPathComponent("Appear.arcdeck")
        try FileManager.default.createDirectory(at: deck.appendingPathComponent("media"), withIntermediateDirectories: true)
        let doc = PDFDocument(); doc.insert(PDFPage(), at: 0); doc.insert(PDFPage(), at: 1); XCTAssertTrue(doc.write(to: deck.appendingPathComponent("slides.pdf")))
        try await makeClip(deck.appendingPathComponent("media/slide_002.mov"), moving: false)
        try DeckManifest(slides: [DeckManifest.Slide(slide: 1, type: .image, pptxSlide: 1),
                                  DeckManifest.Slide(slide: 2, type: .video, file: "media/slide_002.mov", clicks: [1.0, 2.0, 4.0], entryClick: 2, pptxSlide: 2)])
            .write(to: deck.appendingPathComponent("manifest.json"))
        let split = dir.appendingPathComponent("Appear.builds.arcdeck")
        _ = try await BuildSplitter.convert(deck: deck, into: split)
        let show = dir.appendingPathComponent("Show.arcdeck")
        let r = try DeckCombiner.combine([.init(name: "1.01 Appear", deck: split)], name: "Show", into: show)
        XCTAssertEqual(r.clips, 0); XCTAssertEqual(r.stills, 3, "state 0 and the two builds' stills")
        let m = try XCTUnwrap(DeckManifest.load(from: show.appendingPathComponent("manifest.json")).manifest)
        let talk = try XCTUnwrap(m.slides.first { $0.builds != nil })
        XCTAssertEqual(talk.builds?.map(\.file), [nil, nil])
        XCTAssertTrue(talk.builds?.allSatisfy { FileManager.default.fileExists(atPath: show.appendingPathComponent($0.still).path) } ?? false)
        let verdict = await DeckVerifier.verify(arcdeck: show)
        XCTAssertTrue(verdict.ok, verdict.detail)
    }

    func testTheMotionProbeTellsAFadeFromACut() {
        let a = [UInt8](repeating: 250, count: 1000), b = [UInt8](repeating: 250, count: 990) + [UInt8](repeating: 10, count: 10)   // 1 % of the frame: a line of text
        func run(_ frames: [[UInt8]]) -> MotionProbe.Verdict { MotionProbe.verdict(frames: frames.enumerated().map { (Double($0.offset) / 30, $0.element) }, duration: Double(frames.count) / 30)! }
        XCTAssertTrue(run(Array(repeating: b, count: 60)).isCut, "an Appear that landed before the clip began: every frame the same")
        XCTAssertTrue(run(Array(repeating: a, count: 10) + Array(repeating: b, count: 50)).isCut, "one step")
        XCTAssertTrue(run(Array(repeating: a, count: 10) + Array(repeating: b, count: 50)).endsDifferent)
        // A half-second fade of that line, 17 grey levels a frame: no two NEIGHBOURS differ enough, but mid fade it is far from both ends.
        let fade = (0..<15).map { k in [UInt8](repeating: 250, count: 990) + [UInt8](repeating: UInt8(250 - k * 16), count: 10) }
        let v = run(Array(repeating: a, count: 5) + fade + Array(repeating: b, count: 30))
        XCTAssertFalse(v.isCut); XCTAssertGreaterThan(v.inBetweenSeconds, 0.25)
        // Something that pulses and comes back: it starts and ends the same, and it is an animation.
        let pulse = run(Array(repeating: a, count: 5) + Array(repeating: b, count: 12) + Array(repeating: a, count: 20))
        XCTAssertFalse(pulse.isCut); XCTAssertFalse(pulse.endsDifferent)
    }

    // MARK: A looping movie and its way in

    func testTheLoopIsExactlyOnePeriodAndStartsAfterTheTransition() {
        let real = BuildSplitter.loopCut(entryMark: 1.59, transitionSeconds: 1.5, period: 4.004, clipSeconds: 7.97)   // 3.01 slide 17
        XCTAssertEqual(real?.entry ?? 0, 1.59, accuracy: 0.001)
        XCTAssertEqual(real?.loopFrom ?? 0, 3.24, accuracy: 0.001, "after the 1.5 s transition and a margin: the way in is 1.65 s")
        XCTAssertEqual((real?.loopTo ?? 0) - (real?.loopFrom ?? 0), 4.004, accuracy: 0.001, "one period")
        let short = BuildSplitter.loopCut(entryMark: 1.0, transitionSeconds: 2.0, period: 4.0, clipSeconds: 6.5)
        XCTAssertEqual(short?.loopFrom, 2.5, "a short recording: the last whole period")
        XCTAssertNil(BuildSplitter.loopCut(entryMark: 1.0, transitionSeconds: 1.0, period: 8.0, clipSeconds: 6.0), "less than one period recorded")
        XCTAssertNil(BuildSplitter.loopCut(entryMark: 0, transitionSeconds: 0, period: 0, clipSeconds: 6.0))
    }

    /// Second 0: the previous slide. Second 1: the transition. Seconds 2 to 4: the movie, which loops.
    func testALoopingMovieIsCutFromItsWayIn() async throws {
        let deck = dir.appendingPathComponent("Loop.arcdeck")
        try FileManager.default.createDirectory(at: deck.appendingPathComponent("media"), withIntermediateDirectories: true)
        let doc = PDFDocument(); for _ in 0..<2 { doc.insert(PDFPage(), at: doc.pageCount) }; XCTAssertTrue(doc.write(to: deck.appendingPathComponent("slides.pdf")))
        try await makeClip(deck.appendingPathComponent("media/slide_002.mov"))
        var page = DeckManifest.Slide(slide: 2, type: .video, file: "media/slide_002.mov", clicks: [1.0], entryClick: 0, loop: true, transitionIn: true, pptxSlide: 2)
        page.transitionSeconds = 0.85; page.media = [.init(kind: .video, name: "media1.mp4", seconds: 3.0)]; page.mediaStart = .onEntry
        try DeckManifest(slides: [DeckManifest.Slide(slide: 1, type: .image, pptxSlide: 1), page]).write(to: deck.appendingPathComponent("manifest.json"))
        let out = dir.appendingPathComponent("Loop.v3.arcdeck")
        let summary = try await BuildSplitter.convert(deck: deck, into: out)
        XCTAssertEqual(summary.loopsSeparated, 1)
        let p = try XCTUnwrap(DeckManifest.load(from: out.appendingPathComponent("manifest.json")).manifest?.slide(number: 2))
        XCTAssertEqual(p.entryFile, "media/slide_002_in.mov"); XCTAssertEqual(p.entryClicks, [0])
        XCTAssertEqual(p.loop, true); XCTAssertNil(p.clicks); XCTAssertNil(p.loopStart)
        let wayIn = out.appendingPathComponent("media/slide_002_in.mov"), loop = out.appendingPathComponent("media/slide_002.mov")
        let v1 = try await shown(wayIn, at: 0); XCTAssertEqual(v1, 1, "the way in starts ON the click, not on the second spent waiting on the previous slide")
        let inLen = try await AVURLAsset(url: wayIn).load(.duration).seconds
        XCTAssertEqual(inLen, 1.0, accuracy: 0.06)
        let v2 = try await shown(loop, at: 0); XCTAssertEqual(v2, 2, "the loop holds the movie only")
        let loopLen = try await AVURLAsset(url: loop).load(.duration).seconds
        XCTAssertEqual(loopLen, 3.0, accuracy: 0.06, "exactly one period, so it loops without a jump")
        let verdict = await DeckVerifier.verify(arcdeck: out)
        XCTAssertTrue(verdict.ok, verdict.detail)
        // A click-start loop already says where it loops from: left alone.
        var clicked = page; clicked.clicks = [1.0, 2.5]; clicked.loopStart = 2.6
        try DeckManifest(slides: [DeckManifest.Slide(slide: 1, type: .image), clicked]).write(to: deck.appendingPathComponent("manifest.json"))
        let again = try await BuildSplitter.convert(deck: deck, into: out)
        XCTAssertEqual(again.loopsSeparated, 0)
    }

    // MARK: Logo pages

    private func result(_ id: Int, pptx: Int?) -> CaptureResult {
        CaptureResult(id: id, pptxSlide: pptx, slideType: .image, image: NSImage(size: NSSize(width: 32, height: 18)), videoURL: nil, capturedAt: Date(), settleMs: 1, motionFrames: 0, endedBy: "settled")
    }

    func testTheLogoPagesGoAroundTheDeckAndTheSlidesAreRenumbered() throws {
        let logo = Bumper.image(size: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(logo.size, CGSize(width: 1920, height: 1080))
        XCTAssertNotNil(Bumper.logoURL, "the ARC mark ships in the bundle")
        let plain = Bumper.wrap(slides: [result(1, pptx: 1), result(2, pptx: 3)], tail: nil, logo: logo)
        XCTAssertEqual(plain.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(plain.map(\.role), [.opening, nil, nil, .closing])
        XCTAssertEqual(plain.map(\.pptxSlide), [nil, 1, 3, nil], "a logo page is not a slide of the source")
        XCTAssertEqual(plain.last?.slideType, .image)

        let clip = dir.appendingPathComponent("tail.mov"); try Data("x".utf8).write(to: clip)
        let built = Bumper.wrap(slides: [result(1, pptx: 1)], tail: .init(clip: clip, clicks: [1.0, 2.5, 4.0]), logo: logo)
        XCTAssertEqual(built.last?.slideType, .video, "the closing page carries the last slide's builds to the splitter")
        XCTAssertEqual(built.last?.clicks, [1.0, 2.5, 4.0]); XCTAssertEqual(built.last?.entryClick, 2)
        let none = Bumper.wrap(slides: [result(1, pptx: 1)], tail: .init(clip: clip, clicks: [1.6]), logo: logo)
        XCTAssertEqual(none.last?.slideType, .image, "only the leaving click: nothing to keep")
    }

    /// The last slide's builds were thrown away: nothing followed it to be recorded against.
    func testTheClosingPageGivesTheLastSlideItsBuildsAndStaysAStill() async throws {
        let deck = dir.appendingPathComponent("Last.arcdeck")
        try FileManager.default.createDirectory(at: deck.appendingPathComponent("media"), withIntermediateDirectories: true)
        let doc = PDFDocument(); for _ in 0..<3 { doc.insert(PDFPage(), at: doc.pageCount) }; XCTAssertTrue(doc.write(to: deck.appendingPathComponent("slides.pdf")))
        try await makeClip(deck.appendingPathComponent("media/slide_003.mov"))
        var opening = DeckManifest.Slide(slide: 1, type: .image); opening.role = .opening
        var closing = DeckManifest.Slide(slide: 3, type: .video, file: "media/slide_003.mov", clicks: [1.0, 2.0, 4.0], entryClick: 2); closing.role = .closing
        var info = DeckManifest.DeckInfo(); info.sourceName = "Last.pptx"
        try DeckManifest(deck: info, slides: [opening, DeckManifest.Slide(slide: 2, type: .image, pptxSlide: 1), closing]).write(to: deck.appendingPathComponent("manifest.json"))

        let out = dir.appendingPathComponent("Last.v3.arcdeck")
        let summary = try await BuildSplitter.convert(deck: deck, into: out)
        XCTAssertEqual(summary.builds, 2)
        let m = try XCTUnwrap(DeckManifest.load(from: out.appendingPathComponent("manifest.json")).manifest)
        XCTAssertEqual(m.slide(number: 2)?.builds?.count, 2, "the LAST slide of the source has its builds")
        let end = try XCTUnwrap(m.slide(number: 3))
        XCTAssertEqual(end.role, .closing); XCTAssertEqual(end.type, .image); XCTAssertNil(end.file); XCTAssertNil(end.clicks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("media/slide_003.mov").path), "PowerPoint's way out to its end-of-show screen is not kept")
        XCTAssertNil(m.slide(number: 1)?.builds, "a logo page never owns builds")
        XCTAssertEqual(m.deck?.sourceName, "Last.pptx", "the deck info survives the conversion")
        let verdict = await DeckVerifier.verify(arcdeck: out)
        XCTAssertTrue(verdict.ok, verdict.detail)
    }

    // MARK: The combined session deck

    /// Logo before, between and after: a deck that brings its own logo pages
    /// shares them, a deck without gets them, and builds, stills and notes come along renumbered.
    func testDecksCombineWithALogoBeforeBetweenAndAfter() async throws {
        // Deck A: captured the new way (opening + 1 slide with 2 builds + closing).
        let a = dir.appendingPathComponent("A.arcdeck")
        for sub in ["media", "stills"] { try FileManager.default.createDirectory(at: a.appendingPathComponent(sub), withIntermediateDirectories: true) }
        let docA = PDFDocument(); for _ in 0..<3 { docA.insert(PDFPage(), at: docA.pageCount) }; XCTAssertTrue(docA.write(to: a.appendingPathComponent("slides.pdf")))
        try await makeClip(a.appendingPathComponent("media/slide_002_b01.mov"), seconds: 1)
        try await makeClip(a.appendingPathComponent("media/slide_002_b02.mov"), seconds: 1)
        for n in 0...2 { try await BuildSplitter.still(source: a.appendingPathComponent("media/slide_002_b01.mov"), before: 0.5, into: a.appendingPathComponent("stills/slide_002_s0\(n).png")) }
        var open = DeckManifest.Slide(slide: 1, type: .image); open.role = .opening
        var close = DeckManifest.Slide(slide: 3, type: .image); close.role = .closing
        var talk = DeckManifest.Slide(slide: 2, type: .image, pptxSlide: 1, builds: [.init(file: "media/slide_002_b01.mov", still: "stills/slide_002_s01.png", duration: 1),
                                                                                       .init(file: "media/slide_002_b02.mov", still: "stills/slide_002_s02.png", duration: 1)], initialStill: "stills/slide_002_s00.png")
        talk.title = "Only Slide"
        try DeckManifest(slides: [open, talk, close]).write(to: a.appendingPathComponent("manifest.json"))
        try JSONEncoder().encode(["2": "say hello"]).write(to: a.appendingPathComponent("notes.json"))
        // Deck B: two plain pages, no logo pages, no manifest at all.
        let b = dir.appendingPathComponent("B.arcdeck"); try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let docB = PDFDocument(); for _ in 0..<2 { docB.insert(PDFPage(), at: docB.pageCount) }; XCTAssertTrue(docB.write(to: b.appendingPathComponent("slides.pdf")))

        let out = dir.appendingPathComponent("Session.arcdeck")
        let r = try DeckCombiner.combine([.init(name: "1.01 A", deck: a), .init(name: "1.02 B", deck: b)], name: "Session", into: out)
        XCTAssertEqual(r, .init(pages: 6, clips: 2, stills: 3, parts: 2))
        let m = try XCTUnwrap(DeckManifest.load(from: out.appendingPathComponent("manifest.json")).manifest)
        XCTAssertEqual(m.slides.map(\.role), [.opening, nil, .between, nil, nil, .closing], "A's closing page stands between; B gets a closing page made here")
        XCTAssertEqual(m.version, 3)
        XCTAssertEqual(m.slide(number: 2)?.builds?.map(\.file), ["media/slide_002_b01.mov", "media/slide_002_b02.mov"])
        XCTAssertEqual(m.slide(number: 2)?.title, "Only Slide"); XCTAssertEqual(m.slide(number: 2)?.source, "1.01 A")
        XCTAssertEqual(m.slide(number: 4)?.source, "1.02 B"); XCTAssertEqual(m.slide(number: 5)?.sourcePage, 2)
        XCTAssertEqual(m.deck?.parts?.map(\.lastPage), [3, 6])
        XCTAssertEqual(PDFDocument(url: out.appendingPathComponent("slides.pdf"))?.pageCount, 6)
        let notes = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: out.appendingPathComponent("notes.json")))
        XCTAssertEqual(notes, ["2": "say hello"])
        let verdict = await DeckVerifier.verify(arcdeck: out)
        XCTAssertTrue(verdict.ok, verdict.detail)

        // B first: its pages shift behind an opening page made here, and A's opening page is dropped.
        let r2 = try DeckCombiner.combine([.init(name: "B", deck: b), .init(name: "A", deck: a)], name: "Session", into: out)
        XCTAssertEqual(r2.pages, 6)
        let m2 = try XCTUnwrap(DeckManifest.load(from: out.appendingPathComponent("manifest.json")).manifest)
        XCTAssertEqual(m2.slides.map(\.role), [.opening, nil, nil, .between, nil, .closing])
        XCTAssertEqual(m2.slide(number: 5)?.builds?.first?.file, "media/slide_005_b01.mov", "renumbered with its page")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("stills/slide_005_s02.png").path))

        // One deck with no logo pages gets them in place.
        try DeckCombiner.wrapInPlace(b, name: "B")
        XCTAssertEqual(DeckManifest.load(from: b.appendingPathComponent("manifest.json")).manifest?.slides.map(\.role), [.opening, nil, nil, .closing])
    }
}
