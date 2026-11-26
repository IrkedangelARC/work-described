//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Accelerate
import Foundation

/// Time weighting of the running level (IEC 61672): Fast 125 ms, Slow 1 s.
public enum TimeResponse: String, Codable, CaseIterable, Sendable {
    case fast = "FAST", slow = "SLOW"
    public var timeConstant: Double { self == .fast ? 0.125 : 1.0 }
}

/// Levels in dBFS RMS: a full-scale sine reads -3.01. Add `Calibration.offsetDB` for dB SPL.
/// `-.infinity` means digital silence.
public struct LevelReading: Equatable, Sendable {
    public var fast = -Double.infinity      // frequency weighted, Fast
    public var slow = -Double.infinity      // frequency weighted, Slow
    public var leq = -Double.infinity       // frequency weighted, equivalent level since reset
    public var maxFast = -Double.infinity   // highest Fast level since reset (Lmax)
    public var peakC = -Double.infinity     // highest C weighted sample since reset (LCpeak), dBFS peak
    public var seconds = 0.0                // time measured since reset

    public init() {}
    public func level(_ response: TimeResponse) -> Double { response == .fast ? fast : slow }
}

/// Sound level meter over one channel. Feed it blocks in order; read `reading` any time
/// from the same thread.
public final class SPLMeter {
    public let sampleRate: Double
    public private(set) var weighting: Weighting
    public private(set) var reading = LevelReading()

    private var filter: WeightingFilter
    private let cFilter: WeightingFilter
    private let alphaFast: Float, alphaSlow: Float
    private var msFast: Float = 0, msSlow: Float = 0, maxMsFast: Float = 0
    private var sumSquares = 0.0, sampleCount = 0
    private var peakC: Float = 0
    private var scratch: [Float]

    public init(sampleRate: Double, weighting: Weighting = .a, maxBlock: Int = 16_384) {
        self.sampleRate = sampleRate
        self.weighting = weighting
        filter = WeightingFilter(weighting, sampleRate: sampleRate)
        cFilter = WeightingFilter(.c, sampleRate: sampleRate)
        alphaFast = Float(1 - exp(-1 / (sampleRate * TimeResponse.fast.timeConstant)))
        alphaSlow = Float(1 - exp(-1 / (sampleRate * TimeResponse.slow.timeConstant)))
        scratch = [Float](repeating: 0, count: maxBlock)
    }

    /// Changing the weighting restarts Leq, Lmax and the running levels.
    public func setWeighting(_ w: Weighting) {
        guard w != weighting else { return }
        weighting = w
        filter = WeightingFilter(w, sampleRate: sampleRate)
        reset()
    }

    /// Restart Leq, Lmax, LCpeak and the measured time. The Fast and Slow levels keep running.
    public func reset() {
        sumSquares = 0; sampleCount = 0; maxMsFast = msFast; peakC = 0
        publish()
    }

    public func process(_ samples: UnsafePointer<Float>, count: Int) {
        var offset = 0
        while offset < count {
            let n = min(count - offset, scratch.count)
            scratch.withUnsafeMutableBufferPointer { s in
                let p = s.baseAddress!
                // LCpeak first: it always uses C, whatever the display weighting is.
                cFilter.process(samples + offset, into: p, count: n)
                var pk: Float = 0
                vDSP_maxmgv(p, 1, &pk, vDSP_Length(n))
                peakC = max(peakC, pk)

                filter.process(samples + offset, into: p, count: n)
                var sum: Float = 0
                vDSP_svesq(p, 1, &sum, vDSP_Length(n))
                sumSquares += Double(sum)
                sampleCount += n

                var f = msFast, sl = msSlow, mx = maxMsFast
                let af = alphaFast, asl = alphaSlow
                for i in 0..<n {
                    let sq = p[i] * p[i]
                    f += af * (sq - f)
                    sl += asl * (sq - sl)
                    if f > mx { mx = f }
                }
                msFast = f; msSlow = sl; maxMsFast = mx
            }
            offset += n
        }
        publish()
    }

    private func publish() {
        func db(_ meanSquare: Double) -> Double { meanSquare > 0 ? 10 * log10(meanSquare) : -.infinity }
        reading.fast = db(Double(msFast))
        reading.slow = db(Double(msSlow))
        reading.maxFast = db(Double(maxMsFast))
        reading.leq = sampleCount > 0 ? db(sumSquares / Double(sampleCount)) : -.infinity
        reading.peakC = peakC > 0 ? 20 * log10(Double(peakC)) : -.infinity
        reading.seconds = Double(sampleCount) / sampleRate
    }
}
