//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Accelerate
import Foundation

/// Fractional-octave bands per IEC 61260-1 (base 10: one octave ratio G = 10^0.3, ten 1/3 octave
/// bands per decade, 1 kHz reference).
///
/// The 31 console GEQ bands (20 Hz to 20 kHz) are the frame. 1/6, 1/12 and 1/24 split each of
/// them into 2, 4 and 8 equal parts, which is exactly the IEC rule for even fractions, so every
/// finer band sits wholly inside one coarser band and coarse levels are plain sums of fine ones.
public struct BandLayout: Equatable, Sendable {
    public static let octaveRatio = pow(10.0, 0.3)
    /// 1/3 octave band numbers relative to 1 kHz: -17 is 20 Hz, 13 is 20 kHz.
    public static let thirdOctaveRange = -17...13
    public static let fractions = [3, 6, 12, 24]
    public static let thirdOctaveNames = ["20", "25", "31.5", "40", "50", "63", "80", "100", "125", "160", "200", "250", "315",
                                          "400", "500", "630", "800", "1k", "1.25k", "1.6k", "2k", "2.5k", "3.15k", "4k", "5k",
                                          "6.3k", "8k", "10k", "12.5k", "16k", "20k"]

    public let fraction: Int
    public let centers: [Double]
    public let lower: [Double]
    public let upper: [Double]
    /// Bands per 1/3 octave band.
    public let split: Int

    public init(fraction: Int) {
        precondition(Self.fractions.contains(fraction), "fraction must be 3, 6, 12 or 24")
        self.fraction = fraction
        split = fraction / 3
        var c: [Double] = [], lo: [Double] = [], hi: [Double] = []
        let step = 1 / Double(3 * split)
        for x in Self.thirdOctaveRange {
            for j in 0..<split {
                let a = (Double(x) - 0.5) / 3 + Double(j) * step
                lo.append(1000 * pow(Self.octaveRatio, a))
                hi.append(1000 * pow(Self.octaveRatio, a + step))
                c.append(1000 * pow(Self.octaveRatio, a + step / 2))
            }
        }
        centers = c; lower = lo; upper = hi
    }

    public var count: Int { centers.count }

    /// The band `f` falls in, clamped to the ends.
    public func index(of f: Double) -> Int {
        min(max(Int((position(of: f) * Double(count)).rounded(.down)), 0), count - 1)
    }

    /// Index of the 1/3 octave (GEQ) band that holds band `i`.
    public func thirdOctave(of i: Int) -> Int { i / split }

    /// Where `f` sits across the layout: 0 at the bottom edge of the first band, 1 at the top of the last.
    public func position(of f: Double) -> Double {
        log(max(f, 1e-6) / lower[0]) / log(upper[count - 1] / lower[0])
    }

    public func frequency(at position: Double) -> Double {
        lower[0] * pow(upper[count - 1] / lower[0], position)
    }

    /// Add `fine` band powers (a finer layout on the same frame) into this layout's bands.
    public func sum(_ fine: UnsafeBufferPointer<Float>, from layout: BandLayout, into out: inout [Float]) {
        let k = layout.fraction / fraction
        precondition(k >= 1 && fine.count >= count * k && out.count >= count)
        for b in 0..<count {
            var s: Float = 0
            vDSP_sve(fine.baseAddress! + b * k, 1, &s, vDSP_Length(k))
            out[b] = s
        }
    }
}

/// What each band of a spectrum can resolve. The ring detector needs both to be honest:
/// a band cannot show a decay faster than its window, and one tone lights its near neighbours.
public struct BandResolution: Sendable {
    /// Length of the analysis window behind each band, seconds.
    public var windowSeconds: [Double]
    /// Bands each side that a single steady tone leaks into.
    public var leakBands: [Int]
}

/// Multi-time-window spectrum into 1/24 octave bands (or any `BandLayout`).
///
/// Seven FFT lengths run on the same samples, each half the one before. The window a band
/// wants halves with every octave up (long for the lows, short for the highs, so a tail at
/// 2 kHz is not smeared by the window a 40 Hz band needs), and each band reads a blend of the
/// two lengths either side of what it wants. The resolution therefore changes smoothly along
/// the frequency axis: no frequency where the picture changes character. Every window is centred on the same instant (half the longest
/// window back from the newest sample, `latencySeconds`), so a hit lands on the same slice at
/// every frequency instead of stepping in time at each window change. Output is band POWER (mean square, the dBFS RMS convention):
/// the bands of any signal add up to its broadband level and a sine reads its RMS.
public final class SpectrumAnalyzer {
    public let sampleRate: Double
    public let layout: BandLayout
    /// Samples between slices.
    public let hop: Int
    public var sliceInterval: Double { Double(hop) / sampleRate }
    public private(set) var resolution: BandResolution
    /// How far behind the newest sample a slice is centred: half the longest window.
    public let latencySeconds: Double

    private struct Tier {
        let n: Int
        /// Samples this window ends before the newest one, so its centre lines up with the longest.
        let back: Int
        let log2n: vDSP_Length
        let setup: FFTSetup
        let window: [Float]
        let scale: Float
        let frames: Int
        var bands: [Int] = []
        /// Share of each band's reading this window supplies (a band's shares add up to 1).
        var blend: [Float] = []
        var first: [Int] = []
        var count: [Int] = []
        var offset: [Int] = []
        var weights: [Float] = []
    }

    /// (window length at 48 kHz, used for bands whose centre is below this frequency)
    static let plan: [(n: Int, below: Double)] = [(32_768, 200), (8_192, 1_000), (2_048, 4_000), (512, .infinity)]
    /// Window lengths at 48 kHz, as powers of two, longest first.
    static let windowPowers = [15, 14, 13, 12, 11, 10, 9]
    /// Bands at or below this frequency read the longest window alone. Each octave above wants half the length.
    static let longestBelow = 141.0

    /// The window length a band centred on `hz` wants, as a (fractional) power of two at 48 kHz.
    static func wantedPower(_ hz: Double) -> Double {
        min(max(Double(windowPowers[0]) - log2(max(hz, 1) / longestBelow), Double(windowPowers.last!)), Double(windowPowers[0]))
    }

    private var tiers: [Tier] = []
    private var buf: [Float]
    private var w: Int
    private let keep: Int
    private var pending = 0
    private var windowed: [Float], re: [Float], im: [Float], mags: [Float], acc: [Float]
    private var out: [Float]

    public init(sampleRate: Double, layout: BandLayout = BandLayout(fraction: 24), hop: Int) {
        self.sampleRate = sampleRate
        self.layout = layout
        self.hop = hop
        // Keep the windows the same length in time at 88.2, 96, 176.4 and 192 kHz.
        let rateScale = sampleRate > 144_000 ? 4 : sampleRate > 72_000 ? 2 : 1
        let maxN = (1 << Self.windowPowers[0]) * rateScale
        keep = maxN
        latencySeconds = Double(maxN / 2) / sampleRate
        buf = [Float](repeating: 0, count: 2 * maxN + hop)
        w = maxN
        windowed = [Float](repeating: 0, count: maxN)
        re = [Float](repeating: 0, count: maxN / 2)
        im = [Float](repeating: 0, count: maxN / 2)
        mags = [Float](repeating: 0, count: maxN / 2)
        acc = [Float](repeating: 0, count: maxN / 2)
        out = [Float](repeating: 0, count: layout.count)
        resolution = BandResolution(windowSeconds: [Double](repeating: 0, count: layout.count),
                                    leakBands: [Int](repeating: 1, count: layout.count))

        var leakHz = [Double](repeating: 0, count: layout.count)
        for power in Self.windowPowers {
            let n = (1 << power) * rateScale
            let half = n / 2
            let log2n = vDSP_Length(Int(log2(Double(n)).rounded()))
            var window = [Float](repeating: 0, count: n)
            vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
            var sumSq: Float = 0
            vDSP_svesq(window, 1, &sumSq, vDSP_Length(n))
            // Enough half-overlapped frames to cover the hop, so no sample between slices is skipped.
            // The frames sit either side of the shared centre, within the samples kept.
            let frames = min(max(1, Int((Double(hop) / Double(half)).rounded(.up))), (maxN - n) / n + 1)
            let back = (maxN - n) / 2 - (frames - 1) * half / 2
            // vDSP's real FFT returns twice the DFT, so zvmags gives 4 |X|^2. One-sided power per bin
            // is 2 |X|^2 / (N * sum(w^2)): the bins of any signal then add up to its mean square.
            var tier = Tier(n: n, back: back, log2n: log2n, setup: vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!,
                            window: window, scale: 1 / (2 * Float(n) * sumSq) / Float(frames), frames: frames)
            let df = sampleRate / Double(n)
            for b in 0..<layout.count {
                let share = 1 - abs(Self.wantedPower(layout.centers[b]) - Double(power))
                guard share > 1e-6 else { continue }
                tier.blend.append(Float(share))
                // Bin k covers [k - 0.5, k + 0.5] bins. A band takes each bin by the share it overlaps.
                let lo = layout.lower[b] / df, hi = min(layout.upper[b] / df, Double(half) - 0.5)
                tier.bands.append(b)
                tier.offset.append(tier.weights.count)
                let k0 = max(1, Int((lo + 0.5).rounded(.down)))
                let k1 = min(half - 1, Int((hi + 0.5).rounded(.down)))
                tier.first.append(min(k0, half - 1))
                if hi > lo, k1 >= k0 {
                    tier.count.append(k1 - k0 + 1)
                    for k in k0...k1 {
                        tier.weights.append(Float(max(0, min(hi, Double(k) + 0.5) - max(lo, Double(k) - 0.5))))
                    }
                } else {
                    tier.count.append(0)      // band above Nyquist at this sample rate
                }
                resolution.windowSeconds[b] += share * Double(n) / sampleRate
                leakHz[b] += share * 2 * df
            }
            tiers.append(tier)
        }
        for b in 0..<layout.count {
            // A Hann main lobe is two bins each side of the tone.
            let width = max(layout.upper[b] - layout.lower[b], 1e-9)
            resolution.leakBands[b] = max(1, Int((leakHz[b] / width).rounded(.up)))
        }
    }

    deinit { for t in tiers { vDSP_destroy_fftsetup(t.setup) } }

    /// Feed samples in order. `onSlice` gets the band powers (linear mean square) once per hop.
    public func process(_ samples: UnsafePointer<Float>, count: Int, onSlice: (UnsafeBufferPointer<Float>) -> Void) {
        var i = 0
        while i < count {
            let n = min(count - i, hop - pending)
            if w + n > buf.count {
                buf.withUnsafeMutableBufferPointer { b in
                    b.baseAddress!.update(from: b.baseAddress! + (w - keep), count: keep)
                }
                w = keep
            }
            buf.withUnsafeMutableBufferPointer { b in (b.baseAddress! + w).update(from: samples + i, count: n) }
            w += n
            pending += n
            i += n
            if pending == hop {
                pending = 0
                analyze()
                out.withUnsafeBufferPointer(onSlice)
            }
        }
    }

    private func analyze() {
        vDSP_vclr(&out, 1, vDSP_Length(out.count))
        for t in tiers where !t.bands.isEmpty {
            let half = t.n / 2
            vDSP_vclr(&acc, 1, vDSP_Length(half))
            for j in 0..<t.frames {
                let start = w - t.back - t.n - j * half
                buf.withUnsafeBufferPointer { b in
                    vDSP_vmul(b.baseAddress! + start, 1, t.window, 1, &windowed, 1, vDSP_Length(t.n))
                }
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        windowed.withUnsafeBytes { raw in
                            vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                        }
                        vDSP_fft_zrip(t.setup, &split, 1, t.log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
                    }
                }
                vDSP_vadd(acc, 1, mags, 1, &acc, 1, vDSP_Length(half))
            }
            var scale = t.scale
            vDSP_vsmul(acc, 1, &scale, &acc, 1, vDSP_Length(half))
            acc.withUnsafeBufferPointer { a in
                t.weights.withUnsafeBufferPointer { wt in
                    for i in 0..<t.bands.count {
                        var p: Float = 0
                        if t.count[i] > 0 {
                            vDSP_dotpr(a.baseAddress! + t.first[i], 1, wt.baseAddress! + t.offset[i], 1, &p, vDSP_Length(t.count[i]))
                        }
                        out[t.bands[i]] += t.blend[i] * p
                    }
                }
            }
        }
    }
}

/// How the RTA bars average the slices.
public enum SpectrumAveraging: String, Codable, CaseIterable, Sendable {
    case none = "NONE", fast = "FAST", slow = "SLOW", infinite = "INF"
}

/// The RTA traces for one banding: the live averaged level, a peak-hold trace that falls back,
/// and the maximum since reset.
public final class BandAverager {
    public static let floorDB: Float = -160
    public private(set) var levelsDB: [Float]
    public private(set) var peaksDB: [Float]
    public private(set) var maxDB: [Float]
    public var averaging: SpectrumAveraging { didSet { if averaging != oldValue { frames = 0 } } }
    /// Seconds a peak holds before it falls, and how fast it falls.
    public var peakHoldSeconds = 2.0
    public var peakFallDBPerSecond = 12.0

    private var power: [Float]
    private var peakAge: [Float]
    private var frames = 0
    private let dt: Double

    public init(bands: Int, sliceInterval: Double, averaging: SpectrumAveraging = .fast) {
        dt = sliceInterval
        self.averaging = averaging
        power = [Float](repeating: 0, count: bands)
        levelsDB = [Float](repeating: Self.floorDB, count: bands)
        peaksDB = [Float](repeating: Self.floorDB, count: bands)
        maxDB = [Float](repeating: Self.floorDB, count: bands)
        peakAge = [Float](repeating: 0, count: bands)
    }

    /// Restart the run average, the peaks and the maximum.
    public func reset() {
        frames = 0
        peaksDB = levelsDB
        maxDB = levelsDB
        for i in peakAge.indices { peakAge[i] = 0 }
    }

    public func process(_ slice: UnsafeBufferPointer<Float>) {
        frames += 1
        let alpha: Float
        switch averaging {
        case .none: alpha = 1
        case .fast: alpha = Float(1 - exp(-dt / 0.125))
        case .slow: alpha = Float(1 - exp(-dt / 1.0))
        case .infinite: alpha = 1 / Float(frames)
        }
        let fdt = Float(dt), hold = Float(peakHoldSeconds), fall = Float(peakFallDBPerSecond) * fdt
        for b in 0..<min(slice.count, power.count) {
            power[b] += alpha * (slice[b] - power[b])
            let db = power[b] > 1e-16 ? 10 * log10(power[b]) : Self.floorDB
            levelsDB[b] = db
            if db > maxDB[b] { maxDB[b] = db }
            if db >= peaksDB[b] {
                peaksDB[b] = db; peakAge[b] = 0
            } else {
                peakAge[b] += fdt
                if peakAge[b] > hold { peaksDB[b] = max(db, peaksDB[b] - fall) }
            }
        }
    }
}
