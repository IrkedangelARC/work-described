//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ScopeKit

/// What the ALIGN screen draws, about ten times a second.
struct TransferFrame {
    var result = TransferResult()
    /// The delay taken out of the reference, samples.
    var appliedSamples = 0
    /// The delay finder's latest reading.
    var estimate: DelayEstimate?
    /// The impulse response around the arrival, and the lag (samples) of its first point.
    var impulse: [Float] = []
    var impulseStart = 0
    /// Reference and measurement levels, dBFS RMS over the last moment.
    var referenceDB = -Double.infinity
    var measurementDB = -Double.infinity
    var blocks = 0
    var finding = false
    /// Does coherence fall as the reference gets louder (clip tier 3)? Nil until both a loud
    /// and a quieter level have been heard.
    var distortion: DistortionMonitor.Verdict?
}

/// Pairs the reference with the mic, runs the transfer function and the delay finder, and
/// keeps the delay applied. Lives on the DSP queue.
///
/// The two streams reach it from different callbacks (the generator from the output side, the
/// mic from the input side), so each waits in a short line and they are consumed in step. The
/// offset between the lines is fixed while the engine runs, and is part of the delay found.
final class TransferEngine {
    let sampleRate: Double
    private let tf: TransferFunction
    private let finder: DelayFinder
    private let capacity: Int
    private var ref: [Float], mic: [Float]
    private var refCount = 0, micCount = 0
    private var candidate: Int?
    private var findPending = false
    private var refPower = 0.0, micPower = 0.0
    private var impulse: [Float] = []
    private var impulseStart = 0
    private(set) var applied = 0
    private let distortion = DistortionMonitor()
    /// Reference power, smoothed over the same time the transfer function averages over, so a
    /// coherence reading is set against the level it was taken at.
    private var monitorPower = 0.0
    private var sinceReading = 0

    var enabled = false { didSet { if enabled != oldValue { restart() } } }
    var track = true
    var averagingSeconds: Double {
        get { tf.averagingSeconds }
        set { if newValue != tf.averagingSeconds { tf.averagingSeconds = newValue; tf.reset() } }
    }

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        tf = TransferFunction(sampleRate: sampleRate)
        finder = DelayFinder(sampleRate: sampleRate)
        capacity = Int(sampleRate)
        ref = [Float](repeating: 0, count: capacity)
        mic = [Float](repeating: 0, count: capacity)
    }

    /// Start over: a new reference, a new source, or the two lines fell out of step.
    func restart() {
        refCount = 0; micCount = 0
        candidate = nil
        tf.reset()
        finder.reset()
        impulse = []
        distortion.reset()
        monitorPower = 0
        sinceReading = 0
    }

    func setDelay(_ samples: Int) {
        findPending = false
        candidate = nil
        apply(samples)
    }

    /// Take the next confident reading, whatever it is.
    func find() {
        finder.reset()
        candidate = nil
        findPending = true
    }

    private func apply(_ samples: Int) {
        tf.delaySamples = samples
        applied = tf.delaySamples
    }

    func push(reference p: UnsafePointer<Float>, count: Int) { push(p, count, &ref, &refCount) }
    func push(measurement p: UnsafePointer<Float>, count: Int) { push(p, count, &mic, &micCount) }

    private func push(_ p: UnsafePointer<Float>, _ count: Int, _ line: inout [Float], _ held: inout Int) {
        guard enabled, count > 0 else { return }
        if held + count > capacity {
            // One side has stopped arriving. Whatever comes next is not in step with what is held.
            restart()
            guard count <= capacity else { return }
        }
        line.withUnsafeMutableBufferPointer { ($0.baseAddress! + held).update(from: p, count: count) }
        held += count
    }

    /// Consume what both lines hold.
    func run() {
        let n = min(refCount, micCount)
        guard enabled, n > 0 else { return }
        ref.withUnsafeMutableBufferPointer { r in
            mic.withUnsafeMutableBufferPointer { m in
                var sr: Float = 0, sm: Float = 0
                for i in 0..<n { sr += r[i] * r[i]; sm += m[i] * m[i] }
                let a = min(1, Double(n) / (0.3 * sampleRate))
                refPower += a * (Double(sr) / Double(n) - refPower)
                micPower += a * (Double(sm) / Double(n) - micPower)
                tf.process(reference: r.baseAddress!, measurement: m.baseAddress!, count: n)
                watchDistortion(Double(sr) / Double(n), n)
                if let e = finder.process(reference: r.baseAddress!, measurement: m.baseAddress!, count: n) { heard(e) }
                r.baseAddress!.update(from: r.baseAddress! + n, count: refCount - n)
                m.baseAddress!.update(from: m.baseAddress! + n, count: micCount - n)
            }
        }
        refCount -= n
        micCount -= n
    }

    /// Ten times a second: the mean coherence from 200 Hz to 8 kHz against the reference level.
    /// Not with infinite averaging, where coherence no longer follows the level.
    private func watchDistortion(_ power: Double, _ n: Int) {
        let seconds = tf.averagingSeconds
        guard seconds > 0 else { return }
        monitorPower += min(1, Double(n) / (seconds * sampleRate)) * (power - monitorPower)
        sinceReading += n
        guard sinceReading >= Int(sampleRate / 10) else { return }
        sinceReading = 0
        let r = tf.result
        var sum = 0.0, count = 0
        for b in r.frequencies.indices where r.valid[b] && r.frequencies[b] >= 200 && r.frequencies[b] <= 8000 {
            sum += Double(r.coherence[b]); count += 1
        }
        if count >= 20, monitorPower > 1e-9 { distortion.add(referenceDB: 10 * log10(monitorPower), coherence: sum / Double(count)) }
    }

    private func heard(_ e: DelayEstimate) {
        // The impulse response from 5 ms before the arrival to 45 ms after it.
        let peak = Int(e.samples.rounded()), n = finder.n
        let lead = Int(0.005 * sampleRate), length = Int(0.050 * sampleRate)
        impulseStart = peak - lead
        impulse = (0..<length).map { finder.impulse[((impulseStart + $0) % n + n) % n] }

        guard e.found else { candidate = nil; return }
        if findPending {
            findPending = false
            apply(peak)
        } else if track, abs(peak - applied) > 1 {
            // Two readings in a row that agree with each other and not with the delay in use.
            if let c = candidate, abs(c - peak) <= 1 { apply(peak); candidate = nil } else { candidate = peak }
        } else {
            candidate = nil
        }
    }

    func frame() -> TransferFrame {
        func db(_ p: Double) -> Double { p > 1e-14 ? 10 * log10(p) : -.infinity }
        return TransferFrame(result: tf.result, appliedSamples: applied, estimate: finder.estimate, impulse: impulse,
                             impulseStart: impulseStart, referenceDB: db(refPower), measurementDB: db(micPower),
                             blocks: finder.blocks, finding: findPending, distortion: distortion.verdict)
    }
}

/// The ALIGN screen's data (its own ObservableObject, like the scope's).
@MainActor
final class AlignModel: ObservableObject {
    @Published private(set) var frame = TransferFrame()
    /// Pointer position across the frequency plots, 0...1.
    @Published var cursor: Double?
    func receive(_ f: TransferFrame) { frame = f }
    func clear() { frame = TransferFrame() }
}
