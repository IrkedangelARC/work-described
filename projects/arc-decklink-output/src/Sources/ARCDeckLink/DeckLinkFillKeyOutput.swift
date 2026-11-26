//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

//
//  DeckLinkFillKeyOutput.swift
//  Swift facade over DeckLinkBridge. All apps should import ARCDeckLink and
//  use these types; DeckLinkBridge is an implementation detail.
//

import CoreVideo
import DeckLinkBridge
import Foundation
import os

public enum DeckLinkKeyerMode: Int, CaseIterable, Codable, Sendable {
    /// Plain program video (opaque frames, no keying).
    case none = 0
    /// Device keys over its own passthrough input.
    case internalKey = 1
    /// Device emits fill + key for a downstream switcher keyer.
    /// Use this for the ATEM Mini Extreme ISO G2 over Thunderbolt.
    case externalKey = 2

    var bridgeMode: ARCDLKeyerMode {
        ARCDLKeyerMode(rawValue: rawValue) ?? .none
    }
}

public struct DeckLinkDevice: Identifiable, Hashable, Sendable {
    public let persistentID: Int64
    public let name: String
    public let supportsPlayback: Bool
    public let supportsInternalKeying: Bool
    public let supportsExternalKeying: Bool

    public var id: Int64 { persistentID }

    /// Public so consumers can build fixtures for tests and previews.
    public init(persistentID: Int64, name: String, supportsPlayback: Bool, supportsInternalKeying: Bool, supportsExternalKeying: Bool) {
        self.persistentID = persistentID
        self.name = name
        self.supportsPlayback = supportsPlayback
        self.supportsInternalKeying = supportsInternalKeying
        self.supportsExternalKeying = supportsExternalKeying
    }
}

public enum DeckLinkOutputError: LocalizedError {
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .startFailed(let message): return message
        }
    }
}

/// Thread-safe fill+key playout to a DeckLink output device.
///
/// `send(fill:key:)` may be called from any queue (e.g. a capture callback);
/// frames are displayed synchronously on an internal serial queue and new
/// frames are dropped while one is in flight, so callers are never blocked.
public final class DeckLinkFillKeyOutput: @unchecked Sendable {

    /// True when the Blackmagic Desktop Video driver is installed.
    public static var isDriverInstalled: Bool {
        ARCDLFillKeyOutput.driverInstalled
    }

    /// Playback-capable DeckLink devices currently connected (includes an
    /// ATEM Mini Extreme ISO G2 attached over Thunderbolt).
    public static func devices() -> [DeckLinkDevice] {
        ARCDLFillKeyOutput.outputDevices().map { info in
            DeckLinkDevice(persistentID: info.persistentID,
                           name: info.name,
                           supportsPlayback: info.supportsPlayback,
                           supportsInternalKeying: info.supportsInternalKeying,
                           supportsExternalKeying: info.supportsExternalKeying)
        }
    }

    private struct State {
        var running = false
        var inFlight = false
        var sent = 0
        var dropped = 0
    }

    private let bridge = ARCDLFillKeyOutput()
    private let queue = DispatchQueue(label: "com.arc.decklink.output", qos: .userInteractive)
    // Unfair lock, not NSLock: send() acquires on the caller's thread and the
    // in-flight flag clears on the output queue, so the guard must be a plain
    // mutex with no thread affinity.
    private let state = OSAllocatedUnfairLock(initialState: State())

    public var isRunning: Bool { state.withLock { $0.running } }
    public var sentFrames: Int { state.withLock { $0.sent } }
    public var droppedFrames: Int { state.withLock { $0.dropped } }

    public init() {}

    /// Start output. Pass `devicePersistentID: 0` for the first available device.
    public func start(devicePersistentID: Int64,
                      width: Int,
                      height: Int,
                      fps: Double,
                      keyer: DeckLinkKeyerMode) throws {
        try queue.sync {
            var fpsNumer = Int32((fps * 1000).rounded())
            var fpsDenom: Int32 = 1000
            // Normalize NTSC-family rates to their exact fractions.
            if abs(fps - 59.94) < 0.005 { fpsNumer = 60000; fpsDenom = 1001 }
            if abs(fps - 29.97) < 0.005 { fpsNumer = 30000; fpsDenom = 1001 }
            if abs(fps - 23.976) < 0.005 { fpsNumer = 24000; fpsDenom = 1001 }

            do {
                try bridge.start(withPersistentID: devicePersistentID,
                                 width: Int32(width),
                                 height: Int32(height),
                                 fpsNumer: fpsNumer,
                                 fpsDenom: fpsDenom,
                                 keyerMode: keyer.bridgeMode)
            } catch {
                throw DeckLinkOutputError.startFailed(error.localizedDescription)
            }
            state.withLock { $0 = State(running: true, inFlight: false, sent: 0, dropped: 0) }
        }
    }

    /// Display a frame. `fill` must be 32BGRA at the started size. If `key`
    /// is provided, its blue channel becomes the output alpha (white-on-black
    /// matte); otherwise `fill`'s own alpha channel is used.
    public func send(fill: CVPixelBuffer, key: CVPixelBuffer? = nil) {
        // Drop rather than queue: DisplayVideoFrameSync can block until
        // scanout, and an unbounded queue would add latency without bound.
        let proceed = state.withLock { s -> Bool in
            guard s.running else { return false }
            guard !s.inFlight else {
                s.dropped += 1
                return false
            }
            s.inFlight = true
            return true
        }
        guard proceed else { return }
        queue.async { [self] in
            let displayed = bridge.sendFrame(withFill: fill, key: key)
            state.withLock { s in
                s.inFlight = false
                if displayed { s.sent += 1 } else { s.dropped += 1 }
            }
        }
    }

    public var lastErrorMessage: String? {
        // The bridge property is nonatomic and written on `queue`; read it there.
        queue.sync { bridge.lastErrorMessage }
    }

    public func stop() {
        // Mark stopped first so racing send() calls stop enqueueing, then
        // drain the queue and shut the device down.
        state.withLock {
            $0.running = false
            $0.inFlight = false
        }
        // Bounded: a frame blocked inside DisplayVideoFrameSync to a dead
        // device would otherwise hold the caller (the main thread) forever.
        let done = DispatchSemaphore(value: 0)
        queue.async { [bridge] in
            bridge.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    deinit {
        bridge.stop()
    }
}
