//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import AVFoundation
import ScreenCaptureKit
import ARCShowFormat

/// The very low resolution recording of the program display with the presentation's own sound: one
/// ScreenCaptureKit stream on the display, scaled to `longSide` and capped at `fps`, H.264 at
/// `bitsPerSecond`, the system audio (this app excluded) as AAC, written to one .mov for the whole session.
///
/// ScreenCaptureKit sends no frame while the picture is static, so the video is variable rate: a frame's
/// presentation time is the time the picture changed, which is exactly what the edit wants. Read the
/// timestamps, never assume `fps`. `startMono` is the capture clock reading of the first sample written, so
/// a time in the file plus `startMono` is `t_mono` on the track.
final class ProxyRecorder: NSObject, @unchecked Sendable {
    struct DisplayInfo: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
        let width: Int
        let height: Int
        let scale: CGFloat
        var label: String { "\(name) \(width)x\(height)" }
    }

    let longSide: CGFloat
    let fps: Int
    let bitsPerSecond: Int

    private let queue = DispatchQueue(label: "com.example.arc.arcslidelog.proxy", qos: .userInteractive)
    private var stream: SCStream?
    private var output: StreamOutput?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private(set) var pixelWidth = 0
    private(set) var pixelHeight = 0
    private(set) var url: URL?
    private var _frames = 0
    private var _audioSamples = 0
    private var _dropped = 0
    private var _startMono: Double?
    private var _lastFrameMono: Double?
    var frames: Int { queue.sync { _frames } }
    var audioSamples: Int { queue.sync { _audioSamples } }
    var dropped: Int { queue.sync { _dropped } }
    var startMono: Double? { queue.sync { _startMono } }
    var lastFrameMono: Double? { queue.sync { _lastFrameMono } }
    var onStopped: ((Error?) -> Void)?

    init(longSide: CGFloat = 320, fps: Int = 10, bitsPerSecond: Int = 150_000) {
        self.longSide = longSide; self.fps = fps; self.bitsPerSecond = bitsPerSecond
    }

    /// Displays ScreenCaptureKit can see, named as System Settings names them.
    static func displays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.displays.map { d in
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == d.displayID }
            return DisplayInfo(id: d.displayID, name: screen?.localizedName ?? "Display \(d.displayID)", width: d.width, height: d.height, scale: screen?.backingScaleFactor ?? 1)
        }
    }

    func start(display: DisplayInfo, to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let sc = content.displays.first(where: { $0.displayID == display.id }) else { throw RecorderError.displayGone }
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: sc, excludingApplications: me, exceptingWindows: [])
        let native = CGSize(width: CGFloat(display.width) * display.scale, height: CGFloat(display.height) * display.scale)
        let k = min(1, longSide / max(native.width, native.height))
        // H.264 wants even dimensions.
        let w = Int((native.width * k).rounded()) & ~1, h = Int((native.height * k).rounded()) & ~1
        let config = SCStreamConfiguration()
        config.width = w; config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 4
        config.showsCursor = false
        config.capturesAudio = true
        // Sync-grade sound: mono 16 kHz from the capture itself, AAC 24 kb/s in the file (about 11 MB an hour).
        config.sampleRate = 16_000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        pixelWidth = w; pixelHeight = h

        try? FileManager.default.removeItem(at: url)
        let wr = try AVAssetWriter(url: url, fileType: .mov)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitsPerSecond, AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                                              AVVideoMaxKeyFrameIntervalKey: fps * 2, AVVideoAllowFrameReorderingKey: false],
        ])
        v.expectsMediaDataInRealTime = true
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        var audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 24_000]
        if !wr.canApply(outputSettings: audioSettings, forMediaType: .audio) {
            audioSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
        }
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        a.expectsMediaDataInRealTime = true
        wr.add(v); wr.add(a)
        // A movie fragment every 2 s: the file plays up to the last fragment after a crash, a kill or a
        // power cut (at 5 s a kill lost 4.7 s); without this nothing is readable until finishWriting writes the moov.
        wr.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        wr.shouldOptimizeForNetworkUse = false
        guard wr.startWriting() else { throw wr.error ?? RecorderError.writer }
        queue.sync {
            writer = wr; video = v; audio = a; adaptor = ad
            sessionStarted = false; _frames = 0; _audioSamples = 0; _dropped = 0; _startMono = nil; _lastFrameMono = nil
            self.url = url
        }
        let out = StreamOutput { [weak self] sb, type in self?.handle(sb, type) }
        output = out
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(out, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(out, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    private func handle(_ sb: CMSampleBuffer, _ type: SCStreamOutputType) {
        guard let writer, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            _startMono = SlideTrack.monotonicSeconds()
        }
        switch type {
        case .screen:
            guard let pb = CMSampleBufferGetImageBuffer(sb), let video, let adaptor else { return }
            _lastFrameMono = SlideTrack.monotonicSeconds()
            guard video.isReadyForMoreMediaData else { _dropped += 1; return }
            if adaptor.append(pb, withPresentationTime: pts) { _frames += 1 } else { _dropped += 1 }
        case .audio:
            guard let audio, audio.isReadyForMoreMediaData else { return }
            if audio.append(sb) { _audioSamples += 1 }
        default:
            break
        }
    }

    /// Stop the stream and finish the file. Returns the file's size.
    func stop() async -> Int {
        output = nil
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        return await withCheckedContinuation { cont in
            queue.async { [self] in
                guard let writer, let url else { cont.resume(returning: 0); return }
                self.writer = nil
                guard sessionStarted, writer.status == .writing else { writer.cancelWriting(); cont.resume(returning: 0); return }
                video?.markAsFinished(); audio?.markAsFinished()
                writer.finishWriting {
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    cont.resume(returning: bytes)
                }
            }
        }
    }

    /// Finish without the stream teardown (quit): bounded wait.
    func finishNow(timeout: TimeInterval = 3) {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            guard let writer, sessionStarted, writer.status == .writing else { done.signal(); return }
            self.writer = nil
            video?.markAsFinished(); audio?.markAsFinished()
            writer.finishWriting { done.signal() }
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    enum RecorderError: LocalizedError {
        case displayGone, writer
        var errorDescription: String? {
            switch self {
            case .displayGone: "the chosen display is not there"
            case .writer: "the recording file could not be started"
            }
        }
    }
}

extension ProxyRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        self.stream = nil
        onStopped?(error)
    }
}

private final class StreamOutput: NSObject, SCStreamOutput {
    let handler: (CMSampleBuffer, SCStreamOutputType) -> Void
    init(handler: @escaping (CMSampleBuffer, SCStreamOutputType) -> Void) { self.handler = handler }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if type == .screen, CMSampleBufferGetImageBuffer(sampleBuffer) == nil { return }
        handler(sampleBuffer, type)
    }
}
