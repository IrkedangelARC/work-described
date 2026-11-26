//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ScopeKit

/// Run `x` through the analyser and the ring detector exactly as the app does.
func detect(_ x: [Float], configure: (RingDetector) -> Void = { _ in }, blank: Bool = false) -> (flags: [RingFlag], detector: RingDetector) {
    let an = SpectrumAnalyzer(sampleRate: fs, hop: hop)
    let det = RingDetector(layout: an.layout, sliceInterval: an.sliceInterval, resolution: an.resolution)
    configure(det)
    var flags: [RingFlag] = []
    var slice = 0
    var levels = [Float](repeating: 0, count: an.layout.count)
    feed(x) { p, n in
        an.process(p, count: n) { s in
            for b in 0..<s.count { levels[b] = s[b] > 1e-16 ? 10 * log10(s[b]) : -160 }
            slice += 1
            levels.withUnsafeBufferPointer { flags += det.process($0, time: Double(slice) * an.sliceInterval, blanked: blank) }
        }
    }
    return (flags, det)
}

final class RingDetectorTests: XCTestCase {
    func testRingIsNamedAtItsFrequencyOnEveryHit() {
        let flags = detect(TestSignals.ringScene(sampleRate: fs, ringHz: 2400)).flags
        let opened = flags.filter { !$0.final }, closed = flags.filter(\.final)
        XCTAssertEqual(opened.count, 3, "one flag per hit: \(flags)")
        XCTAssertEqual(closed.count, 3)
        for f in flags {
            XCTAssertEqual(f.frequency, 2400, accuracy: 2400 * 0.03)
            XCTAssertEqual(f.thirdOctave, 21, "the 2.5k fader")
            XCTAssertLessThan(f.neighbourMs, 250)
        }
        for (i, f) in opened.enumerated() {
            // On the slice clock, which runs half the longest window (32768 samples) behind the sound.
            XCTAssertEqual(f.time, 1 + 3 * Double(i) + 16_384 / fs, accuracy: 0.1, "timed at the hit")
            XCTAssertLessThan(f.tailMs, 450, "flagged within half a second of the hit")
        }
        for f in closed {
            // 20 dB of a T60 of 2.0 s is 667 ms.
            XCTAssertEqual(f.decayMs ?? 0, 667, accuracy: 60)
            XCTAssertGreaterThan(f.excessMs, 400)
            XCTAssertGreaterThan(f.tailMs, 1500)
        }
    }

    func testRingsAreFoundAcrossTheSpectrum() {
        // One per analysis window: 32768, 8192, 2048 and 512 samples.
        for hz in [125.0, 630, 3150, 8000] {
            let flags = detect(TestSignals.ringScene(sampleRate: fs, ringHz: hz)).flags.filter { !$0.final }
            XCTAssertGreaterThanOrEqual(flags.count, 2, "\(hz) Hz")
            for f in flags { XCTAssertEqual(f.frequency, hz, accuracy: hz * 0.04, "\(hz) Hz") }
        }
    }

    func testAQuietRingUnderTheHitIsStillFound() {
        // The tail starts 20 dB under the burst in its own band: on the waterfall it only shows once the hit has gone.
        let flags = detect(TestSignals.ringScene(sampleRate: fs, ringHz: 2400, ringPeakDBFS: -62)).flags.filter { !$0.final }
        XCTAssertGreaterThanOrEqual(flags.count, 2)
        for f in flags { XCTAssertEqual(f.frequency, 2400, accuracy: 2400 * 0.03) }
    }

    func testAnEvenDecayRaisesNothing() {
        XCTAssertEqual(detect(TestSignals.ringScene(sampleRate: fs, hits: 8, gap: 2, ringHz: nil)).flags, [])
        XCTAssertEqual(detect(TestSignals.ringScene(sampleRate: fs, hits: 8, gap: 2, ringHz: nil, pinkBurst: true)).flags, [])
        XCTAssertEqual(detect(TestSignals.ringScene(sampleRate: fs, hits: 8, gap: 2, ringHz: nil, roomT60: 1.2, pinkBurst: true)).flags, [])
    }

    func testSteadyNoiseRaisesNothing() {
        XCTAssertEqual(detect(TestSignals.pink(Int(fs * 20)).map { $0 * 0.05 }).flags, [])
    }

    func testAHeldToneIsNotARing() {
        // A steady 1 kHz tone under the same hits: it never decays, but it was there before the hit.
        var x = TestSignals.ringScene(sampleRate: fs, ringHz: nil)
        let tone = TestSignals.sine(1010, peakDBFS: -30, seconds: Double(x.count) / fs, sampleRate: fs)
        for i in 0..<x.count { x[i] += tone[i] }
        XCTAssertEqual(detect(x).flags, [])
    }

    func testANoteThatStartsAfterTheHitIsNotARing() {
        // A one second note, half a second after each hit, with the 30 ms attack and release a played
        // note has. (A tone gated on with a click IS a hit plus a tail: see the detector's notes.)
        var x = TestSignals.ringScene(sampleRate: fs, ringHz: nil)
        for h in 0..<3 {
            let start = Int(fs * (1.5 + 3 * Double(h)))
            for i in 0..<Int(fs) {
                let t = Double(i) / fs
                let env = min(1, t / 0.03, (1 - t) / 0.03)
                x[start + i] += Float(0.03 * 0.5 * (1 - cos(Double.pi * env)) * sin(2 * Double.pi * 1500 * t))
            }
        }
        XCTAssertEqual(detect(x).flags, [])
    }

    func testFeedbackThatHoldsIsFlaggedAsSustained() {
        // Excited by the hit, then it does not die: it creeps up 2 dB a second.
        var x = TestSignals.ringScene(sampleRate: fs, hits: 1, gap: 4, ringHz: nil)
        let start = Int(fs)
        for i in 0..<Int(fs * 3.9) {
            let t = Double(i) / fs
            x[start + i] += Float(0.003 * pow(10, 2 * t / 20) * sin(2 * Double.pi * 3150 * t))
        }
        let det = detect(x)
        var flags = det.flags
        flags += det.detector.closeAll(time: 5)
        XCTAssertEqual(flags.filter { !$0.final }.count, 1, "\(flags)")
        let last = flags.last!
        XCTAssertTrue(last.final)
        XCTAssertTrue(last.sustained)
        XCTAssertEqual(last.slopeDBPerSecond, 2, accuracy: 0.5)
        XCTAssertEqual(last.frequency, 3150, accuracy: 3150 * 0.03)
        XCTAssertGreaterThan(last.tailMs, 3000)
    }

    func testOffSwitchAndClippedSlicesRaiseNothing() {
        let x = TestSignals.ringScene(sampleRate: fs, ringHz: 2400)
        XCTAssertEqual(detect(x, configure: { $0.enabled = false }).flags, [])
        XCTAssertEqual(detect(x, blank: true).flags, [])
    }

    func testRingTimeTraceShowsTheBandThatHangsOn() {
        let det = detect(TestSignals.ringScene(sampleRate: fs, hits: 5, ringHz: 2400)).detector
        let b = det.layout.index(of: 2400)
        let around = ((b - 14)...(b + 14)).filter { abs($0 - b) > 3 }.map { det.ringTimeMs[$0] }.sorted()
        XCTAssertEqual(det.ringTimeMs[b], 667, accuracy: 120)
        XCTAssertLessThan(around[around.count / 2], 250)
    }
}
