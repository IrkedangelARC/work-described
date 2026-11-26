//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Accelerate
import Foundation

/// Frequency weighting of a level reading (IEC 61672). Z is flat.
public enum Weighting: String, Codable, CaseIterable, Sendable {
    case a = "A", c = "C", z = "Z"
}

/// One second-order section, normalised so a0 = 1: y = b0 x + b1 x1 + b2 x2 - a1 y1 - a2 y2.
public struct Biquad: Equatable, Sendable {
    public var b0, b1, b2, a1, a2: Double

    /// Magnitude at `frequency` in Hz.
    public func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return sqrt((nr * nr + ni * ni) / (dr * dr + di * di))
    }
}

/// A and C weighting as biquad cascades, designed for the running sample rate.
///
/// The analog prototypes are the IEC 61672 pole sets. Each first-order section goes through
/// the bilinear transform with its own corner pre-warped, so the corners sit at the right
/// frequencies at 48 kHz. The curve then bends early only close to Nyquist; the tests hold it
/// to the class 1 limits at every standard frequency.
public enum WeightingDesign {
    static let f1 = 20.598997, f2 = 107.65265, f3 = 737.86223, f4 = 12194.217

    public static func sections(_ weighting: Weighting, sampleRate: Double) -> [Biquad] {
        let k = 2 * sampleRate
        func warp(_ f: Double) -> Double { k * tan(Double.pi * min(f, 0.49 * sampleRate) / sampleRate) }
        // First-order pieces as (numerator, denominator) polynomials in z^-1.
        func highpass(_ f: Double) -> ([Double], [Double]) { let w = warp(f); return ([k, -k], [k + w, w - k]) }
        func lowpass(_ f: Double) -> ([Double], [Double]) { let w = warp(f); return ([w, w], [k + w, w - k]) }
        func pair(_ p: ([Double], [Double]), _ q: ([Double], [Double])) -> Biquad {
            let n = [p.0[0] * q.0[0], p.0[0] * q.0[1] + p.0[1] * q.0[0], p.0[1] * q.0[1]]
            let d = [p.1[0] * q.1[0], p.1[0] * q.1[1] + p.1[1] * q.1[0], p.1[1] * q.1[1]]
            return Biquad(b0: n[0] / d[0], b1: n[1] / d[0], b2: n[2] / d[0], a1: d[1] / d[0], a2: d[2] / d[0])
        }
        var out: [Biquad]
        switch weighting {
        case .z: return []
        case .a: out = [pair(highpass(f1), highpass(f1)), pair(highpass(f2), highpass(f3)), pair(lowpass(f4), lowpass(f4))]
        case .c: out = [pair(highpass(f1), highpass(f1)), pair(lowpass(f4), lowpass(f4))]
        }
        // 0 dB at 1 kHz, by definition of both curves.
        let g = 1 / out.reduce(1.0) { $0 * $1.magnitude(at: 1000, sampleRate: sampleRate) }
        out[0].b0 *= g; out[0].b1 *= g; out[0].b2 *= g
        return out
    }

    /// Designed response in dB at `frequency`.
    public static func responseDB(_ weighting: Weighting, at frequency: Double, sampleRate: Double) -> Double {
        let m = sections(weighting, sampleRate: sampleRate).reduce(1.0) { $0 * $1.magnitude(at: frequency, sampleRate: sampleRate) }
        return 20 * log10(m)
    }

    /// The standard's own curve (analog), for the tests and for the cursor readout.
    public static func standardDB(_ weighting: Weighting, at f: Double) -> Double {
        let q = f * f
        switch weighting {
        case .z: return 0
        case .c:
            let r = (f4 * f4 * q) / ((q + f1 * f1) * (q + f4 * f4))
            return 20 * log10(r) + 0.0619
        case .a:
            let r = (f4 * f4 * q * q) / ((q + f1 * f1) * sqrt((q + f2 * f2) * (q + f3 * f3)) * (q + f4 * f4))
            return 20 * log10(r) + 2.0
        }
    }
}

/// A running weighting filter. Keeps its state between blocks; Z passes samples through.
public final class WeightingFilter {
    public let weighting: Weighting
    private let setup: vDSP_biquad_Setup?
    private var delay: [Float]

    public init(_ weighting: Weighting, sampleRate: Double) {
        self.weighting = weighting
        let s = WeightingDesign.sections(weighting, sampleRate: sampleRate)
        delay = [Float](repeating: 0, count: 2 * max(s.count, 1) + 2)
        setup = s.isEmpty ? nil : vDSP_biquad_CreateSetup(s.flatMap { [$0.b0, $0.b1, $0.b2, $0.a1, $0.a2] }, vDSP_Length(s.count))
    }

    deinit { if let setup { vDSP_biquad_DestroySetup(setup) } }

    /// `output` must hold `count` samples and may be the input itself.
    public func process(_ input: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        if let setup {
            vDSP_biquad(setup, &delay, input, 1, output, 1, vDSP_Length(count))
        } else if UnsafePointer(output) != input {
            output.update(from: input, count: count)
        }
    }

    public func reset() { for i in delay.indices { delay[i] = 0 } }
}
