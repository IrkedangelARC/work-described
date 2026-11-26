//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Accelerate
import Foundation

/// A captured RTA trace: the averaged bars at the moment CAPTURE was pressed. Held unweighted
/// in dBFS like the live data, so weighting, calibration and mic correction apply to it at
/// draw time exactly as they do to the live bars.
public struct Trace: Codable, Equatable, Sendable, Identifiable {
    public static let limit = 8
    public var id = UUID()
    public var name: String
    public var date: Date
    /// 0...7: which of the eight trace colours.
    public var slot: Int
    public var visible = true
    /// The 1/3 octave filter bank levels (31) and the 1/24 FFT band levels (248).
    public var thirds: [Float]
    public var fine: [Float]

    public init(name: String, date: Date = Date(), slot: Int, thirds: [Float], fine: [Float]) {
        self.name = name; self.date = date; self.slot = slot; self.thirds = thirds; self.fine = fine
    }

    /// The trace at `fraction` bands per octave. 1/6 and 1/12 are the power sums of the 1/24 bands.
    public func levels(fraction: Int) -> [Float] {
        switch fraction {
        case 3: return thirds
        case 24: return fine
        default:
            let layout = BandLayout(fraction: fraction), from = BandLayout(fraction: 24)
            guard fine.count == from.count, BandLayout.fractions.contains(fraction) else { return [] }
            let group = from.count / layout.count
            return (0..<layout.count).map { b in
                var p = 0.0
                for i in 0..<group { p += pow(10, Double(fine[b * group + i]) / 10) }
                return p > 1e-20 ? Float(10 * log10(p)) : -200
            }
        }
    }
}

/// A measurement microphone's response curve, from its calibration file (.frd, .txt, .csv:
/// lines of "Hz dB", extra columns ignored). The correction is the curve turned upside down.
///
/// The curve is taken relative to its own value at 1 kHz: the level calibration (94 or 114 dB
/// at 1 kHz) already holds the mic's sensitivity, so the file must not move it a second time.
public struct MicCorrection: Codable, Equatable, Sendable {
    public enum ParseError: Error, Equatable { case noData }
    public var name: String
    public var frequencies: [Double]
    public var responseDB: [Double]
    /// Corrections are held to this many dB either way: beyond it the file is describing a
    /// microphone that cannot hear there, and boosting its noise is not a measurement.
    public static let limitDB = 20.0

    public init(name: String, frequencies: [Double], responseDB: [Double]) {
        self.name = name; self.frequencies = frequencies; self.responseDB = responseDB
    }

    public static func parse(_ text: String, name: String) throws -> MicCorrection {
        var points: [(Double, Double)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { " \t,;".contains($0) })
            guard fields.count >= 2, let f = Double(fields[0]), let db = Double(fields[1]), f > 0, db.isFinite else { continue }
            points.append((f, db))
        }
        points.sort { $0.0 < $1.0 }
        guard points.count >= 2 else { throw ParseError.noData }
        return MicCorrection(name: name, frequencies: points.map(\.0), responseDB: points.map(\.1))
    }

    private func raw(at f: Double) -> Double {
        guard let first = frequencies.first, let last = frequencies.last else { return 0 }
        if f <= first { return responseDB[0] }
        if f >= last { return responseDB[responseDB.count - 1] }
        var lo = 0, hi = frequencies.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if frequencies[mid] <= f { lo = mid } else { hi = mid }
        }
        let t = log(f / frequencies[lo]) / log(frequencies[hi] / frequencies[lo])
        return responseDB[lo] + (responseDB[hi] - responseDB[lo]) * t
    }

    /// The mic's response at `f` relative to 1 kHz. Flat beyond the ends of the file.
    public func response(at f: Double) -> Double { raw(at: f) - raw(at: 1000) }

    /// dB to add to a reading at `f`.
    public func correctionDB(at f: Double) -> Double { min(max(-response(at: f), -Self.limitDB), Self.limitDB) }

    /// The correction as a linear phase FIR, for the level meter: its Fast, Slow, Leq and peak
    /// detectors work on samples, so the curve has to reach them as a filter. Odd `taps`.
    public func fir(taps: Int = 4097, sampleRate: Double) -> [Float] {
        let n = taps | 1, m = 2 * (n - 1), half = (n - 1) / 2
        let gain = (0...m / 2).map { k in pow(10, correctionDB(at: max(Double(k) * sampleRate / Double(m), 1)) / 20) }
        let table = (0..<m).map { cos(2 * Double.pi * Double($0) / Double(m)) }
        return (0..<n).map { i in
            let d = abs(i - half)
            var sum = gain[0] + gain[m / 2] * (d % 2 == 0 ? 1 : -1)
            for k in 1..<(m / 2) { sum += 2 * gain[k] * table[(k * d) % m] }
            let window = 0.5 + 0.5 * cos(Double.pi * Double(i - half) / Double(half + 1))
            return Float(sum / Double(m) * window)
        }
    }
}

/// Runs a FIR over a stream, block by block.
public final class FIRFilter {
    private let taps: [Float]
    private var buffer: [Float]
    public var delaySamples: Int { (taps.count - 1) / 2 }

    public init(taps: [Float], maxBlock: Int = 16_384) {
        self.taps = taps
        buffer = [Float](repeating: 0, count: taps.count - 1 + maxBlock)
    }

    public func process(_ input: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>, count: Int) {
        let history = taps.count - 1
        var done = 0
        while done < count {
            let n = min(count - done, buffer.count - history)
            buffer.withUnsafeMutableBufferPointer { b in
                (b.baseAddress! + history).update(from: input + done, count: n)
                vDSP_conv(b.baseAddress!, 1, taps, 1, output + done, 1, vDSP_Length(n), vDSP_Length(taps.count))
                b.baseAddress!.update(from: b.baseAddress! + n, count: history)
            }
            done += n
        }
    }
}
