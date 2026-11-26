//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreImage
import AppKit

/// What the session needs from a frame source. FrameCapture is the
/// ScreenCaptureKit implementation; tests replay fingerprints through a fake.
@MainActor
/// The window a capture attaches to, as a plain value: the engine never
/// touches ScreenCaptureKit types, so a fake source can stand in for tests
/// (V2 refactor, 2026-09-12).
struct CaptureTarget: Equatable {
    let id: UInt32
    let title: String
    let frame: CGRect
}

protocol FrameSource: AnyObject {
    var latestFrame: NSImage? { get }
    var lastSettledFingerprint: [UInt8]? { get }
    var isLatestFrameChanged: Bool { get }
    var capturePixelWidth: Int { get }
    var titleBarHeight: CGFloat { get set }
    var capturePixelHeight: Int { get }

    func findSlideshowWindow(bundleIdentifier: String, titleHint: String) async throws -> CaptureTarget
    func startCapture(target: CaptureTarget,
                      onSettled: @escaping (NSImage) -> Void,
                      onMotionFrame: @escaping (CVPixelBuffer, CMTime) -> Void) async throws
    /// Called with every audio sample buffer the app's window filter yields.
    var onAudio: ((CMSampleBuffer) -> Void)? { get set }
    func stopCapture() async
    /// Open the motion gate with a long grace period (known video slides).
    func forceMotionMode()
    func holdSettle(seconds: TimeInterval)
    /// Fresh settle detection for the next slide; motion stays open.
    func resetSettleKeepMotion()
    /// Seconds since the stream last delivered a frame (nil before the first).
    var lastFrameAge: TimeInterval? { get }
    /// Consecutive frames without a visible change (the stream can run at
    /// 30 fps on a static slide, or send nothing at all; both mean quiet).
    var identicalFrameRun: Int { get }
    /// Frames that differed from the one before, since the stream started: the
    /// walk reads it around a click to know whether the click drew ANYTHING.
    var changedFrameCount: Int { get }
    /// Cancel a settle hold set earlier.
    func releaseSettleHold()
    /// Settle right now on the latest frame (the show moved on by itself).
    func settleNow()
    /// Fingerprint of the most recent frame (for coarse change checks).
    var currentFingerprint: [UInt8]? { get }
    /// Tear the stream down and attach to the window again (same callbacks,
    /// counters kept). Returns the mean difference between an independent
    /// screen read of the window and the last frame the stream delivered,
    /// taken BEFORE the restart: >0.01 means the stream had gone stale.
    func restartStream() async -> Float?
}

/// Captures frames from one window with ScreenCaptureKit and turns the frame
/// stream into two events: "settled" (N identical frames) and "motion frame"
/// (every frame while the motion gate is open). The arithmetic is in
/// FrameAnalysis; this class holds the counters and the stream.
@MainActor @Observable
final class FrameCapture: NSObject, FrameSource {

    enum State: String { case idle, capturing, settled, error }

    private(set) var state: State = .idle
    private(set) var errorMessage: String?
    private(set) var latestFrame: NSImage?
    private(set) var isSettled: Bool = false
    private(set) var isMotionDetected: Bool = false
    private(set) var isLatestFrameChanged: Bool = false
    private(set) var lastSettledFingerprint: [UInt8]?
    private(set) var capturePixelWidth: Int = 0
    private(set) var capturePixelHeight: Int = 0

    // Tunables (see FrameAnalysis for the pixel thresholds).
    let settleFrameCount = 5          // consecutive identical frames = settled
    let captureFrameRate = 30
    let motionFrameThreshold = 3      // changing frames before "motion"
    /// Chrome above the slide inside the captured window; the driver sets
    /// it (Keynote's in-window show has none: 28 px of slide were cropped).
    var titleBarHeight: CGFloat = 28
    private let defaultGraceFrames = 12   // ~400 ms: PowerPoint starts a transition late
    private var activeGraceFrames = 12

    private var stream: SCStream?
    private var streamOutput: StreamOutputDelegate?
    private var currentWindow: SCWindow?
    private var bundleID = ""
    private var titleHint = "slide show"
    private var previous: [UInt8]?
    private var identicalRun = 0
    private var changedFrames = 0
    var changedFrameCount: Int { changedFrames }
    /// ScreenCaptureKit stops delivering frames while the window is static
    /// (measured 2026-09-11: after a Circle Push transition no frame arrived
    /// for 30 s and every motion slide ran to the recording timeout). The
    /// settle rule counts identical FRAMES, so silence never settled. This
    /// watchdog settles on the last frame when the stream goes quiet.
    private var quietTask: Task<Void, Never>?
    /// No settle before this instant: a movie with subtle motion (time-lapse
    /// footage on 1.08 slide 20, 2026-09-11) reads as identical frames
    /// and would be cut after half a second; the analyzer knows how long it
    /// runs, so the session holds the settle for that long.
    private var settleHoldUntil = Date.distantPast
    private let quietSettleMs = 500
    private let quietSettleMotionMs = 800
    /// After a settle reset the transition may already have played (its
    /// frames arrived during the build walk) and nothing more will come.
    private let quietAfterResetMs = 2000
    /// Last fingerprint seen, kept across resets for a reset-time settle.
    private var lastFp: [UInt8]?
    private var lastFrameAt: Date?
    var lastFrameAge: TimeInterval? { lastFrameAt.map { Date().timeIntervalSince($0) } }
    var identicalFrameRun: Int { identicalRun }
    var currentFingerprint: [UInt8]? { lastFp }
    func releaseSettleHold() { settleHoldUntil = .distantPast }
    func settleNow() {
        settleHoldUntil = .distantPast
        guard !isSettled, latestFrame != nil else { return }
        settle(fingerprint: lastFp ?? [], reason: "forced: the show moved on by itself")
    }
    private var changingRun = 0
    private var frameNumber = 0
    private var onSettled: ((NSImage) -> Void)?
    private var onMotionFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    private var audioOutput: AudioOutputDelegate?
    /// One context for the life of the capture; the old code made one per frame.
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let debugLogInterval = 30

    // MARK: window

    /// backingScaleFactor of the screen containing the window's centre.
    /// SCWindow.frame is top-left based (CoreGraphics); NSScreen frames are
    /// bottom-left based, so convert before testing containment.
    static func backingScale(for cgFrame: CGRect) -> CGFloat {
        guard let main = NSScreen.screens.first else { return 2 }
        let centre = CGPoint(x: cgFrame.midX, y: cgFrame.midY)
        for s in NSScreen.screens {
            let f = s.frame
            let cg = CGRect(x: f.minX, y: main.frame.height - f.maxY, width: f.width, height: f.height)
            if cg.contains(centre) { return s.backingScaleFactor }
        }
        return main.backingScaleFactor
    }

    /// The windowed slideshow is titled "PowerPoint Slide Show - [deck]"
    /// and is 1600x900; document windows are 1920x1050 (measured 2026-09-11).
    /// Picking the largest window, as the old code did, attached the capture
    /// to an editor window whenever one was open and produced decks full of
    /// identical pages (suite builds8b). Title first, newest window second.
    /// SCWindows found so far, by id; the engine only holds the CaptureTarget.
    private var knownWindows: [UInt32: SCWindow] = [:]

    func findSlideshowWindow(bundleIdentifier: String, titleHint: String = "slide show") async throws -> CaptureTarget {
        let w = try await findSCWindow(bundleIdentifier: bundleIdentifier, titleHint: titleHint)
        knownWindows[w.windowID] = w
        return CaptureTarget(id: w.windowID, title: w.title ?? "", frame: w.frame)
    }

    private func findSCWindow(bundleIdentifier: String, titleHint: String = "slide show") async throws -> SCWindow {
        self.titleHint = titleHint
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let candidates = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == bundleIdentifier && $0.isOnScreen
                && $0.frame.width > 800 && $0.frame.height > 600
        }
        let titled = candidates.filter { ($0.title ?? "").localizedCaseInsensitiveContains(titleHint) }
        let pick = titled.max { $0.windowID < $1.windowID } ?? candidates.max { $0.windowID < $1.windowID }
        guard let w = pick else { throw CaptureError.slideshowWindowNotFound }
        DebugLog.log("Frame", "window \(w.windowID) \"\(w.title ?? "")\" \(Int(w.frame.width))x\(Int(w.frame.height)) of \(candidates.count) candidate(s)\(titled.isEmpty ? " (no slide show title, took the newest)" : "")")
        return w
    }

    // MARK: stream

    func startCapture(target: CaptureTarget,
                      onSettled: @escaping (NSImage) -> Void,
                      onMotionFrame: @escaping (CVPixelBuffer, CMTime) -> Void) async throws {
        guard let window = knownWindows[target.id] else { throw CaptureError.slideshowWindowNotFound }
        try await startCapture(window: window, onSettled: onSettled, onMotionFrame: onMotionFrame)
    }

    private func startCapture(window: SCWindow,
                      onSettled: @escaping (NSImage) -> Void,
                      onMotionFrame: @escaping (CVPixelBuffer, CMTime) -> Void) async throws {
        self.onSettled = onSettled
        self.onMotionFrame = onMotionFrame
        isSettled = false; isMotionDetected = false; identicalRun = 0; changingRun = 0; previous = nil; frameNumber = 0

        currentWindow = window
        bundleID = window.owningApplication?.bundleIdentifier ?? bundleID
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let contentHeight = window.frame.height - titleBarHeight
        config.sourceRect = CGRect(x: 0, y: titleBarHeight, width: window.frame.width, height: contentHeight)
        // Pixel scale of the DISPLAY holding the window. A hard-coded 2x on
        // the 1x extended display left the content in the top-left quarter
        // of a 2x buffer (every page captured there on 2026-09-11 afternoon).
        let scale = Self.backingScale(for: window.frame)
        config.width = Int(window.frame.width * scale)
        config.height = Int(contentHeight * scale)
        DebugLog.log("Frame", "capture scale \(scale)x -> \(config.width)x\(config.height)")
        capturePixelWidth = config.width
        capturePixelHeight = config.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(captureFrameRate))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = false
        // The presentation app's audio, same clock as the frames.
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        // Fingerprint + diff run on the capture queue; only the verdict and
        // the image hop to the main actor. That takes ~170 KB of arithmetic
        // per frame off the UI thread.
        let delegate = StreamOutputDelegate { [weak self] sampleBuffer in
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let fp = FrameAnalysis.fingerprint(pixelBuffer)
            let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            Task { @MainActor [weak self] in self?.handleFrame(pixelBuffer, fingerprint: fp, timestamp: ts) }
        }
        streamOutput = delegate
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(delegate, type: .screen,
                              sampleHandlerQueue: DispatchQueue(label: "com.example.arc.arccapture.capture", qos: .userInteractive))
        let audio = AudioOutputDelegate { [weak self] sb in self?.onAudio?(sb) }
        audioOutput = audio
        try s.addStreamOutput(audio, type: .audio,
                              sampleHandlerQueue: DispatchQueue(label: "com.example.arc.arccapture.audio", qos: .userInteractive))
        try await s.startCapture()
        stream = s
        state = .capturing
    }

    func restartStream() async -> Float? {
        guard let onSettled, let onMotionFrame, let old = currentWindow else { return nil }
        let last = previous ?? lastFp
        // Stop first: a screenshot of a window that a stream is already
        // capturing failed every time ("Failed to start stream due to
        // audio/video capture failure", 2026-09-12), so staleness was never
        // measured. With the stream down, the screenshot is the ground truth
        // against the last frame the stream delivered.
        quietTask?.cancel(); quietTask = nil
        streamOutput = nil
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        var staleness: Float? = nil
        if let last {
            let cfg = SCStreamConfiguration()
            // Same pixel scale as the stream: a 2x canvas on the 1x display
            // drew the window in the top-left quarter and read a constant
            // 0.624 against every frozen frame (evidence pair, 2026-09-12 07:56).
            let scale = Self.backingScale(for: old.frame)
            cfg.width = Int(old.frame.width * scale); cfg.height = Int((old.frame.height - titleBarHeight) * scale)
            cfg.sourceRect = CGRect(x: 0, y: titleBarHeight, width: old.frame.width, height: old.frame.height - titleBarHeight)
            cfg.showsCursor = false
            do {
                let cg = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: old), configuration: cfg)
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(nil, cg.width, cg.height, kCVPixelFormatType_32BGRA, nil, &pb)
                if let pb {
                    ciContext.render(CIImage(cgImage: cg), to: pb)
                    staleness = FrameAnalysis.difference(FrameAnalysis.fingerprint(pb), last)
                    // Evidence for a freeze: the screenshot and the stream's
                    // last frame, side by side on disk (slide 4 of short2
                    // read 0.624 three times running, 2026-09-12).
                    let stamp = Int(Date().timeIntervalSince1970)
                    let dir = URL(fileURLWithPath: "/tmp/arc-capture-freeze")
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    if let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                        try? png.write(to: dir.appendingPathComponent("\(stamp)_screenshot.png"))
                    }
                    if let lf = latestFrame, let tiff = lf.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: dir.appendingPathComponent("\(stamp)_stream.png"))
                    }
                    DebugLog.log("Frame", "staleness evidence written to /tmp/arc-capture-freeze/\(stamp)_*.png")
                }
            } catch {
                DebugLog.log("Frame", "staleness screenshot failed: \(error.localizedDescription)")
            }
        } else {
            DebugLog.log("Frame", "staleness unknown: no frame fingerprint to compare")
        }
        // Re-find the window (its id may have changed) and restart.
        let win = (try? await findSCWindow(bundleIdentifier: bundleID, titleHint: titleHint)) ?? old
        knownWindows[win.windowID] = win
        let keepMotion = isMotionDetected
        do {
            try await startCapture(window: win, onSettled: onSettled, onMotionFrame: onMotionFrame)
            isMotionDetected = keepMotion
            DebugLog.log("Frame", "stream restarted on window \(win.windowID) (was \(old.windowID)); screen-vs-stream diff before restart \(staleness.map { String(format: "%.4f", $0) } ?? "n/a")")
        } catch {
            DebugLog.log("Frame", "stream restart FAILED: \(error.localizedDescription)")
        }
        return staleness
    }

    /// Awaited teardown: no frame can arrive into a torn-down session.
    func stopCapture() async {
        quietTask?.cancel(); quietTask = nil
        streamOutput = nil
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        onSettled = nil
        onMotionFrame = nil
        state = .idle
    }

    /// Suppress settling for `seconds` from now (video slides).
    func holdSettle(seconds: TimeInterval) {
        settleHoldUntil = Date().addingTimeInterval(seconds)
        DebugLog.log("Frame", "settle held for \(Int(seconds)) s")
    }

    func forceMotionMode() {
        DebugLog.log("Frame", "force motion at f#\(frameNumber), grace 300")
        quietTask?.cancel(); quietTask = nil
        isMotionDetected = true; isSettled = false
        identicalRun = 0; changingRun = 0; previous = nil; frameNumber = 0
        activeGraceFrames = 300
    }

    func resetSettleKeepMotion() {
        DebugLog.log("Frame", "reset settle (keep motion) at f#\(frameNumber)")
        quietTask?.cancel(); quietTask = nil
        isSettled = false
        identicalRun = 0; changingRun = 0; previous = nil; frameNumber = 0
        activeGraceFrames = defaultGraceFrames
        settleHoldUntil = .distantPast
        armQuietWatchdog(fingerprint: lastFp ?? [], fixedMs: quietAfterResetMs)
    }

    // MARK: per frame (main actor)

    private func handleFrame(_ pixelBuffer: CVPixelBuffer, fingerprint fp: [UInt8], timestamp: CMTime) {
        frameNumber += 1
        latestFrame = nsImage(from: pixelBuffer)
        lastFp = fp
        lastFrameAt = Date()
        CaptureMonitor.shared.frameArrived()

        var diff: Float = 0
        if let prev = previous {
            diff = FrameAnalysis.difference(prev, fp)
            isLatestFrameChanged = diff >= FrameAnalysis.motionCountThreshold
            if diff < FrameAnalysis.settleThreshold {
                identicalRun += 1
                if changingRun > 0 { changingRun -= 1 }   // decay, not reset
            } else {
                identicalRun = 0; changedFrames += 1
                changingRun += 1
            }
        }
        previous = fp

        if frameNumber % debugLogInterval == 0 {
            DebugLog.log("Frame", "f#\(frameNumber) diff=\(String(format: "%.4f", diff)) identical=\(identicalRun) changing=\(changingRun) motion=\(isMotionDetected) settled=\(isSettled)")
        }

        let inGrace = frameNumber <= activeGraceFrames
        if !inGrace && changingRun >= motionFrameThreshold && !isMotionDetected {
            isMotionDetected = true
            if isSettled { isSettled = false }
            DebugLog.log("Frame", "motion at f#\(frameNumber) (changing=\(changingRun), diff=\(String(format: "%.4f", diff)))")
        }
        if isMotionDetected && !isSettled {
            onMotionFrame?(pixelBuffer, timestamp)
        }
        // During motion, demand a longer quiet run so a pause between build
        // steps does not read as the end.
        let needed = isMotionDetected ? settleFrameCount * 3 : settleFrameCount
        if !inGrace && identicalRun >= needed && !isSettled && Date() >= settleHoldUntil {
            settle(fingerprint: fp, reason: "identical=\(identicalRun), needed=\(needed)")
            return
        }
        armQuietWatchdog(fingerprint: fp)
    }

    private func settle(fingerprint fp: [UInt8], reason: String) {
        quietTask?.cancel(); quietTask = nil
        isSettled = true
        state = .settled
        lastSettledFingerprint = fp
        DebugLog.log("Frame", "settled at f#\(frameNumber) (\(reason), motion=\(isMotionDetected))")
        if let img = latestFrame { onSettled?(img) }
    }

    /// If no further frame arrives within the quiet window, the content is
    /// static: settle on the frame we have. A frame still inside the grace
    /// window gets a longer quiet period, because PowerPoint may simply not
    /// have started the transition yet.
    private func armQuietWatchdog(fingerprint fp: [UInt8], fixedMs: Int? = nil) {
        quietTask?.cancel()
        let atFrame = frameNumber
        let inGrace = frameNumber <= activeGraceFrames
        var ms = fixedMs ?? ((isMotionDetected ? quietSettleMotionMs : quietSettleMs) * (inGrace ? 3 : 1))
        let hold = settleHoldUntil.timeIntervalSinceNow
        if hold > 0 { ms = max(ms, Int(hold * 1000) + 200) }
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.stream != nil, self.frameNumber == atFrame, !self.isSettled, self.latestFrame != nil,
                      Date() >= self.settleHoldUntil else { return }
                self.settle(fingerprint: fp.isEmpty ? (self.lastFp ?? fp) : fp, reason: "quiet \(ms) ms after f#\(atFrame), identical=\(self.identicalRun)")
            }
        }
    }

    private func nsImage(from pixelBuffer: CVPixelBuffer) -> NSImage {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h)) else { return NSImage() }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    enum CaptureError: LocalizedError {
        case slideshowWindowNotFound
        case permissionDenied
        var errorDescription: String? {
            switch self {
            case .slideshowWindowNotFound: "Could not find the slideshow window. Make sure the presentation is in slideshow mode."
            case .permissionDenied: "Screen recording permission is required."
            }
        }
    }
}

extension FrameCapture: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            self.state = .error
            self.errorMessage = error.localizedDescription
            DebugLog.log("Frame", "stream stopped: \(error.localizedDescription)")
        }
    }
}

private final class AudioOutputDelegate: NSObject, SCStreamOutput {
    let handler: (CMSampleBuffer) -> Void
    init(handler: @escaping (CMSampleBuffer) -> Void) { self.handler = handler }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        handler(sampleBuffer)
    }
}

private final class StreamOutputDelegate: NSObject, SCStreamOutput {
    let handler: (CMSampleBuffer) -> Void
    init(handler: @escaping (CMSampleBuffer) -> Void) { self.handler = handler }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        handler(sampleBuffer)
    }
}
