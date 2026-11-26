//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AppKit
import CoreMedia
import CoreVideo
@testable import ArcCaptureTests

/// A frame source the test drives by hand: it hands the session a target,
/// keeps the callbacks, and emits motion frames and settles on demand.
@MainActor
final class FakeFrameSource: FrameSource {
    var latestFrame: NSImage?
    var lastSettledFingerprint: [UInt8]?
    var isLatestFrameChanged = false
    var capturePixelWidth = 64
    var capturePixelHeight = 36
    var titleBarHeight: CGFloat = 28
    var onAudio: ((CMSampleBuffer) -> Void)?
    var lastFrameAge: TimeInterval? = 1.0          // quiet unless a test says otherwise
    var identicalFrameRun = 100                    // quiet
    /// Every read sees a new frame: the fake's clicks always "draw something" unless a test pins it.
    var changedFramesPinned: Int? = nil
    private var changedReads = 0
    var changedFrameCount: Int { if let p = changedFramesPinned { return p }; changedReads += 1; return changedReads }
    var currentFingerprint: [UInt8]?
    var holds: [TimeInterval] = []
    var restarts = 0
    private var onSettled: ((NSImage) -> Void)?
    private var onMotionFrame: ((CVPixelBuffer, CMTime) -> Void)?

    func findSlideshowWindow(bundleIdentifier: String, titleHint: String) async throws -> CaptureTarget {
        CaptureTarget(id: 1, title: "fake show", frame: CGRect(x: 0, y: 0, width: 1920, height: 1108))
    }
    func startCapture(target: CaptureTarget, onSettled: @escaping (NSImage) -> Void, onMotionFrame: @escaping (CVPixelBuffer, CMTime) -> Void) async throws {
        self.onSettled = onSettled; self.onMotionFrame = onMotionFrame
    }
    func stopCapture() async { onSettled = nil; onMotionFrame = nil }
    func forceMotionMode() {}
    func holdSettle(seconds: TimeInterval) { holds.append(seconds) }
    func resetSettleKeepMotion() {}
    func releaseSettleHold() {}
    func settleNow() { if let img = latestFrame { onSettled?(img) } }
    func restartStream() async -> Float? { restarts += 1; return nil }

    // MARK: test drive

    /// Show slide `n`: `motionFrames` distinct frames ~33 ms apart (a
    /// transition or a movie), then the slide settles on a flat colour.
    func showSlide(_ n: Int, motionFrames: Int = 0, then settle: Bool = true) async {
        let colour = Self.colour(n)
        isLatestFrameChanged = motionFrames > 0     // the session counts a motion frame only when the picture changed
        defer { isLatestFrameChanged = false }
        for i in 0..<motionFrames {
            let pb = Self.pixelBuffer(width: capturePixelWidth, height: capturePixelHeight, shade: UInt8((i * 37 + n * 11) % 256))
            onMotionFrame?(pb, CMClockGetTime(CMClockGetHostTimeClock()))
            try? await Task.sleep(for: .milliseconds(33))
        }
        let img = Self.image(colour)
        latestFrame = img
        let fp = [UInt8](repeating: UInt8(n * 40 % 256), count: 64)
        lastSettledFingerprint = fp; currentFingerprint = fp
        if settle { onSettled?(img) }
    }

    static func colour(_ n: Int) -> NSColor { NSColor(calibratedHue: CGFloat(n % 10) / 10, saturation: 0.8, brightness: 0.9, alpha: 1) }
    static func image(_ c: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 64, height: 36)); img.lockFocus(); c.setFill(); NSRect(x: 0, y: 0, width: 64, height: 36).fill(); img.unlockFocus(); return img
    }
    static func pixelBuffer(width: Int, height: Int, shade: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        memset(CVPixelBufferGetBaseAddress(b), Int32(shade), CVPixelBufferGetBytesPerRow(b) * height)
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }
}

/// A scripted presentation: N slides, builds per slide, movie slides. Each
/// click either consumes a build or moves the position; the test wires
/// `onAdvance` and `onBuildClick` to the fake frame source.
final class FakeDriver: PresentationDriver, @unchecked Sendable {
    let bundleIdentifier = "test.fake"
    let displayName = "Fake"
    let windowTitleHint = "fake show"
    var analysis: PPTXAnalysis
    private(set) var position = 0
    private var pendingBuilds: [Int: Int]
    private(set) var clicks: [(slide: Int, kind: String)] = []
    var onAdvance: ((Int) -> Void)?          // new position
    var onBuildClick: ((Int, Int) -> Void)?  // slide, builds left after this click

    init(slides: Int, builds: [Int: Int] = [:], movies: [Int: TimeInterval] = [:], loops: Set<Int> = []) {
        var a = PPTXAnalysis.empty
        a.slideCount = slides
        for n in 1...slides { a.clickCounts[n] = builds[n] ?? 0 }
        for (n, d) in movies { a.videoSlides.insert(n); a.slideDurations[n] = d }
        a.loopingSlides = loops
        analysis = a
        pendingBuilds = builds
    }

    func analyze(_ url: URL) -> PPTXAnalysis? { analysis }
    func openFile(_ url: URL) async throws {}
    func startSlideshow() async throws { position = 1; onAdvance?(1) }

    /// PowerPoint's starting slide, which a resume needs (V3, plan 1.2).
    var supportsRange: Bool { true }
    /// The slide the show was told to open on, for the resume tests.
    private(set) var startedFrom: Int?
    /// PowerPoint 16.113 accepts a starting slide and opens on slide 1 anyway
    /// (measured on the mini, 2026-09-18). Set this to reproduce that.
    var ignoresStartingSlide = false
    func startSlideshow(from: Int, to: Int) async throws {
        startedFrom = from
        position = ignoresStartingSlide ? 1 : max(1, from)
        onAdvance?(position)
    }
    func advanceSlide() async throws {
        if let left = pendingBuilds[position], left > 0 {
            pendingBuilds[position] = left - 1
            clicks.append((position, "build"))
            onBuildClick?(position, left - 1)
        } else {
            clicks.append((position, "leave"))
            position += 1
            onAdvance?(position)
        }
    }
    func sendNextClick() async throws { try await advanceSlide() }
    func playCurrentSlideMedia() async throws -> Int { 0 }
    func stopSlideshow() async throws {}
    func closeFile(_ url: URL) async throws {}
    func slideCount() async throws -> Int { analysis.slideCount }
    func currentSlideNumber() async throws -> Int { position }
}
