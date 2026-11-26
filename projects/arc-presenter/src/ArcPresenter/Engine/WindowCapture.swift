//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import ScreenCaptureKit
import CoreMedia

/// V4: a live ScreenCaptureKit stream of one other app's window, drawn into a
/// layer Presenter owns. This is how the program output shows a PowerPoint
/// show WITHOUT going transparent: a transparent program window let the
/// per-display menu bar through on the program display (measured 2026-09-16,
/// docs/V4_SWITCHER.md), while an opaque one keeps it covered. PowerPoint keeps
/// rendering under the opaque window and the stream delivers its transitions
/// at ~37 fps (tools/covered_video_capture_bench.swift).
///
/// Frames are handed to the layer as IOSurfaces, zero-copy. SCStream only
/// emits a picture when pixels CHANGE (otherwise status-only buffers with no
/// image, measured 2026-09-16: 172 in 3 s on a static slide), and a stream
/// started on an already covered window gets no initial picture at all. So the
/// layer is seeded with a one-shot SCScreenshotManager render, which does work
/// on a covered window, and the stream takes over on the first change.
@MainActor
@Observable
final class WindowCapture {
    private(set) var isRunning = false
    private(set) var frameCount = 0
    /// Raw sink callbacks and the reasons frames were dropped before drawing,
    /// so "no picture" can be measured instead of guessed.
    private(set) var sinkCallbacks = 0
    private(set) var droppedNoImage = 0
    private(set) var droppedNoSurface = 0
    /// SCFrameStatus tally, e.g. ["complete": 12, "idle": 170].
    private(set) var frameStatuses: [String: Int] = [:]
    private(set) var seeded = false
    private(set) var lastFrameAt: Date?
    private(set) var lastError: String?
    private(set) var windowTitle: String?
    private(set) var windowID: CGWindowID?

    /// The program-output view of the stream. `makeMirror()` gives more views
    /// of the same frames (the SOURCES thumbnail); an NSView has one superview.
    @ObservationIgnored let view = CaptureLayerView()
    /// Weak: the representable that asked for a mirror owns it; a closed window's mirror leaves the
    /// table by itself (assessment 2026-09-20 item 5: a strong array kept every mirror ever made, each
    /// holding a full program frame).
    @ObservationIgnored private let mirrorTable = NSHashTable<CaptureLayerView>.weakObjects()
    private var mirrors: [CaptureLayerView] { mirrorTable.allObjects }
    @ObservationIgnored private var lastSurface: IOSurfaceRef?
    @ObservationIgnored private var lastSeed: CGImage?

    func makeMirror() -> CaptureLayerView {
        let v = CaptureLayerView()
        v.layer?.contentsRect = cropRect
        if let lastSurface, let buffer = view.retainedBuffer { v.show(lastSurface, keeping: buffer) }
        else if let lastSeed { v.show(lastSeed) }
        mirrorTable.add(v)
        return v
    }

    /// Seconds since the last picture arrived; nil before the first (the frozen rule, ZoomSource).
    var pictureAge: TimeInterval? { lastFrameAt.map { Date().timeIntervalSince($0) } }
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var sink: FrameSink?
    @ObservationIgnored private var watcher: StreamWatcher?
    /// The stream died (PowerPoint quit or crashed, the window closed). The
    /// layer would otherwise keep the last frame forever with SOURCES reading
    /// READY (stability audit 2026-09-16, R4).
    var onStopped: ((String) -> Void)?
    @ObservationIgnored private var isStarting = false
    /// macOS can hold SCShareableContent or startCapture behind a system
    /// dialog (the monthly screen-recording re-consent, measured 2026-09-16).
    /// The caller must never wedge on it: give up, report, and let the
    /// operator answer the dialog.
    let startTimeout: Double = 8

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    /// Shows the system prompt once; the grant needs an app relaunch to take effect.
    static func requestPermission() { if !hasPermission { _ = CGRequestScreenCaptureAccess() } }

    /// Attach to the first on-screen window of `ownerBundleID` whose title starts
    /// with `titlePrefix`, at `pixelSize`. Returns once the first frame has been
    /// drawn (or false after `firstFrameTimeout`).
    func start(ownerBundleID: String, titlePrefix: String, pixelSize: CGSize, firstFrameTimeout: Double = 3) async -> Bool {
        pendingCropTop = 0   // a PowerPoint show fills its window; no strip to cut
        return await start(pixelSize: pixelSize, firstFrameTimeout: firstFrameTimeout,
                    describe: "no window of \(ownerBundleID) titled \(titlePrefix)…") {
            $0.owningApplication?.bundleIdentifier == ownerBundleID && ($0.title ?? "").hasPrefix(titlePrefix)
        }
    }

    /// Attach to one window by its window-server ID (the generic window source).
    /// The stream is the WINDOW's own pixel size (its frame × `scale`), never the
    /// program's: SCK draws a window smaller than the buffer at native pixels,
    /// offset and clipped, and never scales it (Zoom drill 2026-09-20, an
    /// unparked 1309x1122 meeting window sat top-right of a 1920x1280 program,
    /// clipped). A buffer of the window's size lets the layer letterbox it.
    /// `cropTop`: points cut off the top of the picture (the app's own title strip, SourceProfile).
    func start(windowID: CGWindowID, scale: CGFloat, cropTop: CGFloat = 0, firstFrameTimeout: Double = 3) async -> Bool {
        pendingCropTop = cropTop
        if isRunning, self.windowID == windowID {
            // Already streaming this window: the crop still has to follow the (new) profile.
            applyCrop(Self.contentsRect(cropTop: cropTop, windowHeight: lastWindowHeight))
            return true
        }
        return await start(pixelSize: nil, scale: scale, firstFrameTimeout: firstFrameTimeout, describe: "window \(windowID) is gone") {
            $0.windowID == windowID
        }
    }
    @ObservationIgnored private var lastWindowHeight: CGFloat = 0

    /// The crop as the layer wants it: `contentsRect` in unit space, origin at the BOTTOM-left of the
    /// picture (an unflipped CALayer), so cutting the top means keeping height from y = 0.
    nonisolated static func contentsRect(cropTop: CGFloat, windowHeight: CGFloat) -> CGRect {
        guard cropTop > 0, windowHeight > cropTop + 8 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: 0, y: 0, width: 1, height: 1 - cropTop / windowHeight)
    }

    @ObservationIgnored private var pendingCropTop: CGFloat = 0
    @ObservationIgnored private var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private func applyCrop(_ rect: CGRect) {
        cropRect = rect
        view.layer?.contentsRect = rect
        mirrors.forEach { $0.layer?.contentsRect = rect }
    }

    /// Stream buffer for a window of `size` points on a `scale` display: whole
    /// even pixels (BGRA streams want even dimensions), never below 2x2.
    nonisolated static func streamSize(for size: CGSize, scale: CGFloat) -> CGSize {
        func even(_ v: CGFloat) -> CGFloat {
            let px = (v * max(scale, 1)).rounded(.down)
            return max(2, (px / 2).rounded(.down) * 2)
        }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    private func start(pixelSize: CGSize?, scale: CGFloat = 1, firstFrameTimeout: Double, describe missing: String,
                       matching: (SCWindow) -> Bool) async -> Bool {
        if isRunning { return true }
        if isStarting { return false }
        isStarting = true
        defer { isStarting = false }
        lastError = nil
        guard Self.hasPermission else {
            lastError = "Screen Recording permission is needed to show another app on the program output. Allow it in System Settings, then relaunch ARC Presenter"
            Self.requestPermission()
            return false
        }
        do {
            guard let content = try await Self.within(startTimeout, {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }) else {
                lastError = "the system did not list windows within \(Int(startTimeout)) s. A screen-recording dialog may be waiting for an answer"
                return false
            }
            guard let window = content.windows.first(where: matching) else {
                lastError = missing
                return false
            }
            windowTitle = window.title
            windowID = window.windowID
            lastWindowHeight = window.frame.height
            applyCrop(Self.contentsRect(cropTop: pendingCropTop, windowHeight: window.frame.height))
            let config = SCStreamConfiguration()
            let size = pixelSize ?? Self.streamSize(for: window.frame.size, scale: scale)
            config.width = Int(size.width)
            config.height = Int(size.height)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 4
            config.showsCursor = false
            let sink = FrameSink { [weak self] buffer, status in
                Task { @MainActor in self?.deliver(buffer, status: status) }
            }
            let watcher = StreamWatcher { [weak self] error in
                Task { @MainActor in self?.streamDied(error) }
            }
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: watcher)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "arc.presenter.capture"))
            self.watcher = watcher
            guard try await Self.within(startTimeout, { try await stream.startCapture() }) != nil else {
                lastError = "the capture did not start within \(Int(startTimeout)) s. A screen-recording dialog may be waiting for an answer"
                Task.detached { try? await stream.stopCapture() }
                return false
            }
            self.stream = stream
            self.sink = sink
            isRunning = true
            frameCount = 0; sinkCallbacks = 0; droppedNoImage = 0; droppedNoSurface = 0; frameStatuses = [:]; seeded = false
            // Seed the picture with a one-shot render (works on a covered window);
            // the stream only sends pictures on change.
            let filter = SCContentFilter(desktopIndependentWindow: window)
            if let seed = try? await Self.within(firstFrameTimeout, {
                try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }) {
                view.show(seed); mirrors.forEach { $0.show(seed) }
                lastSeed = seed; lastSurface = nil
                seeded = true
                lastFrameAt = Date()
            }
            // Polled, not a continuation: a continuation child in a task group
            // never resumes on cancel and the group then waits forever.
            let deadline = Date().addingTimeInterval(firstFrameTimeout)
            while !seeded, frameCount == 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if !seeded, frameCount == 0 {
                lastError = "the capture started but no picture arrived in \(Int(firstFrameTimeout)) s (sink callbacks \(sinkCallbacks), statuses \(frameStatuses))"
                await stop()
                return false
            }
            return true
        } catch {
            lastError = "capture failed: \(error.localizedDescription)"
            return false
        }
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        sink = nil
        isRunning = false
        seeded = false
        windowTitle = nil
        view.clear(); mirrors.forEach { $0.clear() }
        lastSurface = nil; lastSeed = nil
        // Not awaited past a short grace: stopCapture can hang behind the same dialogs.
        _ = try? await Self.within(2, { try await stream.stopCapture() })
    }

    /// Run `work` with a deadline; nil on timeout. The caller resumes as soon
    /// as either side finishes; a hung `work` is left to finish on its own
    /// rather than holding the caller (a task group would wait for it).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
    private static func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T? {
        let once = Once()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T?, Error>) in
            Task.detached {
                do { let v = try await work(); if once.first() { c.resume(returning: v) } }
                catch { if once.first() { c.resume(throwing: error) } }
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(seconds))
                if once.first() { c.resume(returning: nil) }
            }
        }
    }

    private func deliver(_ buffer: CVPixelBuffer?, status: String) {
        sinkCallbacks += 1
        frameStatuses[status, default: 0] += 1
        guard let buffer else { droppedNoImage += 1; return }
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { droppedNoSurface += 1; return }
        view.show(surface, keeping: buffer); mirrors.forEach { $0.show(surface, keeping: buffer) }
        lastSurface = surface
        frameCount += 1
        lastFrameAt = Date()
    }

    /// Receives frames on the capture queue; pure plumbing, no state.
    private final class FrameSink: NSObject, SCStreamOutput {
        let onFrame: (CVPixelBuffer?, String) -> Void
        init(onFrame: @escaping (CVPixelBuffer?, String) -> Void) { self.onFrame = onFrame }
        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen else { return }
            var status = "unknown"
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let raw = attachments.first?[.status] as? Int, let s = SCFrameStatus(rawValue: raw) {
                switch s {
                case .complete: status = "complete"
                case .idle: status = "idle"
                case .blank: status = "blank"
                case .suspended: status = "suspended"
                case .started: status = "started"
                case .stopped: status = "stopped"
                @unknown default: status = "other"
                }
            }
            onFrame(CMSampleBufferGetImageBuffer(sampleBuffer), status)
        }
    }

    private func streamDied(_ error: Error) {
        guard isRunning else { return }
        let reason = "the window capture stopped: \(error.localizedDescription)"
        stream = nil; sink = nil; watcher = nil
        isRunning = false
        lastError = reason
        ShowLog.error("capture stopped by the system: \(error.localizedDescription)")
        onStopped?(reason)
    }

    var stateJSON: String {
        let title = windowTitle.map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" } ?? "null"
        let err = lastError.map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" } ?? "null"
        let age = lastFrameAt.map { String(format: "%.2f", Date().timeIntervalSince($0)) } ?? "null"
        let statuses = frameStatuses.map { "\"\($0.key)\":\($0.value)" }.sorted().joined(separator: ",")
        return "{\"running\":\(isRunning),\"permission\":\(Self.hasPermission),\"seeded\":\(seeded),\"frames\":\(frameCount),\"sinkCallbacks\":\(sinkCallbacks),\"statuses\":{\(statuses)},\"droppedNoImage\":\(droppedNoImage),\"droppedNoSurface\":\(droppedNoSurface),\"lastFrameAge\":\(age),\"window\":\(title),\"error\":\(err)}"
    }
}

/// A black, layer-backed view whose layer shows the latest captured IOSurface,
/// letterboxed. The pixel buffer is kept alive until the next frame replaces it
/// so the surface is never recycled under the layer.
final class CaptureLayerView: NSView {
    private(set) var retainedBuffer: CVPixelBuffer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ surface: IOSurfaceRef, keeping buffer: CVPixelBuffer) {
        retainedBuffer = buffer
        layer?.contents = surface
    }

    /// The seed picture (one-shot render) until the stream's first change.
    func show(_ image: CGImage) {
        retainedBuffer = nil
        layer?.contents = image
    }

    func clear() {
        retainedBuffer = nil
        layer?.contents = nil
    }
}

/// The captured PowerPoint show for the program output: knows which window to
/// attach to and at what size, so SwitchEngine only says start/stop.
@MainActor
final class PowerPointShowCapture: SwitchEngine.LiveCapture {
    let capture: WindowCapture
    private let powerPoint: PowerPointSource
    private let displays: DisplayManager

    init(capture: WindowCapture, powerPoint: PowerPointSource, displays: DisplayManager) {
        self.capture = capture
        self.powerPoint = powerPoint
        self.displays = displays
    }

    var isRunning: Bool { capture.isRunning }
    var lastError: String? { capture.lastError }

    func start() async -> Bool {
        guard let base = powerPoint.file?.deletingPathExtension().lastPathComponent else { return false }
        // The stream may be on a parked window (WindowShowCapture): restart it on the show.
        if capture.isRunning, !(capture.windowTitle ?? "").hasPrefix("PowerPoint Slide Show - [\(base)") { await capture.stop() }
        return await capture.start(ownerBundleID: PowerPointSource.bundleID,
                                   titlePrefix: "PowerPoint Slide Show - [\(base)",
                                   pixelSize: PowerPointShowCapture.programPixelSize(displays))
    }

    func stop() async { await capture.stop() }

    /// The program display's backing scale (2 when none is assigned: a Retina-sharp default).
    static func programScale(_ displays: DisplayManager) -> CGFloat {
        guard let id = displays.programScreenID,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
              }) else { return 2 }
        return screen.backingScaleFactor
    }

    /// Program display pixels (points × backing scale) so the picture is sharp.
    static func programPixelSize(_ displays: DisplayManager) -> CGSize {
        guard let id = displays.programScreenID,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
              }) else { return CGSize(width: 1920, height: 1080) }
        let scale = screen.backingScaleFactor
        return CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
    }
}


/// The same stream, fed from whatever window WindowSource parked. Shares the one
/// WindowCapture with PowerPointShowCapture: one external picture at a time.
@MainActor
final class WindowShowCapture: SwitchEngine.LiveCapture {
    let capture: WindowCapture
    private let source: WindowSource
    private let displays: DisplayManager

    init(capture: WindowCapture, source: WindowSource, displays: DisplayManager) {
        self.capture = capture
        self.source = source
        self.displays = displays
    }

    var isRunning: Bool { capture.isRunning && capture.windowID == source.pick?.windowID }
    var lastError: String? { capture.lastError }

    func start() async -> Bool {
        guard let pick = source.pick else { return false }
        // The stream may still be on PowerPoint's window: restart it on this one.
        if capture.isRunning, capture.windowID != pick.windowID { await capture.stop() }
        // The window's own size at the program display's scale (letterboxed by the layer); see start(windowID:).
        return await capture.start(windowID: pick.windowID, scale: PowerPointShowCapture.programScale(displays), cropTop: source.profile.cropTop)
    }

    func stop() async { await capture.stop() }
}

/// SCStreamDelegate needs an NSObject; WindowCapture is a main-actor model.
private final class StreamWatcher: NSObject, SCStreamDelegate {
    private let onError: @Sendable (Error) -> Void
    init(onError: @escaping @Sendable (Error) -> Void) { self.onError = onError }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError(error) }
}
