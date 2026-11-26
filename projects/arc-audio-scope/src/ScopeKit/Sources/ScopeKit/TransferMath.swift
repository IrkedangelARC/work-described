//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

extension TransferResult {
    /// Smoothing choices, as the octave fraction averaged over. 24 = the points as measured.
    public static let smoothings = [24, 12, 6, 3]

    /// Each point averaged with its neighbours across 1/`fraction` octave, weighted by coherence
    /// so a doubtful point pulls less. Phase is averaged as a direction, so it survives a wrap.
    public func smoothed(fraction: Int) -> TransferResult {
        let half = max(0, 24 / max(fraction, 1) / 2)
        guard half > 0, !frequencies.isEmpty else { return self }
        var out = self
        let n = frequencies.count
        for b in 0..<n where valid[b] {
            var w = 0.0, mag = 0.0, re = 0.0, im = 0.0, coh = 0.0, count = 0.0
            for j in max(0, b - half)...min(n - 1, b + half) where valid[j] {
                let weight = Double(max(coherence[j], 0.01))
                let phase = Double(phaseDegrees[j]) * .pi / 180
                w += weight; mag += weight * Double(magnitudeDB[j])
                re += weight * cos(phase); im += weight * sin(phase)
                coh += Double(coherence[j]); count += 1
            }
            out.magnitudeDB[b] = Float(mag / w)
            out.phaseDegrees[b] = Float(atan2(im, re) * 180 / .pi)
            out.coherence[b] = Float(coh / count)
        }
        return out
    }

    /// Phase with the wraps taken out, degrees, following the trusted points from the bottom up.
    /// NaN where a point is not trusted (not valid, or under `threshold` coherence).
    public func unwrappedPhase(threshold: Float) -> [Float] {
        Self.unwrap(phaseDegrees, trusted: frequencies.indices.map { valid[$0] && coherence[$0] >= threshold })
    }

    public static func unwrap(_ phase: [Float], trusted: [Bool]) -> [Float] {
        var out = [Float](repeating: .nan, count: phase.count)
        var turns: Float = 0
        var last: Float?
        for b in 0..<phase.count where b < trusted.count && trusted[b] {
            let p = phase[b]
            if let last {
                if p - last > 180 { turns -= 360 } else if p - last < -180 { turns += 360 }
            }
            last = p
            out[b] = p + turns
        }
        return out
    }
}

/// A captured transfer function: what the ALIGN plots showed when it was taken.
public struct TransferTrace: Codable, Equatable, Sendable, Identifiable {
    public static let limit = 8
    public var id = UUID()
    public var name: String
    public var date = Date()
    public var slot: Int
    public var visible = true
    /// Per 1/24 octave band. NaN-free: untrusted points are marked in `trusted`.
    public var magnitudeDB: [Float]
    public var phaseDegrees: [Float]
    public var coherence: [Float]
    public var trusted: [Bool]
    public var delaySamples: Int
    /// What the magnitude plot's 0 dB line stood for when this was taken.
    public var zeroDB: Float

    public init(name: String, slot: Int, result: TransferResult, threshold: Float, delaySamples: Int, zeroDB: Float = 0) {
        self.name = name; self.slot = slot; self.zeroDB = zeroDB
        magnitudeDB = result.magnitudeDB; phaseDegrees = result.phaseDegrees; coherence = result.coherence
        trusted = result.frequencies.indices.map { result.valid[$0] && result.coherence[$0] >= threshold }
        self.delaySamples = delaySamples
    }
}

/// Tier 3 clip watch: does the mic stop following the reference when the reference gets loud?
/// A system driven into distortion makes sound the reference does not explain, so coherence
/// falls with level. It is a warning, not proof: a noisy room does not do this, but a compressor
/// or a limiter in the chain does.
public final class DistortionMonitor {
    public struct Verdict: Equatable, Sendable {
        public var suspected: Bool
        /// Coherence at the loudest reference level seen, and 6 to 18 dB below it.
        public var loudCoherence: Double
        public var quietCoherence: Double
        public var loudLevelDB: Double
    }

    /// Coherence must fall this far at the loud end, from a quiet end that is at least `minimumQuiet`.
    public var drop = 0.15
    public var minimumQuiet = 0.7
    /// Readings a level bin needs before it counts.
    public var minimumCount = 20

    private static let binDB = 3.0, floorDB = -90.0, bins = 30
    private var sum = [Double](repeating: 0, count: DistortionMonitor.bins)
    private var count = [Double](repeating: 0, count: DistortionMonitor.bins)

    public init() {}

    public func reset() {
        for i in 0..<Self.bins { sum[i] = 0; count[i] = 0 }
    }

    /// One reading: the reference level and the mean coherence over the same stretch of time.
    public func add(referenceDB: Double, coherence: Double) {
        guard referenceDB.isFinite, coherence.isFinite else { return }
        let i = Int(((referenceDB - Self.floorDB) / Self.binDB).rounded(.down))
        guard (0..<Self.bins).contains(i) else { return }
        // Old readings fade, so a fault that has been fixed stops being reported.
        if count[i] > 200 { sum[i] *= 0.5; count[i] *= 0.5 }
        sum[i] += coherence; count[i] += 1
    }

    public var verdict: Verdict? {
        guard let loud = (0..<Self.bins).last(where: { count[$0] >= Double(minimumCount) }) else { return nil }
        // The best of the quieter levels: the ones in between are passages on their way up or
        // down, where the average still holds some of the loud part.
        var quietC = -1.0
        for i in max(0, loud - 6)...max(0, loud - 2) where i < loud && count[i] >= Double(minimumCount) {
            quietC = max(quietC, sum[i] / count[i])
        }
        guard quietC >= 0 else { return nil }
        let loudC = sum[loud] / count[loud]
        return Verdict(suspected: quietC >= minimumQuiet && loudC <= quietC - drop, loudCoherence: loudC, quietCoherence: quietC,
                       loudLevelDB: Self.floorDB + (Double(loud) + 0.5) * Self.binDB)
    }
}
