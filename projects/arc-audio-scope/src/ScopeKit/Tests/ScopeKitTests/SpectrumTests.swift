//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ScopeKit

let hop = 960   // 20 ms at 48 kHz, the app's slice rate

func db(_ p: Double) -> Double { 10 * log10(max(p, 1e-20)) }

/// Long-term 1/24 band powers of `x` from the MTW analyser, skipping the start-up slices.
func finePowers(_ x: [Float], skip: Int = 40) -> [Double] {
    let an = SpectrumAnalyzer(sampleRate: fs, hop: hop)
    var sum = [Double](repeating: 0, count: an.layout.count)
    var slices = 0
    feed(x) { p, n in
        an.process(p, count: n) { s in
            slices += 1
            if slices > skip { for b in 0..<s.count { sum[b] += Double(s[b]) } }
        }
    }
    return sum.map { $0 / Double(max(slices - skip, 1)) }
}

/// The same, summed to a coarser layout.
func powers(_ x: [Float], fraction: Int) -> [Double] {
    let fine = finePowers(x)
    let k = 24 / fraction
    return (0..<BandLayout(fraction: fraction).count).map { b in (0..<k).reduce(0.0) { $0 + fine[b * k + $1] } }
}

/// Long-term 1/3 octave band powers from the filter bank.
func bankPowers(_ x: [Float], skip: Int = 40) -> [Double] {
    let bank = OctaveFilterBank(sampleRate: fs, hop: hop)
    var sum = [Double](repeating: 0, count: 31)
    var slices = 0
    feed(x) { p, n in
        bank.process(p, count: n) { s in
            slices += 1
            if slices > skip { for b in 0..<s.count { sum[b] += Double(s[b]) } }
        }
    }
    return sum.map { $0 / Double(max(slices - skip, 1)) }
}

final class BandLayoutTests: XCTestCase {
    func testThirdOctaveIsTheGEQ() {
        let l = BandLayout(fraction: 3)
        XCTAssertEqual(l.count, 31)
        XCTAssertEqual(BandLayout.thirdOctaveNames.count, 31)
        XCTAssertEqual(l.centers[0], 19.95, accuracy: 0.01)
        XCTAssertEqual(l.centers[17], 1000, accuracy: 1e-9)
        XCTAssertEqual(l.centers[27], 10_000, accuracy: 1e-6, "base 10: ten bands a decade")
        XCTAssertEqual(l.centers[30], 19_953, accuracy: 1)
        XCTAssertEqual(l.index(of: 1000), 17)
        XCTAssertEqual(l.index(of: 2400), 21)   // the 2.5k fader
        XCTAssertEqual(l.index(of: 5), 0)
        XCTAssertEqual(l.index(of: 30_000), 30)
    }

    func testFinerBandsNestInsideTheGEQBands() {
        let third = BandLayout(fraction: 3)
        for fraction in [6, 12, 24] {
            let l = BandLayout(fraction: fraction)
            XCTAssertEqual(l.count, 31 * fraction / 3)
            for b in 0..<l.count {
                let t = l.thirdOctave(of: b)
                XCTAssertGreaterThanOrEqual(l.lower[b], third.lower[t] * (1 - 1e-12))
                XCTAssertLessThanOrEqual(l.upper[b], third.upper[t] * (1 + 1e-12))
                XCTAssertEqual(l.index(of: l.centers[b]), b)
            }
            XCTAssertEqual(l.position(of: l.frequency(at: 0.37)), 0.37, accuracy: 1e-12)
        }
    }
}

final class SpectrumTests: XCTestCase {
    func testSineLandsInItsBandAtItsRMS() {
        let l24 = BandLayout(fraction: 24), l3 = BandLayout(fraction: 3)
        for hz in [31.0, 50, 180, 1300, 2400, 9500, 15_000] {
            let fine = finePowers(TestSignals.sine(hz, peakDBFS: -20, seconds: 4, sampleRate: fs))
            let top = fine.indices.max { fine[$0] < fine[$1] }!
            XCTAssertLessThanOrEqual(abs(top - l24.index(of: hz)), 1, "1/24 at \(hz) Hz")
            XCTAssertEqual(db(fine.reduce(0, +)), -23.01, accuracy: 0.1, "bands add up at \(hz) Hz")
            let third = (0..<31).map { t in (0..<8).reduce(0.0) { $0 + fine[t * 8 + $1] } }
            XCTAssertEqual(db(third[l3.index(of: hz)]), -23.01, accuracy: 0.25, "1/3 at \(hz) Hz")
        }
    }

    func testAToneBesideAWindowCrossoverStaysWithinOneDB() {
        // 200 Hz, 1 kHz and 4 kHz are where the analysis window changes length. A tone right beside one
        // leaks differently on each side, so the bands no longer add up exactly: the price of MTW.
        for hz in [195.0, 205, 980, 1020, 3900, 4100] {
            let fine = finePowers(TestSignals.sine(hz, peakDBFS: -20, seconds: 4, sampleRate: fs))
            XCTAssertEqual(db(fine.reduce(0, +)), -23.01, accuracy: 1.0, "\(hz) Hz")
        }
    }

    func testWhiteNoiseAddsUpAndRisesThreeDBPerOctave() {
        let x = TestSignals.white(Int(fs * 10)).map { $0 * 0.05 }   // -26.02 dBFS RMS
        let p = powers(x, fraction: 3)
        // The bands span 17.8 Hz to 22.4 kHz of the 24 kHz the noise fills.
        XCTAssertEqual(db(p.reduce(0, +)), -26.02 + db((22_387 - 17.8) / 24_000), accuracy: 0.2)
        XCTAssertEqual(db(p[23]) - db(p[17]), 6.0, accuracy: 0.6)    // 4k against 1k
        XCTAssertEqual(db(p[17]) - db(p[11]), 6.0, accuracy: 0.8)    // 1k against 250
    }

    func testPinkNoiseReadsFlat() {
        let x = TestSignals.pink(Int(fs * 30)).map { $0 * 0.1 }
        for fraction in [3, 24] {
            let l = BandLayout(fraction: fraction)
            let p = powers(x, fraction: fraction).map(db)
            let lo = l.index(of: 40), hi = l.index(of: 12_500)
            let mid = p[lo...hi].sorted()[(hi - lo) / 2]
            // 1/24 bands at the bottom are a few Hz wide: 30 s of noise leaves them a couple of dB of scatter.
            let tolerance = fraction == 3 ? 1.0 : 3.0
            for b in lo...hi { XCTAssertEqual(p[b], mid, accuracy: tolerance, "1/\(fraction) at \(l.centers[b]) Hz") }
        }
    }

    func testWindowsAndLeakAreReported() {
        let an = SpectrumAnalyzer(sampleRate: fs, hop: hop)
        let l = an.layout
        XCTAssertEqual(an.resolution.windowSeconds[l.index(of: 50)], 32_768 / fs, accuracy: 1e-9)
        XCTAssertEqual(an.resolution.windowSeconds[l.index(of: 20_000)], 512 / fs, accuracy: 1e-9)
        // In between, a blend of the two lengths either side of what the band wants.
        XCTAssertEqual(an.resolution.windowSeconds[l.index(of: 2400)], 1_950 / fs, accuracy: 100 / fs)
        XCTAssertEqual(an.resolution.windowSeconds[l.index(of: 8000)], 600 / fs, accuracy: 80 / fs)
        // No frequency where the window jumps: neighbouring bands are within a few percent.
        for b in 1..<l.count {
            let a = an.resolution.windowSeconds[b - 1], z = an.resolution.windowSeconds[b]
            XCTAssertLessThanOrEqual(z, a)
            XCTAssertGreaterThan(z, a * 0.95, "\(l.centers[b]) Hz")
        }
        XCTAssertGreaterThanOrEqual(an.resolution.leakBands[l.index(of: 25)], 4)
        XCTAssertLessThanOrEqual(an.resolution.leakBands[l.index(of: 3000)], 2)
        // Twice the rate, twice the samples: the same window in time.
        let an96 = SpectrumAnalyzer(sampleRate: 96_000, hop: 1920)
        XCTAssertEqual(an96.resolution.windowSeconds, an.resolution.windowSeconds)
    }

    func testBarsSettleHoldPeaksAndRunAverage() {
        let an = SpectrumAnalyzer(sampleRate: fs, hop: hop)
        let third = BandLayout(fraction: 3)
        let avg = BandAverager(bands: 31, sliceInterval: an.sliceInterval)
        var bands = [Float](repeating: 0, count: 31)
        func run(_ x: [Float]) {
            feed(x) { p, n in
                an.process(p, count: n) { s in
                    third.sum(s, from: an.layout, into: &bands)
                    bands.withUnsafeBufferPointer { avg.process($0) }
                }
            }
        }
        run(TestSignals.sine(1300, peakDBFS: -20, seconds: 3, sampleRate: fs))
        XCTAssertEqual(avg.levelsDB[18], -23.01, accuracy: 0.3)
        run([Float](repeating: 0, count: Int(fs)))
        XCTAssertLessThan(avg.levelsDB[18], -45, "FAST lets go")
        XCTAssertEqual(avg.peaksDB[18], -23.01, accuracy: 0.3, "peak holds 2 s")
        XCTAssertEqual(avg.maxDB[18], -23.01, accuracy: 0.3)
        run([Float](repeating: 0, count: Int(fs * 4)))
        XCTAssertLessThan(avg.peaksDB[18], -45, "then falls")
        XCTAssertEqual(avg.maxDB[18], -23.01, accuracy: 0.3, "MAX stays until reset")
        avg.reset()
        avg.averaging = .infinite
        run(TestSignals.sine(1300, peakDBFS: -20, seconds: 2, sampleRate: fs))
        run([Float](repeating: 0, count: Int(fs * 2)))
        // Half the run was the tone: the run average is 3 dB under it (less the window's tail at the start).
        XCTAssertEqual(avg.levelsDB[18], -26.0, accuracy: 0.5)
    }
}

final class OctaveFilterBankTests: XCTestCase {
    /// IEC 61260-1 class 1 limits on relative attenuation, taking the tighter number wherever the
    /// 1995 and 2014 editions (and ANSI S1.11-2004) differ. (octave-band exponent, min dB, max dB)
    static let class1: [(e: Double, min: Double, max: Double)] = [
        (0, -0.3, 0.3), (1.0 / 8, -0.3, 0.4), (1.0 / 4, -0.3, 0.6), (3.0 / 8, -0.3, 1.3), (1.0 / 2, 2.0, 5.0),
        (1, 17.5, .infinity), (2, 42, .infinity), (3, 61, .infinity), (4, 70, .infinity),
    ]

    func testEveryBandMeetsClass1() {
        let g = BandLayout.octaveRatio
        let l = BandLayout(fraction: 3)
        for rate in [44_100.0, 48_000, 96_000] {
            for b in 0..<31 {
                // The rate the band's filter really runs at.
                let rate = OctaveFilterBank.needsOversampling(center: l.centers[b], sampleRate: rate) ? 2 * rate : rate
                for (e, lo, hi) in Self.class1 {
                    // The octave-band breakpoint, scaled to 1/3 octave (IEC 61260-1, 5.10).
                    let high = 1 + (pow(g, 1.0 / 6) - 1) / (pow(g, 0.5) - 1) * (pow(g, e) - 1)
                    for ratio in [high, 1 / high] {
                        let f = l.centers[b] * ratio
                        guard f < 0.5 * rate else { continue }
                        let att = -OctaveFilterDesign.responseDB(center: l.centers[b], at: f, sampleRate: rate)
                        XCTAssertGreaterThanOrEqual(att, lo, "\(BandLayout.thirdOctaveNames[b]) at \(rate): \(att) dB at ratio \(ratio)")
                        XCTAssertLessThanOrEqual(att, hi, "\(BandLayout.thirdOctaveNames[b]) at \(rate): \(att) dB at ratio \(ratio)")
                    }
                }
            }
        }
    }

    func testSineReadsItsRMSInItsBandOnly() {
        for (hz, band) in [(1000.0, 17), (31.62, 2), (100, 7), (10_000, 27)] {
            let p = bankPowers(TestSignals.sine(hz, peakDBFS: -20, seconds: 4, sampleRate: fs), skip: 100).map(db)
            XCTAssertEqual(p[band], -23.01, accuracy: 0.05, "\(hz) Hz")
            // Order 3 Butterworth: 38 dB down two bands away.
            XCTAssertLessThan(p[band - 2], -23.01 - 36, "\(hz) Hz two bands down")
            XCTAssertLessThan(p[band + 2], -23.01 - 36, "\(hz) Hz two bands up")
        }
    }

    func testNoiseAddsUpAndPinkReadsFlat() {
        let white = bankPowers(TestSignals.white(Int(fs * 10)).map { $0 * 0.05 })
        XCTAssertEqual(db(white.reduce(0, +)), -26.02 + db((22_387 - 17.8) / 24_000), accuracy: 0.3)
        let pink = bankPowers(TestSignals.pink(Int(fs * 30)).map { $0 * 0.1 }).map(db)
        let mid = pink[3...28].sorted()[13]
        for b in 3...28 { XCTAssertEqual(pink[b], mid, accuracy: 1.0, BandLayout.thirdOctaveNames[b]) }
    }

    func testFilterBankAndFFTBandsAgree() {
        let x = TestSignals.pink(Int(fs * 30), seed: 5).map { $0 * 0.1 }
        let a = bankPowers(x).map(db), b = powers(x, fraction: 3).map(db)
        for i in 3...29 { XCTAssertEqual(a[i], b[i], accuracy: 0.8, BandLayout.thirdOctaveNames[i]) }
    }

    func testTopBandsRunOversampledAndStillAddUp() {
        let bank = OctaveFilterBank(sampleRate: fs, hop: hop)
        XCTAssertEqual(bank.oversampled.enumerated().filter(\.element).map(\.offset), [28, 29, 30], "12.5k, 16k, 20k at 48 kHz")
        XCTAssertFalse(OctaveFilterBank(sampleRate: 96_000, hop: 1920).oversampled.contains(true))
        // A tone in an oversampled band reads its RMS, and its image above 24 kHz does not come back down.
        let p = bankPowers(TestSignals.sine(15_849, peakDBFS: -20, seconds: 2, sampleRate: fs), skip: 60).map(db)
        XCTAssertEqual(p[29], -23.01, accuracy: 0.05)
        let low = bankPowers(TestSignals.sine(1000, peakDBFS: -20, seconds: 2, sampleRate: fs), skip: 60).map(db)
        XCTAssertLessThan(low[30], -23.01 - 70)
    }
}

final class SpectrumAlignmentTests: XCTestCase {
    /// A click holds every frequency at one instant. It must peak on the same slice in every
    /// window tier: no step in time at 200 Hz, 1 kHz or 4 kHz on the waterfall.
    func testAClickLandsOnTheSameSliceAtEveryFrequency() {
        var x = [Float](repeating: 0, count: Int(fs * 2))
        x[Int(fs)] = 1
        let a = SpectrumAnalyzer(sampleRate: fs, hop: hop)
        var slices: [[Float]] = []
        feed(x) { p, n in a.process(p, count: n) { slices.append(Array($0)) } }
        func peakSlice(_ hz: Double) -> Int {
            let b = a.layout.index(of: hz)
            // The centre of the run of slices within 1 dB of the band's maximum.
            let top = slices.map { $0[b] }.max()!
            let hot = slices.indices.filter { slices[$0][b] > top * 0.8 }
            return (hot.first! + hot.last!) / 2
        }
        let expected = Int((1.0 + a.latencySeconds) / a.sliceInterval)
        for hz in [50.0, 150, 300, 800, 2000, 3500, 6000, 12000] {
            XCTAssertEqual(Double(peakSlice(hz)), Double(expected), accuracy: 1.5, "\(hz) Hz")
        }
    }
}
