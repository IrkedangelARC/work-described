//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Accelerate
import Foundation

/// A real FFT of one length, with vDSP's packing hidden.
final class RealFFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init(n: Int) {
        self.n = n
        log2n = vDSP_Length(Int(log2(Double(n)).rounded()))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// `input` (n samples) to n/2 bins. Bin 0 (DC, with Nyquist packed beside it) is cleared.
    /// The bins are twice the DFT, as vDSP returns them.
    func forward(_ input: UnsafePointer<Float>, re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: re, imagp: im)
        input.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        re[0] = 0
        im[0] = 0
    }

    /// n/2 bins of a true-scale spectrum (destroyed) to n samples.
    func inverse(re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>, output: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: re, imagp: im)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
        output.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(n / 2))
        }
        var scale = 1 / Float(n)
        vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(n))
    }
}

/// What the transfer function plot draws: one point per 1/24 octave band.
public struct TransferResult: Sendable {
    public var frequencies: [Double] = []
    /// Measurement over reference, dB.
    public var magnitudeDB: [Float] = []
    /// Degrees, -180...180.
    public var phaseDegrees: [Float] = []
    /// 0...1. How much of the measurement is explained by the reference.
    public var coherence: [Float] = []
    /// False until the window behind the point has averaged enough frames to mean anything.
    public var valid: [Bool] = []
    public init() {}
}

/// Dual channel FFT transfer function: reference (the console feed, or the generator) against
/// measurement (the mic), on the same multi-time-window plan as the RTA so the lows get long
/// windows and the highs stay quick. H1 estimator (cross spectrum over reference spectrum),
/// which leaves noise that is only in the measurement out of the answer.
///
/// The reference is delayed by `delaySamples` first (the time the sound takes to reach the mic),
/// or the measurement is, when that number is negative.
public final class TransferFunction {
    public let sampleRate: Double
    public let layout = BandLayout(fraction: 24)
    public static let maxDelaySamples = 1 << 17
    /// Frames a window must have averaged before its points count.
    public static let minimumFrames = 4

    /// Averaging time constant in seconds. 0 = everything since `reset()`.
    public var averagingSeconds = 2.0
    public var delaySamples = 0 {
        didSet {
            delaySamples = min(max(delaySamples, -Self.maxDelaySamples), Self.maxDelaySamples)
            if delaySamples != oldValue { reset() }
        }
    }

    private struct Tier {
        let fft: RealFFT
        let window: [Float]
        var pending = 0
        var frames = 0
        var sxx: [Float], syy: [Float], sxyRe: [Float], sxyIm: [Float]
        var bands: [Int] = [], first: [Int] = [], count: [Int] = [], offset: [Int] = []
        var weights: [Float] = []
    }

    private var tiers: [Tier] = []
    private var ref: [Float], mic: [Float]
    private var w: Int
    private let keep: Int
    private let chunk: Int
    private var wx: [Float], wy: [Float]
    private var xr: [Float], xi: [Float], yr: [Float], yi: [Float], tmp: [Float], cr: [Float], ci: [Float]

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let rateScale = sampleRate > 144_000 ? 4 : sampleRate > 72_000 ? 2 : 1
        let maxN = SpectrumAnalyzer.plan[0].n * rateScale
        keep = maxN + Self.maxDelaySamples
        chunk = SpectrumAnalyzer.plan.last!.n * rateScale / 2
        ref = [Float](repeating: 0, count: 2 * keep)
        mic = [Float](repeating: 0, count: 2 * keep)
        w = keep
        wx = [Float](repeating: 0, count: maxN)
        wy = [Float](repeating: 0, count: maxN)
        let half = maxN / 2
        xr = [Float](repeating: 0, count: half); xi = xr; yr = xr; yi = xr; tmp = xr; cr = xr; ci = xr

        var lowEdge = 0.0
        for (baseN, below) in SpectrumAnalyzer.plan {
            let n = baseN * rateScale, h = n / 2
            var window = [Float](repeating: 0, count: n)
            vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
            let zero = [Float](repeating: 0, count: h)
            var tier = Tier(fft: RealFFT(n: n), window: window, sxx: zero, syy: zero, sxyRe: zero, sxyIm: zero)
            let df = sampleRate / Double(n)
            for b in 0..<layout.count where layout.centers[b] >= lowEdge && layout.centers[b] < below {
                let lo = layout.lower[b] / df, hi = min(layout.upper[b] / df, Double(h) - 0.5)
                let k0 = max(1, Int((lo + 0.5).rounded(.down))), k1 = min(h - 1, Int((hi + 0.5).rounded(.down)))
                tier.bands.append(b)
                tier.offset.append(tier.weights.count)
                tier.first.append(min(k0, h - 1))
                if hi > lo, k1 >= k0 {
                    tier.count.append(k1 - k0 + 1)
                    for k in k0...k1 { tier.weights.append(Float(max(0, min(hi, Double(k) + 0.5) - max(lo, Double(k) - 0.5)))) }
                } else {
                    tier.count.append(0)
                }
            }
            tiers.append(tier)
            lowEdge = below
        }
    }

    /// Forget the averages (a new delay, a new system under test).
    public func reset() {
        for t in tiers.indices {
            tiers[t].frames = 0
            tiers[t].pending = 0
            for a in [\Tier.sxx, \Tier.syy, \Tier.sxyRe, \Tier.sxyIm] {
                tiers[t][keyPath: a].withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length($0.count)) }
            }
        }
    }

    /// Feed both inputs, the same moments in each.
    public func process(reference: UnsafePointer<Float>, measurement: UnsafePointer<Float>, count: Int) {
        var i = 0
        while i < count {
            let n = min(count - i, chunk)
            if w + n > ref.count {
                for keyPath in [\TransferFunction.ref, \TransferFunction.mic] {
                    self[keyPath: keyPath].withUnsafeMutableBufferPointer { b in
                        b.baseAddress!.update(from: b.baseAddress! + (w - keep), count: keep)
                    }
                }
                w = keep
            }
            ref.withUnsafeMutableBufferPointer { ($0.baseAddress! + w).update(from: reference + i, count: n) }
            mic.withUnsafeMutableBufferPointer { ($0.baseAddress! + w).update(from: measurement + i, count: n) }
            w += n
            i += n
            for t in tiers.indices {
                tiers[t].pending += n
                if tiers[t].pending >= tiers[t].fft.n / 2 {
                    tiers[t].pending = 0
                    frame(t)
                }
            }
        }
    }

    private func frame(_ index: Int) {
        let n = tiers[index].fft.n, h = n / 2, len = vDSP_Length(h)
        let refBack = max(delaySamples, 0), micBack = max(-delaySamples, 0)
        ref.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + (w - n - refBack), 1, tiers[index].window, 1, &wx, 1, vDSP_Length(n)) }
        mic.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + (w - n - micBack), 1, tiers[index].window, 1, &wy, 1, vDSP_Length(n)) }
        tiers[index].fft.forward(wx, re: &xr, im: &xi)
        tiers[index].fft.forward(wy, re: &yr, im: &yi)

        tiers[index].frames += 1
        let frames = tiers[index].frames
        let hopSeconds = Double(h) / sampleRate
        // A running mean until the time constant takes over, so the first frames are not lost in zeros.
        var a = Float(max(1 / Double(frames), averagingSeconds > 0 ? 1 - exp(-hopSeconds / averagingSeconds) : 0))
        var keepPart = 1 - a

        xr.withUnsafeMutableBufferPointer { xrp in
            xi.withUnsafeMutableBufferPointer { xip in
                yr.withUnsafeMutableBufferPointer { yrp in
                    yi.withUnsafeMutableBufferPointer { yip in
                        cr.withUnsafeMutableBufferPointer { crp in
                            ci.withUnsafeMutableBufferPointer { cip in
                                var x = DSPSplitComplex(realp: xrp.baseAddress!, imagp: xip.baseAddress!)
                                var y = DSPSplitComplex(realp: yrp.baseAddress!, imagp: yip.baseAddress!)
                                var c = DSPSplitComplex(realp: crp.baseAddress!, imagp: cip.baseAddress!)
                                vDSP_zvcmul(&x, 1, &y, 1, &c, 1, len)        // conj(X) * Y
                                vDSP_zvmags(&x, 1, &tmp, 1, len)
                                vDSP_vsmsma(tiers[index].sxx, 1, &keepPart, tmp, 1, &a, &tiers[index].sxx, 1, len)
                                vDSP_zvmags(&y, 1, &tmp, 1, len)
                                vDSP_vsmsma(tiers[index].syy, 1, &keepPart, tmp, 1, &a, &tiers[index].syy, 1, len)
                                vDSP_vsmsma(tiers[index].sxyRe, 1, &keepPart, crp.baseAddress!, 1, &a, &tiers[index].sxyRe, 1, len)
                                vDSP_vsmsma(tiers[index].sxyIm, 1, &keepPart, cip.baseAddress!, 1, &a, &tiers[index].sxyIm, 1, len)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The transfer function now.
    public var result: TransferResult {
        var r = TransferResult()
        let n = layout.count
        r.frequencies = layout.centers
        r.magnitudeDB = [Float](repeating: 0, count: n)
        r.phaseDegrees = [Float](repeating: 0, count: n)
        r.coherence = [Float](repeating: 0, count: n)
        r.valid = [Bool](repeating: false, count: n)
        for t in tiers {
            let ok = t.frames >= Self.minimumFrames
            for i in 0..<t.bands.count where t.count[i] > 0 {
                var xx: Float = 0, yy: Float = 0, re: Float = 0, im: Float = 0
                let len = vDSP_Length(t.count[i])
                t.weights.withUnsafeBufferPointer { wt in
                    let wp = wt.baseAddress! + t.offset[i]
                    t.sxx.withUnsafeBufferPointer { vDSP_dotpr($0.baseAddress! + t.first[i], 1, wp, 1, &xx, len) }
                    t.syy.withUnsafeBufferPointer { vDSP_dotpr($0.baseAddress! + t.first[i], 1, wp, 1, &yy, len) }
                    t.sxyRe.withUnsafeBufferPointer { vDSP_dotpr($0.baseAddress! + t.first[i], 1, wp, 1, &re, len) }
                    t.sxyIm.withUnsafeBufferPointer { vDSP_dotpr($0.baseAddress! + t.first[i], 1, wp, 1, &im, len) }
                }
                let b = t.bands[i]
                let cross = re * re + im * im
                guard ok, xx > 1e-30, yy > 1e-30 else { continue }
                r.magnitudeDB[b] = 10 * log10(max(cross, 1e-37) / (xx * xx))
                r.phaseDegrees[b] = atan2(im, re) * 180 / .pi
                r.coherence[b] = min(cross / (xx * yy), 1)
                r.valid[b] = true
            }
        }
        return r
    }
}

/// Where the reference turns up in the measurement, and how sure that is.
public struct DelayEstimate: Sendable, Equatable {
    /// Measurement behind reference, in samples (to a fraction). Negative: the reference is the late one.
    public var samples: Double
    public var milliseconds: Double
    /// The arrival's height over the rest of the impulse response, dB.
    public var peakToNoiseDB: Double
    /// The arrival points down: a polarity flip somewhere between the two inputs.
    public var inverted: Bool
    public var found: Bool

    /// Distance sound travels in that time, metres, at `celsius`.
    public func metres(celsius: Double = 20) -> Double { milliseconds / 1000 * (331.3 + 0.606 * celsius) }
}

/// Finds the delay between reference and measurement from the impulse response: the inverse FFT
/// of cross spectrum over reference spectrum, averaged over a few blocks. The same impulse
/// response is the IR view.
public final class DelayFinder {
    public let sampleRate: Double
    /// Block length. Delays up to half of it either way can be found.
    public let n: Int
    /// Blocks averaged.
    public var averages = 4
    /// An arrival has to stand this far above the rest to be believed. The tallest sample of
    /// an impulse response that is nothing but noise already stands 13 to 15 dB over its RMS.
    public var minimumPeakToNoiseDB = 20.0
    /// The impulse response. Index i is lag i for i < n/2, lag i - n above.
    public private(set) var impulse: [Float]
    public private(set) var estimate: DelayEstimate?
    public private(set) var blocks = 0

    private let fft: RealFFT
    private let window: [Float]
    private var ref: [Float], mic: [Float]
    private var filled: Int
    private var wx: [Float], wy: [Float]
    private var xr: [Float], xi: [Float], yr: [Float], yi: [Float]
    private var sxx: [Float], sre: [Float], sim: [Float], hr: [Float], hi: [Float]

    public init(sampleRate: Double, log2n: Int = 16) {
        self.sampleRate = sampleRate
        n = 1 << log2n
        fft = RealFFT(n: n)
        var win = [Float](repeating: 0, count: n)
        vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        window = win
        ref = [Float](repeating: 0, count: n)
        mic = ref; wx = ref; wy = ref; impulse = ref
        filled = n / 2
        let half = [Float](repeating: 0, count: n / 2)
        xr = half; xi = half; yr = half; yi = half; sxx = half; sre = half; sim = half; hr = half; hi = half
    }

    public func reset() {
        blocks = 0
        estimate = nil
        filled = n / 2
        for i in 0..<n { ref[i] = 0; mic[i] = 0; impulse[i] = 0 }
    }

    /// Feed both inputs. Returns a fresh estimate each time a block completes (about every
    /// 0.7 s at 48 kHz), nil otherwise.
    public func process(reference: UnsafePointer<Float>, measurement: UnsafePointer<Float>, count: Int) -> DelayEstimate? {
        var out: DelayEstimate?
        var i = 0
        while i < count {
            let m = min(count - i, n - filled)
            ref.withUnsafeMutableBufferPointer { ($0.baseAddress! + filled).update(from: reference + i, count: m) }
            mic.withUnsafeMutableBufferPointer { ($0.baseAddress! + filled).update(from: measurement + i, count: m) }
            filled += m
            i += m
            if filled == n {
                out = block()
                // Half overlap: the newer half becomes the older half.
                ref.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: $0.baseAddress! + n / 2, count: n / 2) }
                mic.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: $0.baseAddress! + n / 2, count: n / 2) }
                filled = n / 2
            }
        }
        return out
    }

    private func block() -> DelayEstimate {
        let h = n / 2, len = vDSP_Length(h)
        vDSP_vmul(ref, 1, window, 1, &wx, 1, vDSP_Length(n))
        vDSP_vmul(mic, 1, window, 1, &wy, 1, vDSP_Length(n))
        fft.forward(wx, re: &xr, im: &xi)
        fft.forward(wy, re: &yr, im: &yi)
        blocks += 1
        var a = Float(max(1 / Double(blocks), 1 / Double(max(averages, 1)))), keepPart = 1 - a
        xr.withUnsafeMutableBufferPointer { xrp in
            xi.withUnsafeMutableBufferPointer { xip in
                yr.withUnsafeMutableBufferPointer { yrp in
                    yi.withUnsafeMutableBufferPointer { yip in
                        var x = DSPSplitComplex(realp: xrp.baseAddress!, imagp: xip.baseAddress!)
                        var y = DSPSplitComplex(realp: yrp.baseAddress!, imagp: yip.baseAddress!)
                        hr.withUnsafeMutableBufferPointer { crp in
                            hi.withUnsafeMutableBufferPointer { cip in
                                var c = DSPSplitComplex(realp: crp.baseAddress!, imagp: cip.baseAddress!)
                                vDSP_zvcmul(&x, 1, &y, 1, &c, 1, len)
                                vDSP_vsmsma(sre, 1, &keepPart, crp.baseAddress!, 1, &a, &sre, 1, len)
                                vDSP_vsmsma(sim, 1, &keepPart, cip.baseAddress!, 1, &a, &sim, 1, len)
                                vDSP_zvmags(&x, 1, crp.baseAddress!, 1, len)
                                vDSP_vsmsma(sxx, 1, &keepPart, crp.baseAddress!, 1, &a, &sxx, 1, len)
                            }
                        }
                    }
                }
            }
        }
        // H = Sxy / (Sxx + e). The small e keeps bins where the reference is silent from blowing up.
        var mean: Float = 0
        vDSP_meanv(sxx, 1, &mean, len)
        var e = max(mean * 1e-3, 1e-30)
        vDSP_vsadd(sxx, 1, &e, &xr, 1, len)
        vDSP_vdiv(xr, 1, sre, 1, &hr, 1, len)
        vDSP_vdiv(xr, 1, sim, 1, &hi, 1, len)
        hr[0] = 0; hi[0] = 0
        fft.inverse(re: &hr, im: &hi, output: &impulse)

        var peak: Float = 0
        var at: vDSP_Length = 0
        vDSP_maxmgvi(impulse, 1, &peak, &at, vDSP_Length(n))
        let p = Int(at)
        // Everything but the arrival and its near skirt is the floor.
        var sumSq = 0.0, counted = 0
        for i in 0..<n where min((i - p + n) % n, (p - i + n) % n) > 64 {
            sumSq += Double(impulse[i]) * Double(impulse[i]); counted += 1
        }
        let floor = sqrt(sumSq / Double(max(counted, 1)))
        let ratio = 20 * log10(max(Double(peak), 1e-20) / max(floor, 1e-20))
        // Parabola through the peak and its neighbours for the fraction of a sample.
        let l = Double(abs(impulse[(p - 1 + n) % n])), c = Double(peak), r = Double(abs(impulse[(p + 1) % n]))
        let denom = l - 2 * c + r
        let frac = abs(denom) > 1e-12 ? min(max(0.5 * (l - r) / denom, -0.5), 0.5) : 0
        let lag = Double(p < n / 2 ? p : p - n) + frac
        let est = DelayEstimate(samples: lag, milliseconds: lag / sampleRate * 1000, peakToNoiseDB: ratio,
                                inverted: impulse[p] < 0, found: ratio >= minimumPeakToNoiseDB && peak > 0)
        estimate = est
        return est
    }
}
