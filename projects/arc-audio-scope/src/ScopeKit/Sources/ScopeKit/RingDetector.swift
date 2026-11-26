//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// One ring: a band that kept going after the bands around it had stopped.
public struct RingFlag: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    /// Seconds since the detector started, at the hit that excited the ring.
    public var time: Double
    /// Hz, centre of the 1/24 octave band (power-weighted across its two neighbours).
    public var frequency: Double
    /// 1/24 octave band index, and the 1/3 octave (GEQ) band it sits in.
    public var band: Int
    public var thirdOctave: Int
    /// Band level in dB when it was flagged.
    public var levelDB: Double
    /// Time the bands around it took to fall, ms per 20 dB.
    public var neighbourMs: Double
    /// How long the tail has stood out since the hit, ms. Final when `final` is true.
    public var tailMs: Double
    /// The tail's own decay, ms per 20 dB, from a line fitted to it. Nil when it is not falling.
    public var decayMs: Double?
    /// Fitted slope of the tail, dB per second. Near zero or positive = holding or growing (feedback).
    public var slopeDBPerSecond: Double
    /// False while it is still ringing.
    public var final: Bool

    /// Decay beyond what the neighbours took, ms. Uses the tail length when the ring is not falling.
    public var excessMs: Double { (decayMs ?? tailMs) - neighbourMs }
    public var sustained: Bool { decayMs == nil }
}

/// Finds rings the way the operator reads a waterfall: after a hit every band falls away, and a band
/// that leaves a trailing line is the ring. Not a rising-tone detector.
///
/// Works on 1/24 octave band levels, slice by slice:
///
/// 1. THE HIT. For each band, the median of the bands half an octave either side is "what the
///    neighbours are doing". When that median falls `neighbourDropDB` from its peak, there was a
///    hit there and it has decayed. This is the onset detector, done per region so a kick and a
///    consonant each count where their energy is.
/// 2. THE TAIL. From then on the band is a ring candidate on every slice where it
///      - stands `prominenceDB` above its neighbours,
///      - is well above what it read before the hit (a note that was already sounding is not a ring),
///      - and has not come back up since the hit (a note that starts later is not a ring).
/// 3. THE FLAG. A candidate that holds for longer than both `minPersistMs` and the band's own
///    analysis window is flagged at the centre band of the tone. It closes, with the tail's length
///    and fitted decay, when the band rejoins its neighbours or the next hit arrives.
///
/// Judging a tail by how far it stands above the neighbour median, rather than by timing each
/// band's own fall, is what keeps noise from raising flags: a narrow band of a decaying noise
/// burst swings many dB slice to slice, but it does not sit 12 dB proud for a whole window.
public final class RingDetector {
    public let layout: BandLayout
    public let dt: Double
    public var enabled = true
    /// dB the neighbours must fall for a hit to count. Their fall time is reported per 20 dB.
    public var neighbourDropDB = 15.0
    /// The neighbours must fall that far within this long, or it was a fade, not a hit.
    public var maxNeighbourFallSeconds = 1.5
    /// dB the tail must stand above the neighbour median.
    public var prominenceDB = 12.0
    /// dB the tail must stand above the band's own level before the hit.
    public var aboveBackgroundDB = 8.0
    /// Shortest tail that is flagged. Bands with a longer analysis window wait one window.
    public var minPersistMs = 150.0
    /// A tail with lines at twice and three times its frequency, or one that is itself the
    /// harmonic of a louder line below it, is a note being played, not a ring: it is not flagged.
    public var harmonicCheck = true

    /// Per band, the smoothed time it takes to fall 20 dB after a peak: the "ring time" trace.
    public private(set) var ringTimeMs: [Float]

    private let n: Int
    private let window: [Double]
    private let leak: [Int]
    private let reach: Int
    private var started = false
    private var slice = 0

    // History of slices, for the level before a hit.
    private let depth: Int
    private var history: [Float]

    // Neighbour median, per band.
    private var ref: [Double]
    private var refPeak: [Double], refPeakAt: [Double]

    // Watch state, per band, after a hit.
    private var watching: [Bool]
    private var hitAt: [Double], fellAt: [Double], neighbourMs: [Double]
    private var refMin: [Double], background: [Double], bandMin: [Double]
    private var runStart: [Double]
    private var fitN: [Double], fitT: [Double], fitY: [Double], fitTT: [Double], fitTY: [Double]
    private var flagID: [Int], flagLevel: [Double], flagHz: [Double]
    /// Judged a played note at some point since the hit. Its overtones die first, so it is remembered.
    private var note: [Bool]
    private var nextID = 1
    private var validFrom = 0.0

    // Each band's own fall timer, for the ring time trace.
    private var ownPeak: [Double], ownPeakAt: [Double]

    private var scratch: [Double] = []

    public init(layout: BandLayout, sliceInterval: Double, resolution: BandResolution) {
        self.layout = layout
        dt = sliceInterval
        n = layout.count
        window = resolution.windowSeconds
        leak = resolution.leakBands
        reach = max(layout.fraction / 2, 3)             // neighbours: half an octave each side
        depth = Int((4.0 / sliceInterval).rounded(.up))
        history = [Float](repeating: -140, count: depth * n)
        ringTimeMs = [Float](repeating: 0, count: n)
        func zeros() -> [Double] { [Double](repeating: 0, count: layout.count) }
        ref = zeros(); refPeak = zeros(); refPeakAt = zeros()
        watching = [Bool](repeating: false, count: n)
        hitAt = zeros(); fellAt = zeros(); neighbourMs = zeros()
        refMin = zeros(); background = zeros(); bandMin = zeros()
        runStart = [Double](repeating: -1, count: n)
        fitN = zeros(); fitT = zeros(); fitY = zeros(); fitTT = zeros(); fitTY = zeros()
        flagID = [Int](repeating: 0, count: n); flagLevel = zeros(); flagHz = zeros()
        ownPeak = zeros(); ownPeakAt = zeros()
        note = [Bool](repeating: false, count: layout.count)
    }

    /// One slice of 1/24 band levels in dB at `time` seconds. `blanked` marks a slice that must not
    /// be read as data (the input clipped): no tail is started or extended on it.
    /// Returns the flags this slice opened (`final` false) or closed (`final` true).
    public func process(_ db: UnsafeBufferPointer<Float>, time t: Double, blanked: Bool = false) -> [RingFlag] {
        precondition(db.count >= n)
        var out: [RingFlag] = []
        let row = (slice % depth) * n
        for b in 0..<n { history[row + b] = max(db[b], -140) }
        slice += 1
        history.withUnsafeBufferPointer { h in
            let now = UnsafeBufferPointer(rebasing: h[row..<(row + n)])
            medians(now)
            if !started {
                // Until the longest window has filled with real samples the slices are part silence.
                validFrom = t + (window.max() ?? 0)
                for b in 0..<n {
                    refPeak[b] = ref[b]; refPeakAt[b] = t
                    ownPeak[b] = Double(now[b]); ownPeakAt[b] = t
                }
                started = true
                return
            }
            for b in 0..<n {
                let level = Double(now[b])
                trackRingTime(b, level, t)
                if watching[b] {
                    watch(b, level, t, now, blanked, &out)
                } else {
                    seekHit(b, level, t, h)
                }
            }
        }
        return out
    }

    /// Close every open flag, as when the detector is switched off or the input stops.
    public func closeAll(time t: Double) -> [RingFlag] {
        var out: [RingFlag] = []
        for b in 0..<n where watching[b] {
            if flagID[b] != 0 { out.append(flag(b, t, final: true)) }
            endWatch(b, t)
        }
        return out
    }

    // MARK: the hit

    private func medians(_ now: UnsafeBufferPointer<Float>) {
        for b in 0..<n {
            scratch.removeAll(keepingCapacity: true)
            let skip = leak[b]
            for j in max(0, b - skip - reach)...min(n - 1, b + skip + reach) where abs(j - b) > skip {
                scratch.append(Double(now[j]))
            }
            scratch.sort()
            ref[b] = scratch.isEmpty ? Double(now[b]) : scratch[scratch.count / 2]
        }
    }

    private func seekHit(_ b: Int, _ level: Double, _ t: Double, _ h: UnsafeBufferPointer<Float>) {
        if ref[b] >= refPeak[b] || t - refPeakAt[b] > maxNeighbourFallSeconds {
            refPeak[b] = ref[b]; refPeakAt[b] = t
            return
        }
        guard ref[b] <= refPeak[b] - neighbourDropDB else { return }
        // The neighbours have fallen. What did this band read before the hit, and how low has it been since?
        let hit = refPeakAt[b]
        let before = hit - window[b]
        // Never from the start-up slices: silence there would make anything already sounding a "tail".
        guard let bg = median(of: b, from: max(before - 1.0, validFrom), to: before - 0.1, now: t, h),
              let low = minimum(of: b, from: hit, to: t, now: t, h) else {
            refPeak[b] = ref[b]; refPeakAt[b] = t
            return
        }
        watching[b] = true
        hitAt[b] = hit
        fellAt[b] = t
        neighbourMs[b] = (t - hit) * 1000 * 20 / neighbourDropDB
        refMin[b] = ref[b]
        background[b] = bg
        bandMin[b] = low
        runStart[b] = -1
        flagID[b] = 0
        note[b] = false
    }

    private func endWatch(_ b: Int, _ t: Double) {
        watching[b] = false
        flagID[b] = 0
        runStart[b] = -1
        refPeak[b] = ref[b]; refPeakAt[b] = t
    }

    // MARK: the tail

    private func watch(_ b: Int, _ level: Double, _ t: Double, _ now: UnsafeBufferPointer<Float>,
                       _ blanked: Bool, _ out: inout [RingFlag]) {
        refMin[b] = min(refMin[b], ref[b])
        bandMin[b] = min(bandMin[b], level)
        let proud = level - ref[b]
        let open = flagID[b] != 0

        // The next hit ends this one. So does a long wait with nothing ringing.
        if ref[b] >= refMin[b] + 8 || (!open && t - fellAt[b] > 8) {
            if open, enabled { out.append(flag(b, t, final: true)) }
            endWatch(b, t)
            return
        }
        if open {
            // Rejoined its neighbours, or sank back to where it was before the hit.
            if proud < prominenceDB - 6 || level < background[b] + aboveBackgroundDB - 4 || !enabled {
                if enabled { out.append(flag(b, t, final: true)) }
                flagID[b] = 0
                runStart[b] = -1
                return
            }
            if !blanked, level >= background[b] + 12 { fit(b, t, level) }
            return
        }
        guard enabled, !blanked,
              proud >= prominenceDB,
              level >= background[b] + aboveBackgroundDB,
              level <= bandMin[b] + 6 else {
            runStart[b] = -1
            return
        }
        if runStart[b] < 0 {
            runStart[b] = t
            fitN[b] = 0; fitT[b] = 0; fitY[b] = 0; fitTT[b] = 0; fitTY[b] = 0
        }
        if level >= background[b] + 12 { fit(b, t, level) }
        if harmonicCheck, !note[b], isNote(b, now) { note[b] = true }
        guard (t - runStart[b]) * 1000 >= max(minPersistMs, window[b] * 1000), isCentre(b, now) else { return }
        if harmonicCheck, note[b] { return }
        flagID[b] = nextID
        nextID += 1
        flagLevel[b] = level
        flagHz[b] = centroid(b, now)
        out.append(flag(b, t, final: false))
    }

    /// The band is the top of its tone: no louder band in its leak range, no flag already open there,
    /// and it is not the side lobe of something far louder nearby.
    private func isCentre(_ b: Int, _ now: UnsafeBufferPointer<Float>) -> Bool {
        let skip = leak[b]
        for j in max(0, b - skip)...min(n - 1, b + skip) where j != b {
            if flagID[j] != 0 || now[j] > now[b] { return false }
        }
        for j in max(0, b - skip - reach)...min(n - 1, b + skip + reach) where now[j] >= now[b] + 20 { return false }
        return true
    }

    /// A line stands out at `ratio` times this band's frequency. Returns its level, or nil.
    private func line(_ b: Int, _ ratio: Double, _ now: UnsafeBufferPointer<Float>) -> Double? {
        let j = b + Int((Double(layout.fraction) * log2(ratio)).rounded())
        guard j >= 1, j < n - 1 else { return nil }
        let level = Double(max(now[j - 1], now[j], now[j + 1]))
        return level - ref[j] >= prominenceDB - 3 ? level : nil
    }

    private func isNote(_ b: Int, _ now: UnsafeBufferPointer<Float>) -> Bool {
        let own = Double(now[b])
        if line(b, 2, now) != nil, line(b, 3, now) != nil { return true }
        for ratio in [0.5, 1.0 / 3] {
            if let below = line(b, ratio, now), below >= own { return true }
        }
        return false
    }

    private func centroid(_ b: Int, _ now: UnsafeBufferPointer<Float>) -> Double {
        var num = 0.0, den = 0.0
        for j in max(0, b - 1)...min(n - 1, b + 1) {
            let p = pow(10, Double(now[j]) / 10)
            num += p * log(layout.centers[j]); den += p
        }
        return den > 0 ? exp(num / den) : layout.centers[b]
    }

    private func fit(_ b: Int, _ t: Double, _ level: Double) {
        let x = t - runStart[b]
        fitN[b] += 1; fitT[b] += x; fitY[b] += level; fitTT[b] += x * x; fitTY[b] += x * level
    }

    private func flag(_ b: Int, _ t: Double, final: Bool) -> RingFlag {
        var slope = 0.0
        let d = fitN[b] * fitTT[b] - fitT[b] * fitT[b]
        if fitN[b] >= 4, d > 1e-9 { slope = (fitN[b] * fitTY[b] - fitT[b] * fitY[b]) / d }
        // Slower than 20 dB a minute is not a decay worth timing: it is holding.
        let decay: Double? = fitN[b] >= 4 && slope < -0.33 ? 20_000 / -slope : nil
        return RingFlag(id: flagID[b], time: hitAt[b], frequency: flagHz[b], band: b, thirdOctave: layout.thirdOctave(of: b),
                        levelDB: flagLevel[b], neighbourMs: neighbourMs[b], tailMs: (t - hitAt[b]) * 1000,
                        decayMs: decay, slopeDBPerSecond: slope, final: final)
    }

    // MARK: ring time trace

    /// Every band times its own fall of 20 dB from a peak. Slowly averaged, it shows which
    /// frequencies keep hanging on over a whole song even when no single hit stood out.
    private func trackRingTime(_ b: Int, _ level: Double, _ t: Double) {
        if level >= ownPeak[b] || t - ownPeakAt[b] > 3 {
            ownPeak[b] = level; ownPeakAt[b] = t
        } else if level <= ownPeak[b] - 20 {
            let ms = Float((t - ownPeakAt[b]) * 1000)
            ringTimeMs[b] = ringTimeMs[b] == 0 ? ms : ringTimeMs[b] + 0.2 * (ms - ringTimeMs[b])
            ownPeak[b] = level; ownPeakAt[b] = t
        }
    }

    // MARK: history

    private func rows(from a: Double, to z: Double, now t: Double) -> ClosedRange<Int>? {
        // The newest slice is `slice - 1`, at time `t`.
        let newest = slice - 1
        let first = max(newest - Int(((t - a) / dt).rounded()), max(0, slice - depth))
        let last = min(newest - Int(((t - z) / dt).rounded()), newest)
        return last - first >= 0 ? first...last : nil
    }

    private func median(of b: Int, from a: Double, to z: Double, now t: Double, _ h: UnsafeBufferPointer<Float>) -> Double? {
        guard let r = rows(from: a, to: z, now: t), r.count >= 5 else { return nil }
        scratch.removeAll(keepingCapacity: true)
        for s in r { scratch.append(Double(h[(s % depth) * n + b])) }
        scratch.sort()
        return scratch[scratch.count / 2]
    }

    private func minimum(of b: Int, from a: Double, to z: Double, now t: Double, _ h: UnsafeBufferPointer<Float>) -> Double? {
        guard let r = rows(from: a, to: z, now: t) else { return nil }
        var m = Double.infinity
        for s in r { m = min(m, Double(h[(s % depth) * n + b])) }
        return m
    }
}
