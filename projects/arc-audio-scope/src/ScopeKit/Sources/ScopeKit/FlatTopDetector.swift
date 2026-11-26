//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// The reference arrived already clipped: something upstream (a console bus, a processor) hit
/// its ceiling, at a level below this input's full scale.
public struct ReferenceClip: Equatable, Sendable {
    /// Where the tops are cut off, dBFS peak at this input.
    public var ceilingDBFS: Double
    /// Flat tops seen in the last second.
    public var runs: Int
}

/// Tier 2 clip detection: flat tops below full scale.
///
/// A clipped wave runs dead straight along its ceiling and meets it at a corner. Three things
/// together, several times a second at about the same level, are the signature:
///   - a STRAIGHT run (second difference near zero) that is nearly level,
///   - entered and left through a CORNER (a second difference many times larger at each end),
///   - at the top of the wave, not through its middle.
/// Straight rather than flat, because a clipped top that has passed through a coupling capacitor
/// sags. A low sine is straight near its peak too, but it has no corner; a high sine has neither.
public final class FlatTopDetector {
    public let sampleRate: Double
    /// Second difference, relative to the level, under which the wave counts as straight.
    public var straightness = 3e-4
    /// The corner's second difference must be this many times `straightness`.
    public var cornerFactor = 10.0
    /// Straight samples in a row (second differences) for a flat top.
    public var minimumRun = 4
    /// Flat tops within a second, at ceilings within 1 dB, for a report.
    public var runsNeeded = 3
    /// Quieter than this (linear) is never judged.
    public var minimumLevel = 0.03
    /// At or above this the input itself is clipping: that is tier 1's.
    public var fullScale = 0.989

    private var x1: Float = 0, x2: Float = 0
    private var run = 0
    private var cornerBefore = false
    /// Samples since the last corner. A real corner can spread over two samples.
    private var sinceCorner = 1000
    /// A run that ended without a corner waits this many samples for one.
    private var pendingPeak = 0.0, pendingLeft = 0
    /// The loudest sample lately, falling about 8 dB a second. A flat top is the top of the wave.
    private var peak = 0.0
    /// Share of the samples at the top of the wave that are straight. Nearly all of them on a
    /// clipped wave; few on a smooth wave with noise riding on it, whose chance straight
    /// stretches would otherwise pass for flat tops.
    private var straightShare = 0.0
    private var runPeak = 0.0
    private var index = 0
    private var recent: [(at: Int, ceiling: Double)] = []
    private var quietUntil = 0

    public init(sampleRate: Double) { self.sampleRate = sampleRate }

    public func reset() {
        x1 = 0; x2 = 0; run = 0; recent = []; quietUntil = 0; index = 0
        sinceCorner = 1000; pendingLeft = 0; peak = 0; straightShare = 0
    }

    /// Feed the reference. Returns a report when it has just been found clipped (at most one
    /// every two seconds).
    public func process(_ x: UnsafePointer<Float>, count: Int) -> ReferenceClip? {
        var report: ReferenceClip?
        for i in 0..<count {
            let v = x[i]
            let level = Double(abs(x1))
            let d2 = Double(abs(v - 2 * x1 + x2))
            let judged = level > minimumLevel
            let rel = judged ? d2 / level : .infinity
            let corner = cornerFactor * straightness
            let slope = Double(abs(v - x1))
            peak = max(peak * 0.99998, level)
            let isCorner = judged && rel > corner
            if pendingLeft > 0 {
                pendingLeft -= 1
                if isCorner {
                    pendingLeft = 0
                    if let r = ended(pendingPeak) { report = r }
                }
            }
            let straight = rel < straightness && slope < 5e-3 * level
            if judged, level >= peak * 0.94 { straightShare += 0.002 * ((straight ? 1 : 0) - straightShare) }
            if straight {
                if run == 0 {
                    cornerBefore = sinceCorner <= 2
                    runPeak = 0
                }
                run += 1
                runPeak = max(runPeak, level, Double(abs(v)), Double(abs(x2)))
            } else {
                // It must leave through a corner too: noise on a smooth wave makes a straight
                // stretch by chance now and then, but not one with a corner at both ends.
                if run >= minimumRun, cornerBefore, runPeak < fullScale, runPeak >= peak * 0.94 {
                    if isCorner {
                        if let r = ended(runPeak) { report = r }
                    } else {
                        pendingPeak = runPeak; pendingLeft = 2
                    }
                }
                run = 0
            }
            // Coming up through the level floor is not a corner.
            sinceCorner = isCorner ? 0 : min(sinceCorner + 1, 1000)
            x2 = x1; x1 = v
            index += 1
        }
        return report
    }

    private func ended(_ ceiling: Double) -> ReferenceClip? {
        let window = Int(sampleRate)
        recent.removeAll { index - $0.at > window }
        recent.append((index, ceiling))
        if recent.count > 64 { recent.removeFirst() }
        let alike = recent.filter { abs(20 * log10($0.ceiling / ceiling)) <= 1 }
        guard alike.count >= runsNeeded, straightShare >= 0.5, index >= quietUntil else { return nil }
        quietUntil = index + 2 * window
        let top = alike.map(\.ceiling).max() ?? ceiling
        return ReferenceClip(ceilingDBFS: 20 * log10(top), runs: alike.count)
    }
}
