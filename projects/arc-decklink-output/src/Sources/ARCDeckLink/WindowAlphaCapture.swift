//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

//
//  WindowAlphaCapture.swift
//  Captures one of the app's own windows via ScreenCaptureKit with a clear
//  background, yielding 32BGRA frames whose alpha channel preserves window
//  transparency. Pair with DeckLinkFillKeyOutput in external-key mode to key
//  SwiftUI-rendered graphics on an ATEM without a matte render pass.
//
//  Requires the Screen Recording TCC permission even for the app's own
//  windows, and the captured window must be on screen (occlusion is fine,
//  minimized/hidden is not).
//

import CoreMedia
import CoreVideo
import Foundation
import os
import ScreenCaptureKit

public final class WindowAlphaCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    public enum CaptureError: LocalizedError {
        case windowNotFound

        public var errorDescription: String? {
            switch self {
            case .windowNotFound:
                return "Window to capture was not found on screen. It must be visible (occluded is OK, minimized is not)."
            }
        }
    }

    private struct State {
        var stream: SCStream?
        var config: SCStreamConfiguration?
        var sourceRect: CGRect?
        var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
        var onStopped: (@Sendable (Error?) -> Void)?
    }

    private let windowID: CGWindowID
    private let outputWidth: Int
    private let outputHeight: Int
    private let fps: Int
    private let queue = DispatchQueue(label: "com.arc.decklink.windowcapture", qos: .userInteractive)
    // Callbacks and the stream handle are set/cleared from the owner's thread
    // while SCK delivers frames and stop events on its own queues.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Called on an internal queue with each captured 32BGRA (alpha-preserving) frame.
    public var onFrame: (@Sendable (CVPixelBuffer) -> Void)? {
        get { state.withLock { $0.onFrame } }
        set { state.withLock { $0.onFrame = newValue } }
    }

    /// Called on an internal queue if the stream stops with an error.
    public var onStopped: (@Sendable (Error?) -> Void)? {
        get { state.withLock { $0.onStopped } }
        set { state.withLock { $0.onStopped = newValue } }
    }

    /// The part of the window to send, in window points (nil = the whole
    /// window). A program window on a 16:10 display holds a 16:9 picture with
    /// bars; without a crop SCK fits the whole 16:10 window into the 16:9
    /// frame and the room sees a pillarboxed, letterboxed slide (UltraStudio
    /// 4K Mini, 2026-09-16). Set before `start()`, or change it live with
    /// `update(sourceRect:)` when the window is resized.
    public var sourceRect: CGRect? {
        get { state.withLock { $0.sourceRect } }
        set { state.withLock { $0.sourceRect = newValue } }
    }

    /// Re-crop a running capture (a display assignment resized the window).
    public func update(sourceRect: CGRect?) async {
        let (stream, config) = state.withLock { s -> (SCStream?, SCStreamConfiguration?) in
            s.sourceRect = sourceRect
            return (s.stream, s.config)
        }
        guard let stream, let config else { return }
        config.sourceRect = sourceRect ?? .zero
        try? await stream.updateConfiguration(config)
    }

    /// - Parameters:
    ///   - windowNumber: `NSWindow.windowNumber` of the window to capture.
    ///   - outputWidth/outputHeight: pixel size of delivered frames (SCK scales).
    ///   - fps: capture cadence. SCK only delivers frames when content changes;
    ///     downstream consumers must tolerate gaps (a DeckLink sync output holds
    ///     the last displayed frame, so gaps are harmless there).
    public init(windowNumber: Int, outputWidth: Int, outputHeight: Int, fps: Int) {
        self.windowID = CGWindowID(windowNumber)
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.fps = fps
    }

    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = outputWidth
        config.height = outputHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.backgroundColor = CGColor.clear
        config.showsCursor = false
        config.scalesToFit = true
        config.queueDepth = 4
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        if let rect = state.withLock({ $0.sourceRect }) { config.sourceRect = rect }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        state.withLock { $0.stream = stream; $0.config = config }
    }

    public func stop() async {
        let stream = state.withLock { s -> SCStream? in
            let current = s.stream
            s.stream = nil
            s.config = nil
            return current
        }
        guard let stream else { return }
        try? await stream.stopCapture()
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        state.withLock { $0.onFrame }?(pixelBuffer)
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let callback = state.withLock { s -> (@Sendable (Error?) -> Void)? in
            s.stream = nil
            return s.onStopped
        }
        callback?(error)
    }
}
