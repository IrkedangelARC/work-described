//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Accelerate
import Foundation

/// What one input is doing. DEAD is exact digital zero for a second: an unplugged or muted
/// input, or a missing microphone consent. A real converter never reads exact zero, so a
/// dead input can never pass for a quiet room.
public enum InputState: String, Codable, Sendable {
    case dead = "DEAD", present = "PRESENT", clipping = "CLIP"
}

public struct InputStatus: Equatable, Sendable {
    public var state = InputState.dead
    public var peakDB = -Double.infinity       // this block, dBFS peak
    public var peakHoldDB = -Double.infinity   // held 2 s, then falls 12 dB per second
    public var maxPeakDB = -Double.infinity    // highest since reset: headroom is its negative
    public var clipEvents = 0                  // runs of clipped samples since reset
    public var blockClipped = false            // true when THIS block held a clipped sample

    public init() {}
    /// dB left below full scale at the loudest moment since reset.
    public var headroomDB: Double { -maxPeakDB }
}

/// Clip tier 1 and input health for one channel (plan: "Input clip per channel").
/// Time comes from the sample count, so a test gets the same answer every run.
public final class InputMonitor {
    /// A sample at or above this (linear) is clipped: -0.01 dBFS.
    public static let clipThreshold: Float = 0.9988
    static let lampHold = 3.0, peakHold = 2.0, peakFall = 12.0, deadAfter = 1.0

    public let sampleRate: Double
    public private(set) var status = InputStatus()

    private var now = 0.0
    private var lastNonZero = -Double.infinity
    private var lastClip = -Double.infinity
    private var holdSetAt = 0.0
    private var inClipRun = false

    public init(sampleRate: Double) { self.sampleRate = sampleRate }

    public func reset() {
        status.maxPeakDB = -.infinity
        status.clipEvents = 0
        lastClip = -.infinity
    }

    public func process(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        let dt = Double(count) / sampleRate
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        now += dt

        let peakDB = peak > 0 ? 20 * log10(Double(peak)) : -Double.infinity
        status.peakDB = peakDB
        status.maxPeakDB = max(status.maxPeakDB, peakDB)
        if peak > 0 { lastNonZero = now }

        if peakDB >= status.peakHoldDB {
            status.peakHoldDB = peakDB
            holdSetAt = now
        } else if now - holdSetAt > Self.peakHold {
            status.peakHoldDB = max(peakDB, status.peakHoldDB - Self.peakFall * dt)
        }

        status.blockClipped = peak >= Self.clipThreshold
        if status.blockClipped {
            // Count runs, not samples: one overload is one event however long it lasts.
            for i in 0..<count {
                let clipped = abs(samples[i]) >= Self.clipThreshold
                if clipped && !inClipRun { status.clipEvents += 1 }
                inClipRun = clipped
            }
            lastClip = now
        } else {
            inClipRun = false
        }

        if now - lastClip < Self.lampHold {
            status.state = .clipping
        } else if now - lastNonZero >= Self.deadAfter {
            status.state = .dead
        } else {
            status.state = .present
        }
    }
}
