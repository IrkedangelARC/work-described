import XCTest
@testable import ScopeKit

/// A peaking EQ (RBJ cookbook), the "known EQ curve" of the plan's two-channel test pair.
private struct Peak {
    let b0, b1, b2, a1, a2: Double
    init(hz: Double, gainDB: Double, q: Double) {
        let a = pow(10, gainDB / 40), w = 2 * Double.pi * hz / fs, alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha / a
        b0 = (1 + alpha * a) / a0; b1 = -2 * cos(w) / a0; b2 = (1 - alpha * a) / a0
        a1 = -2 * cos(w) / a0; a2 = (1 - alpha / a) / a0
    }
    func run(_ x: [Float]) -> [Float] {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        return x.map { s in
            let v = Double(s), y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = v; y2 = y1; y1 = y
            return Float(y)
        }
    }
    /// (dB, degrees) at `hz`.
    func response(_ hz: Double) -> (Double, Double) {
        let w = 2 * Double.pi * hz / fs
        let nr = b0 + b1 * cos(w) + b2 * cos(2 * w), ni = -b1 * sin(w) - b2 * sin(2 * w)
        let dr = 1 + a1 * cos(w) + a2 * cos(2 * w), di = -a1 * sin(w) - a2 * sin(2 * w)
        let mag = sqrt((nr * nr + ni * ni) / (dr * dr + di * di))
        return (20 * log10(mag), (atan2(ni, nr) - atan2(di, dr)) * 180 / .pi)
    }
}

private func delayed(_ x: [Float], by d: Int) -> [Float] { [Float](repeating: 0, count: d) + x.dropLast(d) }

final class TransferFunctionTests: XCTestCase {
    private func run(_ ref: [Float], _ mic: [Float], delay: Int = 0, seconds: Double = 0) -> TransferResult {
        let tf = TransferFunction(sampleRate: fs)
        tf.averagingSeconds = seconds
        tf.delaySamples = delay
        var i = 0
        while i < ref.count {
            let n = min(1024, ref.count - i)
            ref.withUnsafeBufferPointer { r in mic.withUnsafeBufferPointer { m in
                tf.process(reference: r.baseAddress! + i, measurement: m.baseAddress! + i, count: n)
            } }
            i += n
        }
        return tf.result
    }

    /// The loopback case of the plan: flat magnitude, zero phase, coherence 1.
    func testASignalAgainstItselfIsFlat() {
        let x = TestSignals.pink(Int(fs * 8)).map { $0 * 0.1 }
        let r = run(x, x)
        for b in 0..<r.frequencies.count where r.frequencies[b] < 20_000 {
            XCTAssertTrue(r.valid[b], "\(r.frequencies[b]) Hz")
            XCTAssertEqual(r.magnitudeDB[b], 0, accuracy: 0.01)
            XCTAssertEqual(r.phaseDegrees[b], 0, accuracy: 0.01)
            XCTAssertEqual(r.coherence[b], 1, accuracy: 1e-4)
        }
    }

    /// Reference through a known delay, EQ and gain: the delay finder reads the delay back to
    /// the sample and the transfer function reads the EQ back in magnitude and phase.
    func testKnownDelayAndEQReadBack() {
        let ref = TestSignals.pink(Int(fs * 12)).map { $0 * 0.1 }
        let eq = Peak(hz: 1000, gainDB: 6, q: 2)
        let d = 542                                   // 11.29 ms
        let mic = delayed(eq.run(ref), by: d).map { $0 * 0.5 }

        let finder = DelayFinder(sampleRate: fs)
        var last: DelayEstimate?
        feedPair(ref, mic) { r, m, n in if let e = finder.process(reference: r, measurement: m, count: n) { last = e } }
        let e = try! XCTUnwrap(last)
        XCTAssertTrue(e.found)
        XCTAssertEqual(e.samples, Double(d), accuracy: 0.5)
        XCTAssertEqual(e.milliseconds, 11.29, accuracy: 0.02)
        XCTAssertFalse(e.inverted)
        XCTAssertEqual(e.metres(celsius: 20), 3.873, accuracy: 0.01)

        let r = run(ref, mic, delay: d)
        for hz in [63.0, 250, 700, 1000, 1400, 4000, 12_000] {
            let b = BandLayout(fraction: 24).index(of: hz)
            let (db, deg) = eq.response(r.frequencies[b])
            XCTAssertEqual(Double(r.magnitudeDB[b]), db - 6.02, accuracy: 0.3, "\(hz) Hz magnitude")
            XCTAssertEqual(Double(r.phaseDegrees[b]), deg, accuracy: 4, "\(hz) Hz phase")
            XCTAssertGreaterThan(r.coherence[b], 0.95, "\(hz) Hz coherence")
        }
    }

    func testWrongDelayShowsAsLowCoherenceUpTop() {
        let ref = TestSignals.white(Int(fs * 6)).map { $0 * 0.1 }
        let r = run(ref, delayed(ref, by: 542))        // not compensated
        let b = BandLayout(fraction: 24).index(of: 8000)
        XCTAssertLessThan(r.coherence[b], 0.3, "half a window late at 8 kHz: the measurement is not this reference")
    }

    func testUnrelatedInputsHaveNoCoherence() {
        let r = run(TestSignals.white(Int(fs * 10), seed: 1), TestSignals.white(Int(fs * 10), seed: 2))
        for hz in [100.0, 1000, 8000] {
            XCTAssertLessThan(r.coherence[BandLayout(fraction: 24).index(of: hz)], 0.3, "\(hz) Hz")
        }
    }

    func testNoiseAtTheMicLowersCoherenceNotTheAnswer() {
        let ref = TestSignals.pink(Int(fs * 20), seed: 3).map { $0 * 0.1 }
        let noise = TestSignals.pink(Int(fs * 20), seed: 4).map { $0 * 0.1 }
        let mic = zip(ref, noise).map { $0 + $1 }      // 0 dB signal to noise
        let r = run(ref, mic)
        for hz in [500.0, 2000, 6000] {
            let b = BandLayout(fraction: 24).index(of: hz)
            XCTAssertEqual(r.magnitudeDB[b], 0, accuracy: 1.0, "\(hz) Hz: H1 leaves the mic's own noise out")
            XCTAssertEqual(r.coherence[b], 0.5, accuracy: 0.15)
        }
    }

    func testPointsWaitForEnoughFrames() {
        let x = TestSignals.pink(Int(fs * 0.5))
        let r = run(x, x)
        XCTAssertFalse(r.valid[BandLayout(fraction: 24).index(of: 50)], "the 0.68 s window has not filled once")
        XCTAssertTrue(r.valid[BandLayout(fraction: 24).index(of: 8000)])
    }
}

private func feedPair(_ a: [Float], _ b: [Float], _ body: (UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void) {
    a.withUnsafeBufferPointer { ap in b.withUnsafeBufferPointer { bp in
        var i = 0
        while i < a.count {
            let n = min(700, a.count - i)
            body(ap.baseAddress! + i, bp.baseAddress! + i, n)
            i += n
        }
    } }
}

final class DelayFinderTests: XCTestCase {
    private func find(_ ref: [Float], _ mic: [Float]) -> (DelayEstimate?, DelayFinder) {
        let f = DelayFinder(sampleRate: fs)
        var last: DelayEstimate?
        feedPair(ref, mic) { r, m, n in if let e = f.process(reference: r, measurement: m, count: n) { last = e } }
        return (last, f)
    }

    func testNoDelayIsAUnitImpulseAtZero() {
        let x = TestSignals.pink(Int(fs * 5)).map { $0 * 0.1 }
        let (e, f) = find(x, x)
        XCTAssertEqual(e!.samples, 0, accuracy: 0.05)
        XCTAssertEqual(f.impulse[0], 1, accuracy: 0.02, "the impulse response keeps true scale")
        XCTAssertGreaterThan(e!.peakToNoiseDB, 40)
    }

    func testDelaysShortLongAndNegative() {
        let x = TestSignals.pink(Int(fs * 8)).map { $0 * 0.1 }
        for d in [1, 48, 4800, 20_000] {
            let (e, _) = find(x, delayed(x, by: d))
            XCTAssertTrue(e!.found, "\(d)")
            XCTAssertEqual(e!.samples, Double(d), accuracy: 0.5, "\(d) samples")
        }
        let (e, _) = find(delayed(x, by: 300), x)
        XCTAssertEqual(e!.samples, -300, accuracy: 0.5, "the reference is the late one")
    }

    func testPolarityFlipIsSeen() {
        let x = TestSignals.pink(Int(fs * 5)).map { $0 * 0.1 }
        let (e, _) = find(x, delayed(x, by: 100).map { -$0 })
        XCTAssertTrue(e!.inverted)
        XCTAssertEqual(e!.samples, 100, accuracy: 0.5)
    }

    func testFoundThroughRoomNoiseAndRefusedOnUnrelatedInputs() {
        let x = TestSignals.pink(Int(fs * 8), seed: 5).map { $0 * 0.1 }
        let noise = TestSignals.pink(Int(fs * 8), seed: 6).map { $0 * 0.1 }
        let (e, _) = find(x, zip(delayed(x, by: 1234), noise).map { $0 + $1 })
        XCTAssertTrue(e!.found)
        XCTAssertEqual(e!.samples, 1234, accuracy: 0.5)
        let (none, _) = find(x, noise)
        XCTAssertFalse(none!.found, "nothing of the reference in the measurement")
    }
}

final class GeneratorTests: XCTestCase {
    private func render(_ configure: (SignalGenerator) -> Void, seconds: Double = 4) -> [Float] {
        let g = SignalGenerator(sampleRate: fs)
        configure(g)
        g.running = true
        var out = [Float](repeating: 0, count: Int(fs * seconds))
        var i = 0
        while i < out.count {
            let n = min(512, out.count - i)
            out.withUnsafeMutableBufferPointer { g.render(into: $0.baseAddress! + i, count: n) }
            i += n
        }
        return out
    }
    private func rmsDB(_ x: ArraySlice<Float>) -> Double { 10 * log10(Double(x.reduce(0) { $0 + $1 * $1 }) / Double(x.count)) }

    func testEverySignalComesOutAtTheLevelAsked() {
        for signal in GeneratorSignal.allCases {
            let x = render { $0.settings.signal = signal; $0.settings.levelDBFS = -20; $0.settings.sweepSeconds = 2 }
            XCTAssertEqual(rmsDB(x[4800...]), -20, accuracy: 0.3, signal.rawValue)
            XCTAssertLessThan(x.map(abs).max()!, 1)
        }
    }

    func testPinkIsPinkAndWhiteIsWhite() {
        for (signal, slope) in [(GeneratorSignal.pink, 0.0), (.white, 3.0)] {
            let x = render({ $0.settings.signal = signal; $0.settings.levelDBFS = -20 }, seconds: 20)
            let p = powers(x, fraction: 3)
            // dB per octave between the 125 Hz and 8 kHz bands (six octaves apart).
            let perOctave = (db(p[26]) - db(p[8])) / 6
            XCTAssertEqual(Double(perOctave), slope, accuracy: 0.25, signal.rawValue)
        }
    }

    func testSineIsAtItsFrequencyAndLevelCannotExceedTheCeiling() {
        let x = render { $0.settings.signal = .sine; $0.settings.frequency = 1000; $0.settings.levelDBFS = +10 }
        XCTAssertEqual(rmsDB(x[4800...]), -3.01, accuracy: 0.05, "held to a full-scale sine")
        let crossings = (4800..<x.count - 1).filter { x[$0] <= 0 && x[$0 + 1] > 0 }.count
        XCTAssertEqual(Double(crossings) / (Double(x.count - 4800) / fs), 1000, accuracy: 1)
        var s = GeneratorSettings(); s.signal = .pink; s.levelDBFS = 0
        XCTAssertEqual(s.clampedLevel, -12)
    }

    func testStartsAndStopsWithoutAClick() {
        let g = SignalGenerator(sampleRate: fs)
        g.settings.signal = .sine; g.settings.levelDBFS = -6
        g.running = true
        var a = [Float](repeating: 0, count: 4800)
        g.render(into: &a, count: a.count)
        XCTAssertLessThan(abs(a[10]), 0.01, "ramps up from nothing")
        g.running = false
        var b = [Float](repeating: 0, count: 4800)
        g.render(into: &b, count: b.count)
        XCTAssertEqual(b[4799], 0)
        XCTAssertFalse(g.audible)
        let steps = zip(a + b, (a + b).dropFirst()).map { abs($1 - $0) }.max()!
        XCTAssertLessThan(steps, 0.1, "no jump between neighbouring samples")
    }
}
