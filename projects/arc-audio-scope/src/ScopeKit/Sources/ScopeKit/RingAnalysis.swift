//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Accelerate
import Foundation

/// The tech hears something and hits the key. This goes back over the last few seconds of the
/// sound itself (not the bars) with long windows, finds the narrow lines in it to within about
/// a hertz, follows each one through the period and says what it was doing: growing, holding,
/// dying away, or a note with harmonics.
public enum RingAnalysis {
    public enum Kind: String, Codable, Sendable {
        /// Getting louder: feedback building.
        case growing
        /// Neither rising nor falling: feedback sitting at its limit, or a steady tone.
        case held
        /// Falling: a ring after a hit.
        case dying
        /// Has harmonics, or is one: a played or sung note.
        case note
    }

    public struct Candidate: Equatable, Sendable {
        public var frequency: Double
        /// Level of the line itself while it was there, dBFS RMS.
        public var levelDB: Double
        /// How far it stood above the sound around it, dB.
        public var prominenceDB: Double
        public var slopeDBPerSecond: Double
        /// Share of the period it was there, 0...1, how long that was, and how long before the key it began.
        public var presentFraction: Double
        public var heardSeconds: Double
        public var startedSecondsAgo: Double
        public var kind: Kind
        /// Never within `faintDB` of the rest of the sound at any moment: on the analyser, but
        /// almost certainly not what was heard.
        public var faint = false
    }

    public struct Report: Equatable, Sendable {
        /// Most likely first. Notes come after everything that is not a note.
        public var candidates: [Candidate]
        /// Seconds of sound that were analysed.
        public var seconds: Double
    }

    /// A line must stand this far above its surroundings to be a candidate, and this far to count as a harmonic.
    static let candidateDB: Float = 10, harmonicDB: Float = 6
    /// Lines more than this far below the loudest (A weighted) were not what was heard.
    static let audibleWithin: Float = 35
    static let growing = 1.5, dying = -4.0
    /// A line this far under the whole (A weighted) sound at its best moment is called faint.
    static let faintDB = 25.0
    /// A rise this big from one frame to the next (over 100 dB a second) is a new strike, not growth.
    static let strikeDB = 5.0

    /// What to do about a line. The depth is a starting cut, not a measurement: a ring that is
    /// growing or just holding is only a fraction of a dB over the edge, so 3 dB clears it with
    /// room to spare, and the next mark shows whether it is gone.
    public struct Advice: Equatable, Sendable {
        /// False for a note: nothing to cut.
        public var cut: Bool
        public var peqHz: Double
        public var depthDB: Double
        /// The 1/3 octave GEQ fader it falls under, and whether it sits out toward the edge of
        /// that fader's band, where the GEQ takes more of the sound around it than a PEQ would.
        public var thirdOctave: Int
        public var betweenFaders: Bool
    }

    private static let thirdOctaves = BandLayout(fraction: 3)

    public static func advice(_ c: Candidate) -> Advice {
        let thirds = thirdOctaves
        let band = thirds.index(of: c.frequency)
        let off = abs(log2(c.frequency / thirds.centers[band]))
        return Advice(cut: c.kind != .note && !c.faint, peqHz: c.frequency, depthDB: 3, thirdOctave: band, betweenFaders: off > 1.0 / 12)
    }

    /// Frequencies within this many octaves of `focus` count as the spot that was pointed at.
    static let focusOctaves = 1.0 / 6

    /// `focus`: the frequency the tech pointed at, if any. A line there is put first, and is
    /// admitted even when something louder elsewhere would otherwise have drowned it out.
    public static func analyze(_ x: [Float], sampleRate: Double, limit: Int = 3, focus: Double? = nil) -> Report {
        let n = sampleRate > 60_000 ? 32_768 : 16_384, hop = n / 8
        guard x.count >= n + hop * 4 else { return Report(candidates: [], seconds: Double(x.count) / sampleRate) }
        let frames = (x.count - n) / hop + 1, half = n / 2, df = sampleRate / Double(n)
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        var sumSquares: Float = 0
        vDSP_svesq(window, 1, &sumSquares, vDSP_Length(n))
        // vDSP hands back twice the DFT. With this scale, the bins across a line add up to its mean square.
        let scale = 1 / (2 * Float(n) * sumSquares)

        let fft = RealFFT(n: n)
        var power = [Float](repeating: 0, count: frames * half)
        var buffer = [Float](repeating: 0, count: n), re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        // The whole sound in each frame as the ear weighs it, to judge whether a line could be heard in it.
        let aGain = (0..<half).map { k in k == 0 ? Float(0) : Float(pow(10, WeightingDesign.standardDB(.a, at: Double(k) * df) / 10)) }
        var wholeDB = [Double](repeating: -200, count: frames)
        x.withUnsafeBufferPointer { src in
            for t in 0..<frames {
                vDSP_vmul(src.baseAddress! + t * hop, 1, window, 1, &buffer, 1, vDSP_Length(n))
                fft.forward(buffer, re: &re, im: &im)
                var whole: Float = 0
                for k in 0..<half {
                    let p = (re[k] * re[k] + im[k] * im[k]) * scale
                    power[t * half + k] = p
                    whole += p * aGain[k]
                }
                wholeDB[t] = 10 * log10(Double(whole) + 1e-20)
            }
        }

        let lo = max(3, Int((20 / df).rounded(.up))), hi = min(half - 4, Int(min(20_000, sampleRate * 0.45) / df))
        guard hi > lo + 64 else { return Report(candidates: [], seconds: Double(x.count) / sampleRate) }
        // The mean in dB over the period: a line that stays outweighs a hit that passes.
        var mean = [Float](repeating: -200, count: half)
        for k in lo...hi {
            var s: Float = 0
            for t in 0..<frames { s += 10 * log10(power[t * half + k] + 1e-20) }
            mean[k] = s / Float(frames)
        }
        // What surrounds each bin: the median a quarter octave each side, the bin's own lobe left out.
        let ratio = pow(2.0, 0.25)
        func surround(_ k: Int) -> Float? {
            let a = max(lo, Int(Double(k) / ratio)), b = min(hi, Int(Double(k) * ratio))
            let stride = max(1, (b - a) / 48)
            var values: [Float] = []
            var j = a
            while j <= b {
                if abs(j - k) > 4 { values.append(mean[j]) }
                j += stride
            }
            guard values.count >= 6 else { return nil }
            values.sort()
            return values[values.count / 2]
        }

        struct Peak { var bin: Int; var base: Float; var prominence: Float; var heard: Float }
        var peaks: [Peak] = []
        for k in (lo + 1)..<hi where mean[k] > mean[k - 1] && mean[k] >= mean[k + 1] {
            guard let base = surround(k), mean[k] - base >= harmonicDB else { continue }
            // Not a side lobe of a bigger line next door.
            guard mean[k] >= mean[(k - 3)...(k + 3)].max()! else { continue }
            let a = Float(WeightingDesign.standardDB(.a, at: Double(k) * df))
            peaks.append(Peak(bin: k, base: base, prominence: mean[k] - base, heard: mean[k] + a))
        }
        func pointedAt(_ f: Double) -> Bool { focus.map { abs(log2(f / $0)) <= focusOctaves } ?? false }
        let loudest = peaks.filter({ $0.prominence >= candidateDB }).map(\.heard).max() ?? -.infinity

        func exact(_ k: Int) -> Double {
            let a = Double(mean[k - 1]), b = Double(mean[k]), c = Double(mean[k + 1])
            let d = a - 2 * b + c
            return (Double(k) + (abs(d) > 1e-9 ? 0.5 * (a - c) / d : 0)) * df
        }
        func peak(near f: Double) -> Peak? {
            peaks.filter { abs(Double($0.bin) * df - f) <= max(f * 0.012, 2 * df) }.max { $0.prominence < $1.prominence }
        }

        let frameSeconds = Double(hop) / sampleRate
        var found: [(score: Float, candidate: Candidate)] = []
        for p in peaks {
            let f = exact(p.bin)
            guard pointedAt(f) || (p.prominence >= candidateDB && p.heard >= loudest - audibleWithin) else { continue }
            // The line's own level in each frame, across its lobe.
            var level = [Double](repeating: -200, count: frames)
            var present: [Int] = []
            for t in 0..<frames {
                var s: Float = 0
                for k in (p.bin - 2)...(p.bin + 2) { s += power[t * half + k] }
                level[t] = 10 * log10(Double(s) + 1e-20)
                if 10 * log10(power[t * half + p.bin] + 1e-20) > p.base + harmonicDB { present.append(t) }
            }
            guard present.count >= 3 else { continue }
            // Straight line through the frames it was there.
            // A window that straddles the line's start or end reads low, which would steepen the
            // line: leave those frames out when enough are left.
            let straddle = n / hop - 1
            var fit = present
            if present[0] > 0 { fit = fit.filter { $0 >= present[0] + straddle } }
            if present[present.count - 1] < frames - 1 { fit = fit.filter { $0 <= present[present.count - 1] - straddle } }
            if fit.count < 4 { fit = present }
            // Struck again part way through (a jump no feedback grows at): what it did since the
            // last strike is the answer, or before it when the strike came right at the end.
            var end = frames
            while true {
                guard let last = fit.last(where: { $0 < end && $0 > 0 && level[$0] - level[$0 - 1] > strikeDB }) else { break }
                var first = last
                while let earlier = fit.last(where: { $0 < first && $0 >= first - straddle && $0 > 0 && level[$0] - level[$0 - 1] > strikeDB }) { first = earlier }
                let after = fit.filter { $0 >= first + straddle && $0 < end }
                if after.count >= 4 { fit = after; break }
                let before = fit.filter { $0 < first }
                if before.count < 4 { break }
                fit = before
                end = first
            }
            let ts = fit.map { Double($0) * frameSeconds }, ls = fit.map { level[$0] }
            let mt = ts.reduce(0, +) / Double(ts.count), ml = ls.reduce(0, +) / Double(ls.count)
            var num = 0.0, den = 0.0
            for i in 0..<ts.count { num += (ts[i] - mt) * (ls[i] - ml); den += (ts[i] - mt) * (ts[i] - mt) }
            let slope = den > 0 ? num / den : 0
            let meanSquare = present.map { pow(10, level[$0] / 10) }.reduce(0, +) / Double(present.count)

            let second = peak(near: 2 * f), third = peak(near: 3 * f)
            let below = [f / 2, f / 3].compactMap { peak(near: $0) }.contains { mean[$0.bin] > mean[p.bin] }
            let note = (second != nil && third != nil) || below
            let kind: Kind = note ? .note : slope > growing ? .growing : slope < dying ? .dying : .held
            let aDB = WeightingDesign.standardDB(.a, at: f)
            let faint = !present.contains { level[$0] + aDB >= wholeDB[$0] - faintDB }
            var candidate = Candidate(frequency: f, levelDB: 10 * log10(meanSquare), prominenceDB: Double(p.prominence), slopeDBPerSecond: slope,
                                      presentFraction: Double(present.count) / Double(frames), heardSeconds: Double(present.count) * frameSeconds,
                                      startedSecondsAgo: Double(frames - 1 - present[0]) * frameSeconds + Double(n) / (2 * sampleRate), kind: kind)
            candidate.faint = faint
            found.append((p.prominence + (loudest.isFinite ? p.heard - loudest : 0) - (note ? 1000 : 0) - (faint ? 5000 : 0) + (pointedAt(f) ? 100_000 : 0), candidate))
        }
        found.sort { $0.score > $1.score }
        return Report(candidates: found.prefix(limit).map(\.candidate), seconds: Double(x.count) / sampleRate)
    }
}
