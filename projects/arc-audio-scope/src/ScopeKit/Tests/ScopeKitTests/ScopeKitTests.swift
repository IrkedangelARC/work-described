//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ScopeKit

let fs = 48_000.0

func sine(_ hz: Double, peakDBFS: Double, seconds: Double) -> [Float] {
    let a = pow(10, peakDBFS / 20)
    return (0..<Int(seconds * fs)).map { Float(a * sin(2 * Double.pi * hz * Double($0) / fs)) }
}

func feed(_ x: [Float], block: Int = 512, _ body: (UnsafePointer<Float>, Int) -> Void) {
    x.withUnsafeBufferPointer { p in
        var i = 0
        while i < x.count {
            let n = min(block, x.count - i)
            body(p.baseAddress! + i, n)
            i += n
        }
    }
}

final class SPSCRingTests: XCTestCase {
    func testWrapKeepsOrder() {
        let ring = SPSCRing(minimumCapacity: 8)
        var out = [Float](repeating: 0, count: 8)
        var next: Float = 0, expect: Float = 0
        for _ in 0..<50 {
            let chunk = (0..<5).map { _ -> Float in next += 1; return next }
            XCTAssertEqual(ring.write(chunk, count: 5), 5)
            let n = ring.read(into: &out, max: 8)
            XCTAssertEqual(n, 5)
            for i in 0..<n { expect += 1; XCTAssertEqual(out[i], expect) }
        }
        XCTAssertEqual(ring.dropped, 0)
    }

    func testFullRingDropsNewSamplesAndCountsThem() {
        let ring = SPSCRing(minimumCapacity: 8)
        let x = (1...12).map(Float.init)
        XCTAssertEqual(ring.write(x, count: 12), 8)
        XCTAssertEqual(ring.dropped, 4)
        var out = [Float](repeating: 0, count: 16)
        XCTAssertEqual(ring.read(into: &out, max: 16), 8)
        XCTAssertEqual(Array(out[0..<8]), Array(x[0..<8]))
    }

    func testOneWriterOneReaderLosesNothing() {
        let ring = SPSCRing(minimumCapacity: 4096)
        let total = 2_000_000
        let writer = Thread {
            var v: Float = 0
            var block = [Float](repeating: 0, count: 256)
            var sent = 0
            while sent < total {
                for i in 0..<256 { block[i] = v + Float(i) }
                let n = ring.write(block, count: min(256, total - sent))
                // A full ring drops the tail of the block; resend from the first unsent value.
                v += Float(n); sent += n
                if v >= 8_000_000 { v = 0 }
            }
        }
        writer.start()
        var out = [Float](repeating: 0, count: 1024)
        var got = 0
        var expect: Float = 0
        var bad = 0
        while got < total {
            let n = ring.read(into: &out, max: 1024)
            for i in 0..<n {
                if out[i] != expect { bad += 1 }
                expect += 1
                if expect >= 8_000_000 { expect = 0 }
            }
            got += n
        }
        XCTAssertEqual(bad, 0)
        XCTAssertEqual(got, total)
    }
}

final class WeightingTests: XCTestCase {
    // IEC 61672-1 table 3: nominal frequency, A, C, class 1 limits (+, -).
    let table: [(f: Double, a: Double, c: Double, plus: Double, minus: Double)] = [
        (31.5, -39.4, -3.0, 1.5, 1.5), (63, -26.2, -0.8, 1.0, 1.0), (125, -16.1, -0.2, 1.0, 1.0),
        (250, -8.6, 0.0, 1.0, 1.0), (500, -3.2, 0.0, 1.0, 1.0), (1000, 0.0, 0.0, 0.7, 0.7),
        (2000, 1.2, -0.2, 1.0, 1.0), (4000, 1.0, -0.8, 1.0, 1.0), (8000, -1.1, -3.0, 1.5, 2.5),
        (12500, -4.3, -6.2, 2.0, 5.0), (16000, -6.6, -8.5, 2.5, 16.0),
    ]

    func testDesignHoldsClassOneAt48k() {
        for row in table {
            let a = WeightingDesign.responseDB(.a, at: row.f, sampleRate: fs)
            let c = WeightingDesign.responseDB(.c, at: row.f, sampleRate: fs)
            print(String(format: "%7.1f Hz  A %7.2f (std %6.1f)  C %7.2f (std %6.1f)", row.f, a, row.a, c, row.c))
            XCTAssertLessThanOrEqual(a - row.a, row.plus, "A at \(row.f)")
            XCTAssertGreaterThanOrEqual(a - row.a, -row.minus, "A at \(row.f)")
            XCTAssertLessThanOrEqual(c - row.c, row.plus, "C at \(row.f)")
            XCTAssertGreaterThanOrEqual(c - row.c, -row.minus, "C at \(row.f)")
        }
    }

    func testDesignTracksTheAnalogCurveThroughTheMidband() {
        // Above 3 kHz the bilinear design runs up to 0.4 dB high (see the class 1 table test).
        for f in stride(from: 20.0, through: 3000, by: 37) {
            XCTAssertEqual(WeightingDesign.responseDB(.a, at: f, sampleRate: fs), WeightingDesign.standardDB(.a, at: f), accuracy: 0.25, "A at \(f)")
            XCTAssertEqual(WeightingDesign.responseDB(.c, at: f, sampleRate: fs), WeightingDesign.standardDB(.c, at: f), accuracy: 0.25, "C at \(f)")
        }
    }

    func testZIsFlat() {
        XCTAssertTrue(WeightingDesign.sections(.z, sampleRate: fs).isEmpty)
    }
}

final class SPLMeterTests: XCTestCase {
    func leq(_ w: Weighting, _ hz: Double) -> Double {
        let m = SPLMeter(sampleRate: fs, weighting: w)
        // Let the filter settle, then measure.
        feed(sine(hz, peakDBFS: -20, seconds: 2)) { m.process($0, count: $1) }
        m.reset()
        feed(sine(hz, peakDBFS: -20, seconds: 2)) { m.process($0, count: $1) }
        return m.reading.leq
    }

    func testSineReadsItsRMS() {
        // -20 dBFS peak sine = -23.01 dBFS RMS, on every weighting at 1 kHz.
        for w in Weighting.allCases { XCTAssertEqual(leq(w, 1000), -23.01, accuracy: 0.05, "\(w)") }
    }

    func testFilteredSignalFollowsTheCurve() {
        XCTAssertEqual(leq(.a, 100), -23.01 - 19.1, accuracy: 0.3)
        XCTAssertEqual(leq(.a, 4000), -23.01 + 1.0, accuracy: 0.3)
        XCTAssertEqual(leq(.c, 31.5), -23.01 - 3.0, accuracy: 0.3)
        XCTAssertEqual(leq(.z, 31.5), -23.01, accuracy: 0.05)
    }

    func testFastAndSlowSettleOnTheSameLevel() {
        let m = SPLMeter(sampleRate: fs, weighting: .z)
        // The C filter overshoots when a tone starts from nothing; LCpeak is read after it settles.
        feed(sine(1000, peakDBFS: -10, seconds: 1)) { m.process($0, count: $1) }
        m.reset()
        feed(sine(1000, peakDBFS: -10, seconds: 8)) { m.process($0, count: $1) }
        XCTAssertEqual(m.reading.fast, -13.01, accuracy: 0.1)
        XCTAssertEqual(m.reading.slow, -13.01, accuracy: 0.1)
        XCTAssertEqual(m.reading.maxFast, -13.01, accuracy: 0.15)
        XCTAssertEqual(m.reading.peakC, -10, accuracy: 0.1)
        XCTAssertEqual(m.reading.seconds, 8, accuracy: 0.001)
    }

    func testDecayRatesAreTheStandards() {
        // After the signal stops: Fast falls 34.7 dB/s, Slow 4.34 dB/s.
        let m = SPLMeter(sampleRate: fs, weighting: .z)
        feed(sine(1000, peakDBFS: -10, seconds: 8)) { m.process($0, count: $1) }
        let f0 = m.reading.fast, s0 = m.reading.slow
        feed([Float](repeating: 0, count: Int(fs / 2))) { m.process($0, count: $1) }
        XCTAssertEqual(f0 - m.reading.fast, 34.7 / 2, accuracy: 0.3)
        XCTAssertEqual(s0 - m.reading.slow, 4.34 / 2, accuracy: 0.1)
    }

    func testSilenceIsMinusInfinityNotANumber() {
        let m = SPLMeter(sampleRate: fs)
        feed([Float](repeating: 0, count: 4800)) { m.process($0, count: $1) }
        XCTAssertEqual(m.reading.leq, -.infinity)
        XCTAssertEqual(m.reading.peakC, -.infinity)
    }

    func testBlockSizeDoesNotChangeTheAnswer() {
        let x = sine(440, peakDBFS: -6, seconds: 1)
        let a = SPLMeter(sampleRate: fs), b = SPLMeter(sampleRate: fs)
        feed(x, block: 64) { a.process($0, count: $1) }
        feed(x, block: 4800) { b.process($0, count: $1) }
        XCTAssertEqual(a.reading.leq, b.reading.leq, accuracy: 0.001)
        XCTAssertEqual(a.reading.fast, b.reading.fast, accuracy: 0.001)
    }
}

final class InputMonitorTests: XCTestCase {
    func testDigitalZeroIsDead() {
        let m = InputMonitor(sampleRate: fs)
        feed([Float](repeating: 0, count: Int(fs * 1.5))) { m.process($0, count: $1) }
        XCTAssertEqual(m.status.state, .dead)
    }

    func testQuietSignalIsPresentWithHeadroom() {
        let m = InputMonitor(sampleRate: fs)
        feed(sine(1000, peakDBFS: -60, seconds: 1)) { m.process($0, count: $1) }
        XCTAssertEqual(m.status.state, .present)
        XCTAssertEqual(m.status.headroomDB, 60, accuracy: 0.1)
        XCTAssertEqual(m.status.clipEvents, 0)
    }

    func testSignalThenUnplugGoesDeadAfterASecond() {
        let m = InputMonitor(sampleRate: fs)
        feed(sine(1000, peakDBFS: -20, seconds: 0.5)) { m.process($0, count: $1) }
        feed([Float](repeating: 0, count: Int(fs * 0.5))) { m.process($0, count: $1) }
        XCTAssertEqual(m.status.state, .present)
        feed([Float](repeating: 0, count: Int(fs * 0.7))) { m.process($0, count: $1) }
        XCTAssertEqual(m.status.state, .dead)
    }

    func testClipIsCountedPerRunAndTheLampHolds() {
        let m = InputMonitor(sampleRate: fs)
        // Two bursts of a sine driven 6 dB over and flat-topped at full scale.
        let hot = sine(100, peakDBFS: 6, seconds: 0.005).map { max(-1, min(1, $0)) }   // half a cycle: one flat top
        let quiet = sine(1000, peakDBFS: -30, seconds: 0.5)
        feed(quiet + hot + quiet + hot + quiet) { m.process($0, count: $1) }
        XCTAssertEqual(m.status.clipEvents, 2)
        XCTAssertEqual(m.status.state, .clipping)
        XCTAssertEqual(m.status.headroomDB, 0, accuracy: 0.01)
        feed(sine(1000, peakDBFS: -30, seconds: 3)) { m.process($0, count: $1) }
        XCTAssertEqual(m.status.state, .present)
        XCTAssertEqual(m.status.clipEvents, 2, "the count stays until reset")
        m.reset()
        XCTAssertEqual(m.status.clipEvents, 0)
    }

    func testPeakHoldStaysThenFalls() {
        let m = InputMonitor(sampleRate: fs)
        feed(sine(1000, peakDBFS: -6, seconds: 0.2)) { m.process($0, count: $1) }
        feed(sine(1000, peakDBFS: -40, seconds: 1.5)) { m.process($0, count: $1) }
        XCTAssertEqual(m.status.peakHoldDB, -6, accuracy: 0.1, "held inside 2 s")
        feed(sine(1000, peakDBFS: -40, seconds: 1.5)) { m.process($0, count: $1) }
        XCTAssertLessThan(m.status.peakHoldDB, -12)
        XCTAssertEqual(m.status.maxPeakDB, -6, accuracy: 0.1, "the maximum never falls")
    }
}

final class ShowFileTests: XCTestCase {
    func testCalibrationOffset() {
        XCTAssertEqual(Calibration.offset(reading: -31.5, targetSPL: 94), 125.5)
        XCTAssertNil(Calibration.offset(reading: -.infinity, targetSPL: 94))
        XCTAssertEqual(Calibration(offsetDB: 125.5, method: .calibrator94).spl(-40), 85.5)
    }

    func testRoundTrip() throws {
        var show = ShowFile()
        show.notes = "main hall ring out"
        show.deviceName = "ZOOM AMS-24 Driver"
        show.weighting = .c
        show.calibrations[ShowFile.calibrationKey(device: show.deviceName, channel: 0)] =
            Calibration(offsetDB: 125.5, method: .calibrator94, date: Date(timeIntervalSince1970: 1_800_000_000), note: "gain at 2 o'clock")
        show.events = [ScopeEvent(date: Date(timeIntervalSince1970: 1_800_000_100), kind: .inputClip, channel: 0, detail: "1 run")]
        show.created = Date(timeIntervalSince1970: 1_800_000_000)
        show.scope.fraction = 3
        show.scope.colorMap = .inferno
        show.scope.floorDB = -80
        let flag = RingFlag(id: 4, time: 12, frequency: 2412, band: 170, thirdOctave: 21, levelDB: -31, neighbourMs: 110,
                            tailMs: 1900, decayMs: 667, slopeDBPerSecond: -30, final: true)
        show.ringLog = [RingLogEntry(flag, date: Date(timeIntervalSince1970: 1_800_000_200))]
        XCTAssertEqual(show.ringLog[0].geqBand, "2.5k")
        XCTAssertEqual(show.ringLog[0].excessMs, 557)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scopekit-\(UUID().uuidString).arcscope")
        defer { try? FileManager.default.removeItem(at: url) }
        try show.save(to: url)
        XCTAssertEqual(try ShowFile.load(from: url), show)
    }

    func testOlderAndNewerFilesStillOpen() throws {
        let json = #"{"version": 9, "notes": "from the future", "weighting": "Q", "somethingNew": [1, 2, 3]}"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let show = try dec.decode(ShowFile.self, from: Data(json.utf8))
        XCTAssertEqual(show.notes, "from the future")
        XCTAssertEqual(show.weighting, .a, "an unknown value falls back, the file still opens")
        XCTAssertEqual(show.sampleRate, 48_000)
        XCTAssertEqual(show.scope, ScopeSettings(), "a file from before the scope gets the defaults")
        let odd = try dec.decode(ShowFile.self, from: Data(#"{"scope": {"fraction": 7, "floorDB": -50, "ceilingDB": -52, "colorMap": "PLAID"}}"#.utf8))
        XCTAssertEqual(odd.scope.fraction, 24)
        XCTAssertEqual(odd.scope.ceilingDB, -44, "the ceiling stays above the floor")
        XCTAssertEqual(odd.scope.colorMap, .smaart)
    }
}
