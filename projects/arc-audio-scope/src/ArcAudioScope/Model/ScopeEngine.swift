//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ScopeKit

/// What the RING OUT screen draws, replaced whole about 20 times a second.
struct ScopeFrame {
    /// Index into `SliceHistory.bandCounts` of the banding these traces are at.
    var fractionIndex = 3
    /// dBFS, unweighted.
    var levels: [Float] = []
    var peaks: [Float] = []
    var maxes: [Float] = []
    /// Per 1/24 band, ms to fall 20 dB.
    var ringTimeMs: [Float] = []
    /// Slices analysed since the engine started, and the analyser clock in seconds.
    var slices = 0
    var time = 0.0
    /// Ring flags opened or closed since the last frame.
    var events: [RingFlag] = []
    var testSignal = false
    /// The averaged 1/3 and 1/24 levels whatever banding is on screen: what CAPTURE stores.
    var thirds: [Float] = []
    var fine: [Float] = []
}

/// The scope's signal path: mic samples in, slices out. Runs the MTW analyser (1/24, summed to
/// 1/12 and 1/6), the 1/3 octave filter bank, the RTA averagers and the ring detector, and
/// writes every slice to the history. Lives on the DSP queue.
final class ScopeEngine {
    let sampleRate: Double
    let hop: Int
    let sliceInterval: Double
    private let history: SliceHistory
    private let analyzer: SpectrumAnalyzer
    private let bank: OctaveFilterBank
    private let detector: RingDetector
    private let layouts = BandLayout.fractions.map { BandLayout(fraction: $0) }
    private var averagers: [BandAverager]
    private var power: [[Float]]
    private var levels: [[Float]]
    private var thirdQueue: [Float]
    private var queued = 0, used = 0
    /// The filter bank answers at once; the FFT slices are centred `latencySeconds` back. The
    /// bank's slices wait in this line so both views of one hit sit on the same waterfall row.
    private var thirdDelay: [Float]
    private let thirdDelaySlices: Int
    private var thirdDelayAt = 0
    var latencySeconds: Double { analyzer.latencySeconds }
    private var slices = 0
    private var events: [RingFlag] = []
    /// The sound itself for as long as the waterfall holds, kept whole for MARK: the tech hits
    /// the key (live, or scrolled back to a moment) and `markSeconds` are gone over again with
    /// long windows. Sample i sits at i % recent.count.
    static let markSeconds = 4.0
    private var recent: [Float]
    private var written = 0

    var fractionIndex = 3
    var averaging = SpectrumAveraging.fast { didSet { averagers.forEach { $0.averaging = averaging } } }
    var ringDetect = true {
        didSet {
            detector.enabled = ringDetect
            if !ringDetect { events += detector.closeAll(time: Double(slices) * sliceInterval) }
        }
    }

    var harmonicCheck = true { didSet { detector.harmonicCheck = harmonicCheck } }

    /// TEST SIGNAL: a known scene (pink hits with a 2.4 kHz tail) replaces the microphone.
    var testSignal = false {
        didSet {
            if testSignal, scene.isEmpty { scene = Self.makeScene(sampleRate) }
            guard testSignal != oldValue else { return }
            // What the detector was following belongs to the old source, and so does the sound
            // still inside the analyser's windows: close its flags and sit out until that has
            // passed, or the old source's last ring is logged against the new one.
            events += detector.closeAll(time: Double(slices) * sliceInterval)
            sourceHold = Int((3.0 / sliceInterval).rounded())
        }
    }
    private var sourceHold = 0
    private var scene: [Float] = []
    private var scenePosition = 0
    private var sceneBlock = [Float](repeating: 0, count: 16_384)

    static func makeScene(_ sampleRate: Double) -> [Float] {
        TestSignals.ringScene(sampleRate: sampleRate, hits: 4, gap: 3, ringHz: 2400, ringT60: 2.0, ringPeakDBFS: -40,
                              roomT60: 0.4, burstRMSDBFS: -20, floorRMSDBFS: -75, pinkBurst: true)
    }

    init(sampleRate: Double, history: SliceHistory) {
        self.sampleRate = sampleRate
        self.history = history
        hop = Int((sampleRate / 50).rounded())           // 50 slices a second
        recent = [Float](repeating: 0, count: SliceHistory.capacity * hop)
        sliceInterval = Double(hop) / sampleRate
        analyzer = SpectrumAnalyzer(sampleRate: sampleRate, hop: hop)
        bank = OctaveFilterBank(sampleRate: sampleRate, hop: hop)
        detector = RingDetector(layout: analyzer.layout, sliceInterval: sliceInterval, resolution: analyzer.resolution)
        averagers = SliceHistory.bandCounts.map { BandAverager(bands: $0, sliceInterval: Double(Int((sampleRate / 50).rounded())) / sampleRate) }
        power = SliceHistory.bandCounts.map { [Float](repeating: 0, count: $0) }
        levels = SliceHistory.bandCounts.map { [Float](repeating: -200, count: $0) }
        thirdQueue = [Float](repeating: 0, count: 31 * 64)
        thirdDelaySlices = max(1, Int((analyzer.latencySeconds / sliceInterval).rounded()))
        thirdDelay = [Float](repeating: 0, count: 31 * thirdDelaySlices)
        history.reset(sliceInterval: sliceInterval)
    }

    func resetTraces() { averagers.forEach { $0.reset() } }

    /// `blanked`: these samples clipped at the input and must not be read as ring data.
    func process(_ samples: UnsafePointer<Float>, count: Int, blanked: Bool) {
        var done = 0
        while done < count {
            // Chunks small enough that the filter bank never queues more slices than the queue holds.
            let n = min(count - done, sceneBlock.count)
            if testSignal, !scene.isEmpty {
                for i in 0..<n {
                    sceneBlock[i] = scene[scenePosition]
                    scenePosition = (scenePosition + 1) % scene.count
                }
                sceneBlock.withUnsafeBufferPointer { run($0.baseAddress!, n, false) }
            } else {
                run(samples + done, n, blanked)
            }
            done += n
        }
    }

    /// `markSeconds` of sound, oldest first, ending now or at the moment waterfall slice
    /// `endSlice` shows. Shorter (or empty) when that moment is no longer held.
    func samples(endingAt endSlice: Int?) -> [Float] {
        let size = recent.count
        let end = min(written, endSlice.map { $0 * hop - Int((latencySeconds * sampleRate).rounded()) } ?? written)
        let start = max(end - Int(sampleRate * Self.markSeconds), written - size, 0)
        guard end > start else { return [] }
        var out = [Float](repeating: 0, count: end - start)
        var done = 0
        while done < out.count {
            let at = (start + done) % size, m = min(out.count - done, size - at)
            out.withUnsafeMutableBufferPointer { o in
                recent.withUnsafeBufferPointer { (o.baseAddress! + done).update(from: $0.baseAddress! + at, count: m) }
            }
            done += m
        }
        return out
    }

    private func run(_ p: UnsafePointer<Float>, _ n: Int, _ blanked: Bool) {
        let size = recent.count
        var copied = 0
        while copied < n {
            let at = written % size, m = min(n - copied, size - at)
            recent.withUnsafeMutableBufferPointer { ($0.baseAddress! + at).update(from: p + copied, count: m) }
            written += m
            copied += m
        }
        // Both analysers cut slices at the same samples. The filter bank goes first and queues its
        // slices; the FFT analyser then pairs each of its own with the matching one.
        queued = 0
        used = 0
        bank.process(p, count: n) { s in
            guard queued < 64 else { return }
            thirdQueue.withUnsafeMutableBufferPointer { q in
                (q.baseAddress! + queued * 31).update(from: s.baseAddress!, count: 31)
            }
            queued += 1
        }
        analyzer.process(p, count: n) { fine in slice(fine, blanked) }
    }

    private func slice(_ fine: UnsafeBufferPointer<Float>, _ blanked: Bool) {
        power[3].withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: fine.baseAddress!, count: fine.count) }
        layouts[2].sum(fine, from: layouts[3], into: &power[2])
        layouts[1].sum(fine, from: layouts[3], into: &power[1])
        if used < queued {
            for b in 0..<31 {
                power[0][b] = thirdDelay[thirdDelayAt * 31 + b]
                thirdDelay[thirdDelayAt * 31 + b] = thirdQueue[used * 31 + b]
            }
            thirdDelayAt = (thirdDelayAt + 1) % thirdDelaySlices
            used += 1
        }
        for f in 0..<4 {
            for b in 0..<power[f].count { levels[f][b] = power[f][b] > 1e-20 ? 10 * log10(power[f][b]) : -200 }
            power[f].withUnsafeBufferPointer { averagers[f].process($0) }
        }
        slices += 1
        if sourceHold > 0 { sourceHold -= 1 }
        levels[3].withUnsafeBufferPointer {
            events += detector.process($0, time: Double(slices) * sliceInterval, blanked: blanked || sourceHold > 0)
        }
        history.append(levels)
    }

    /// The traces now, and the ring events since the last call.
    func frame() -> ScopeFrame {
        let a = averagers[fractionIndex]
        let f = ScopeFrame(fractionIndex: fractionIndex, levels: a.levelsDB, peaks: a.peaksDB, maxes: a.maxDB,
                           ringTimeMs: detector.ringTimeMs, slices: slices, time: Double(slices) * sliceInterval,
                           events: events, testSignal: testSignal, thirds: averagers[0].levelsDB, fine: averagers[3].levelsDB)
        events.removeAll(keepingCapacity: true)
        return f
    }
}
