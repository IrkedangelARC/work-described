//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Accelerate
import Foundation

/// 1/3 octave band filters to IEC 61260-1 / ANSI S1.11 class 1: order 3 Butterworth band-pass
/// (three biquads, six poles) per band.
public enum OctaveFilterDesign {
    /// Sections for the band centred on `center`. Unity gain at the centre frequency.
    ///
    /// The -3 dB bandwidth is narrowed by (pi / 2n) / sin(pi / 2n) (the S1.11 design Q), which
    /// makes the filter pass the same noise power as an ideal band of the nominal width: white
    /// and pink noise then read the same here as on the FFT bands, and the bands add up to the
    /// broadband level. Edges are prewarped, so they land where asked at any sample rate.
    public static func sections(center fm: Double, sampleRate fs: Double, order n: Int = 3) -> [Biquad] {
        let g = BandLayout.octaveRatio
        let q = 1 / (pow(g, 1.0 / 6) - pow(g, -1.0 / 6))
        let qd = q * (Double.pi / Double(2 * n)) / sin(Double.pi / Double(2 * n))
        let f1 = fm * (sqrt(1 + 1 / (4 * qd * qd)) - 1 / (2 * qd))
        let f2 = min(f1 + fm / qd, 0.499 * fs)
        let w1 = tan(Double.pi * f1 / fs), w2 = tan(Double.pi * f2 / fs)
        let bw = w2 - w1, w0sq = w1 * w2

        var out: [Biquad] = []
        for k in 0..<n {
            // Low-pass prototype pole on the unit circle, left half plane, upper half only:
            // the lower half is the conjugate and comes with each biquad.
            let theta = Double.pi * Double(2 * k + n + 1) / Double(2 * n)
            let pr = cos(theta), pi = sin(theta)
            guard pi > -1e-9 else { continue }
            // Band-pass transform: s^2 - p * bw * s + w0^2 = 0.
            let br = pr * bw, bi = pi * bw
            let (dr, di) = csqrt(br * br - bi * bi - 4 * w0sq, 2 * br * bi)
            let roots = abs(pi) < 1e-9 ? [((br + dr) / 2, (bi + di) / 2)]
                                       : [((br + dr) / 2, (bi + di) / 2), ((br - dr) / 2, (bi - di) / 2)]
            for (sr, si) in roots {
                // Bilinear: z = (1 + s) / (1 - s). Zeros at z = 1 and z = -1.
                let den = (1 - sr) * (1 - sr) + si * si
                let zr = ((1 + sr) * (1 - sr) - si * si) / den
                let zi = (si * (1 - sr) + si * (1 + sr)) / den
                out.append(Biquad(b0: 1, b1: 0, b2: -1, a1: -2 * zr, a2: zr * zr + zi * zi))
            }
        }
        for i in out.indices {
            let m = out[i].magnitude(at: fm, sampleRate: fs)
            out[i].b0 /= m; out[i].b2 /= m
        }
        return out
    }

    /// Gain in dB of the band filter centred on `center`, at `frequency`.
    public static func responseDB(center: Double, at frequency: Double, sampleRate: Double) -> Double {
        20 * log10(max(sections(center: center, sampleRate: sampleRate)
            .reduce(1.0) { $0 * $1.magnitude(at: frequency, sampleRate: sampleRate) }, 1e-20))
    }

    private static func csqrt(_ re: Double, _ im: Double) -> (Double, Double) {
        let r = sqrt(re * re + im * im)
        let a = sqrt(max(0, (r + re) / 2)), b = sqrt(max(0, (r - re) / 2))
        return (a, im < 0 ? -b : b)
    }
}

/// The 31 band 1/3 octave real time analyser: the console GEQ's bands, with a real filter's
/// time behaviour (no FFT window). Double precision, because a 20 Hz band at 48 kHz has poles
/// too close to the unit circle for single.
///
/// A band whose centre is above about a quarter of the sample rate cannot meet class 1 as a
/// bilinear design: the squeeze toward Nyquist flattens its lower skirt (12.5k, 16k and 20k
/// at 48 kHz). Those bands run on a 2x oversampled copy of the input instead, where they pass.
public final class OctaveFilterBank {
    public let layout = BandLayout(fraction: 3)
    public let sampleRate: Double
    /// Samples between slices.
    public let hop: Int
    public var sliceInterval: Double { Double(hop) / sampleRate }
    /// Bands that run at twice the sample rate.
    public private(set) var oversampled: [Bool]

    static let taps = 151
    private var setups: [vDSP_biquad_SetupD?] = []
    private var delays: [[Double]]
    private var acc: [Double]
    private var input: [Double], filtered: [Double]
    private var fir: [Double], stuffed: [Double], doubled: [Double]
    private var pending = 0
    private var out: [Float]

    /// True when the band centred on `center` needs the 2x path at `sampleRate`.
    public static func needsOversampling(center: Double, sampleRate: Double) -> Bool { center > sampleRate / 4.2 }

    /// Half-band interpolation filter: Kaiser-windowed sinc, 80 dB down from 0.267 of the doubled
    /// rate (the image of the top band's upper edge at 48 kHz). Unity pass gain on a zero-stuffed input.
    static func halfBand() -> [Double] {
        func i0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            for k in 1..<40 { term *= (x / (2 * Double(k))) * (x / (2 * Double(k))); sum += term }
            return sum
        }
        let m = Double(taps - 1) / 2, beta = 7.857
        return (0..<taps).map { i in
            let x = (Double(i) - m) / 2
            let sinc = abs(x) < 1e-12 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
            let r = (Double(i) - m) / m
            return sinc * i0(beta * sqrt(max(0, 1 - r * r))) / i0(beta)
        }
    }

    public init(sampleRate: Double, hop: Int) {
        self.sampleRate = sampleRate
        self.hop = hop
        let n = layout.count
        delays = []
        oversampled = [Bool](repeating: false, count: n)
        acc = [Double](repeating: 0, count: n)
        input = [Double](repeating: 0, count: hop)
        filtered = [Double](repeating: 0, count: 2 * hop)
        fir = Self.halfBand()
        stuffed = [Double](repeating: 0, count: Self.taps - 1 + 2 * hop)
        doubled = [Double](repeating: 0, count: 2 * hop)
        out = [Float](repeating: 0, count: n)
        for b in 0..<n {
            oversampled[b] = Self.needsOversampling(center: layout.centers[b], sampleRate: sampleRate)
            let rate = oversampled[b] ? 2 * sampleRate : sampleRate
            // A band whose top edge is past Nyquist cannot exist at this rate: it reads empty.
            guard layout.upper[b] < 0.49 * rate else { setups.append(nil); delays.append([]); continue }
            let s = OctaveFilterDesign.sections(center: layout.centers[b], sampleRate: rate)
            let coeffs = s.flatMap { [$0.b0, $0.b1, $0.b2, $0.a1, $0.a2] }
            setups.append(vDSP_biquad_CreateSetupD(coeffs, vDSP_Length(s.count)))
            delays.append([Double](repeating: 0, count: 2 * s.count + 2))
        }
    }

    deinit { for s in setups { if let s { vDSP_biquad_DestroySetupD(s) } } }

    /// Feed samples in order. `onSlice` gets the 31 band powers (mean square over the hop) once per hop.
    public func process(_ samples: UnsafePointer<Float>, count: Int, onSlice: (UnsafeBufferPointer<Float>) -> Void) {
        let history = Self.taps - 1
        var i = 0
        while i < count {
            let n = min(count - i, hop - pending)
            vDSP_vspdp(samples + i, 1, &input, 1, vDSP_Length(n))
            // 2x copy: a zero between every sample, then the half-band filter fills the zeros in.
            for j in 0..<n { stuffed[history + 2 * j] = input[j]; stuffed[history + 2 * j + 1] = 0 }
            vDSP_convD(stuffed, 1, fir, 1, &doubled, 1, vDSP_Length(2 * n), vDSP_Length(Self.taps))
            stuffed.withUnsafeMutableBufferPointer { p in
                p.baseAddress!.update(from: p.baseAddress! + 2 * n, count: history)
            }
            for b in 0..<setups.count {
                guard let setup = setups[b] else { continue }
                var s = 0.0
                if oversampled[b] {
                    vDSP_biquadD(setup, &delays[b], doubled, 1, &filtered, 1, vDSP_Length(2 * n))
                    vDSP_svesqD(filtered, 1, &s, vDSP_Length(2 * n))
                    s /= 2
                } else {
                    vDSP_biquadD(setup, &delays[b], input, 1, &filtered, 1, vDSP_Length(n))
                    vDSP_svesqD(filtered, 1, &s, vDSP_Length(n))
                }
                acc[b] += s
            }
            pending += n
            i += n
            if pending == hop {
                pending = 0
                for b in 0..<out.count { out[b] = Float(acc[b] / Double(hop)); acc[b] = 0 }
                out.withUnsafeBufferPointer(onSlice)
            }
        }
    }
}
