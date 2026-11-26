import XCTest
@testable import ScopeKit

final class TransferMathTests: XCTestCase {
    private func result(_ phase: (Double) -> Double, magnitude: (Int) -> Float = { _ in 0 }) -> TransferResult {
        let l = BandLayout(fraction: 24)
        var r = TransferResult()
        r.frequencies = l.centers
        r.magnitudeDB = (0..<l.count).map(magnitude)
        r.phaseDegrees = l.centers.map { f in
            let p = phase(f).truncatingRemainder(dividingBy: 360)
            return Float(p > 180 ? p - 360 : p < -180 ? p + 360 : p)
        }
        r.coherence = [Float](repeating: 1, count: l.count)
        r.valid = [Bool](repeating: true, count: l.count)
        return r
    }

    func testUnwrapTurnsADelayBackIntoALine() {
        // 1 ms late: phase = -360 * f * 0.001 degrees. Up to 1 kHz neighbouring points are under half a turn apart.
        let r = result { -360 * $0 * 0.001 }
        let u = r.unwrappedPhase(threshold: 0.3)
        for b in 0..<r.frequencies.count where r.frequencies[b] < 4000 {
            XCTAssertEqual(Double(u[b]), -360 * r.frequencies[b] * 0.001, accuracy: 0.5, "\(r.frequencies[b]) Hz")
        }
    }

    func testUnwrapSkipsUntrustedPoints() {
        var r = result { _ in 20 }
        r.coherence[100] = 0.1
        r.valid[50] = false
        let u = r.unwrappedPhase(threshold: 0.3)
        XCTAssertTrue(u[100].isNaN)
        XCTAssertTrue(u[50].isNaN)
        XCTAssertEqual(u[101], 20, accuracy: 1e-4)
    }

    func testSmoothingKeepsALevelAndCalmsARipple() {
        let flat = result({ _ in 170 }, magnitude: { _ in -6 }).smoothed(fraction: 3)
        XCTAssertEqual(flat.magnitudeDB[120], -6, accuracy: 1e-4)
        XCTAssertEqual(flat.phaseDegrees[120], 170, accuracy: 1e-3)
        let ripple = result({ _ in 0 }, magnitude: { $0 % 2 == 0 ? 3 : -3 })
        XCTAssertEqual(ripple.smoothed(fraction: 24).magnitudeDB[120], ripple.magnitudeDB[120])
        XCTAssertLessThan(abs(ripple.smoothed(fraction: 6).magnitudeDB[120]), 1)
        // A wrap is not averaged into nonsense: +179 and -179 smooth to 180, not 0.
        let wrap = result { Int($0) % 2 == 0 ? 179 : -179 }.smoothed(fraction: 6)
        XCTAssertGreaterThan(abs(wrap.phaseDegrees[120]), 178)
    }
}

final class FlatTopTests: XCTestCase {
    private func run(_ x: [Float]) -> ReferenceClip? {
        let d = FlatTopDetector(sampleRate: fs)
        var found: ReferenceClip?
        feed(x) { p, n in if let r = d.process(p, count: n) { found = found ?? r } }
        return found
    }
    private func sine(_ hz: Double, _ amp: Double, seconds: Double = 2) -> [Float] {
        (0..<Int(fs * seconds)).map { Float(amp * sin(2 * Double.pi * hz * Double($0) / fs)) }
    }
    private func clip(_ x: [Float], _ c: Float) -> [Float] { x.map { min(max($0, -c), c) } }

    func testCleanSignalsAreNotFlagged() {
        for hz in [20.0, 31.5, 50, 100, 440, 1000, 5000, 10_000] {
            XCTAssertNil(run(sine(hz, 0.5)), "\(hz) Hz sine")
            XCTAssertNil(run(sine(hz, 0.05)), "\(hz) Hz quiet sine")
        }
        XCTAssertNil(run(TestSignals.pink(Int(fs * 10)).map { $0 * 0.2 }))
        XCTAssertNil(run(TestSignals.white(Int(fs * 10)).map { $0 * 0.2 }))
        // Low tone under noise: the straight stretch near a peak, without a corner.
        let both = zip(sine(40, 0.4, seconds: 10), TestSignals.pink(Int(fs * 10), seed: 3)).map { $0 + $1 * 0.001 }
        XCTAssertNil(run(both))
    }

    func testClippedTonesAreFoundAtTheirCeiling() {
        for hz in [50.0, 100, 1000] {
            let r = run(clip(sine(hz, 0.5), 0.35))
            XCTAssertNotNil(r, "\(hz) Hz")
            XCTAssertEqual(r?.ceilingDBFS ?? 0, 20 * log10(0.35), accuracy: 0.2, "\(hz) Hz")
        }
    }

    func testClippedProgramIsFound() {
        let x = clip(TestSignals.pink(Int(fs * 10)).map { $0 * 0.3 }, 0.25)
        XCTAssertEqual(run(x)?.ceilingDBFS ?? 0, 20 * log10(0.25), accuracy: 0.3)
    }

    func testClippingBehindACouplingCapacitorIsFound() {
        // The flat tops sag after a 20 Hz high-pass.
        let x = clip(sine(100, 0.5, seconds: 3), 0.3)
        let a = exp(-2 * Double.pi * 20 / fs)
        var y = [Float](repeating: 0, count: x.count), px = 0.0, py = 0.0
        for i in 0..<x.count { let v = a * (py + Double(x[i]) - px); px = Double(x[i]); py = v; y[i] = Float(v) }
        XCTAssertNotNil(run(y))
    }

    func testFullScaleIsLeftToTheInputClipLamp() {
        XCTAssertNil(run(clip(sine(100, 1.5), 1.0)))
    }
}

final class DistortionMonitorTests: XCTestCase {
    func testCoherenceThatFallsWithLevelIsFlagged() {
        let m = DistortionMonitor()
        for _ in 0..<100 { m.add(referenceDB: -30, coherence: 0.95); m.add(referenceDB: -12, coherence: 0.6) }
        XCTAssertEqual(m.verdict?.suspected, true)
        XCTAssertEqual(m.verdict?.loudCoherence ?? 0, 0.6, accuracy: 0.01)
    }

    func testSteadyOrNoisyRoomsAreNot() {
        let good = DistortionMonitor()
        for _ in 0..<100 { good.add(referenceDB: -30, coherence: 0.9); good.add(referenceDB: -12, coherence: 0.93) }
        XCTAssertEqual(good.verdict?.suspected, false)
        // Poor coherence everywhere is a noisy room, not distortion.
        let noisy = DistortionMonitor()
        for _ in 0..<100 { noisy.add(referenceDB: -30, coherence: 0.4); noisy.add(referenceDB: -12, coherence: 0.2) }
        XCTAssertEqual(noisy.verdict?.suspected, false)
        let short = DistortionMonitor()
        for _ in 0..<5 { short.add(referenceDB: -12, coherence: 0.2) }
        XCTAssertNil(short.verdict)
    }

    /// End to end: the same programme through a clean system and through one that clips on the loud passages.
    func testAClippingSystemShowsThroughTheTransferFunction() {
        func verdict(clipAt: Float?) -> DistortionMonitor.Verdict? {
            let seconds = 36, block = Int(fs / 10)
            let noise = TestSignals.pink(Int(fs) * seconds, seed: 9)
            let ref: [Float] = noise.enumerated().map { i, v in v * ((i / Int(fs * 6)) % 2 == 0 ? 0.03 : 0.2) }
            let room = TestSignals.pink(ref.count, seed: 10).map { $0 * 0.0005 }
            let mic = zip(ref, room).map { r, n in (clipAt.map { min(max(r, -$0), $0) } ?? r) + n }
            let tf = TransferFunction(sampleRate: fs)
            tf.averagingSeconds = 1
            let m = DistortionMonitor()
            var level = 0.0
            var i = 0
            while i + block <= ref.count {
                ref.withUnsafeBufferPointer { r in mic.withUnsafeBufferPointer { q in
                    tf.process(reference: r.baseAddress! + i, measurement: q.baseAddress! + i, count: block)
                } }
                let power = Double(ref[i..<(i + block)].reduce(0) { $0 + $1 * $1 }) / Double(block)
                level += 0.1 * (power - level)
                let r = tf.result
                let band = r.frequencies.indices.filter { r.valid[$0] && r.frequencies[$0] >= 200 && r.frequencies[$0] <= 8000 }
                if !band.isEmpty, i > Int(fs * 2) {
                    m.add(referenceDB: 10 * log10(max(level, 1e-12)), coherence: Double(band.map { r.coherence[$0] }.reduce(0, +)) / Double(band.count))
                }
                i += block
            }
            return m.verdict
        }
        XCTAssertEqual(verdict(clipAt: nil)?.suspected, false)
        XCTAssertEqual(verdict(clipAt: 0.06)?.suspected, true)
    }
}

final class RingHarmonicTests: XCTestCase {
    /// A struck note: fundamental with harmonics, all dying slowly after each hit.
    private func scene(_ partials: [(Double, Double)]) -> [Float] {
        var x = TestSignals.ringScene(sampleRate: fs, ringHz: nil)
        for h in 0..<3 {
            let start = Int(fs * (1 + 3 * Double(h)))
            for i in start..<min(x.count, start + Int(fs * 3)) {
                let t = Double(i - start) / fs
                for (hz, amp) in partials { x[i] += Float(amp * pow(10, -3 * t / 2.0) * sin(2 * Double.pi * hz * t)) }
            }
        }
        return x
    }

    func testANoteWithHarmonicsIsNotARing() {
        XCTAssertEqual(detect(scene([(440, 0.05), (880, 0.03), (1320, 0.02)])).flags, [])
    }

    func testTheSameLineAloneIsARing() {
        let flags = detect(scene([(440, 0.05)])).flags.filter { !$0.final }
        XCTAssertGreaterThanOrEqual(flags.count, 2)
        // And with the check off, the note is flagged: the check is what holds it back.
        let off = detect(scene([(440, 0.05), (880, 0.03), (1320, 0.02)]), configure: { $0.harmonicCheck = false }).flags
        XCTAssertFalse(off.isEmpty)
    }

    func testARingWithOneOvertoneIsStillARing() {
        // Feedback through a system that is starting to distort has a second harmonic and no more.
        let flags = detect(scene([(2400, 0.05), (4800, 0.004)])).flags.filter { !$0.final }
        XCTAssertGreaterThanOrEqual(flags.count, 2)
        XCTAssertEqual(flags[0].frequency, 2400, accuracy: 2400 * 0.03)
    }
}

final class ShowFileStep5Tests: XCTestCase {
    func testAFreshShowKeepsTheRigAndDropsTheLogs() throws {
        var s = ShowFile()
        s.deviceName = "ZOOM AMS-24"
        s.calibrations["ZOOM AMS-24 / input 1"] = Calibration(offsetDB: 120, method: .calibrator94)
        s.notes = "Tuesday"
        s.events = [ScopeEvent(kind: .inputClip, channel: 0)]
        s.align.smoothing = 6; s.align.unwrap = true; s.scope.harmonicCheck = false
        var r = TransferResult()
        r.frequencies = [100, 200]; r.magnitudeDB = [1, 2]; r.phaseDegrees = [10, 20]; r.coherence = [0.9, 0.1]; r.valid = [true, true]
        s.transferTraces = [TransferTrace(name: "1", slot: 0, result: r, threshold: 0.3, delaySamples: 12, zeroDB: 1.5)]
        XCTAssertEqual(s.transferTraces[0].trusted, [true, false])
        s.transferTraces[0].date = Date(timeIntervalSince1970: 1_800_000_000)   // the file keeps whole seconds

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scopekit-\(UUID().uuidString).arcscope")
        defer { try? FileManager.default.removeItem(at: dir) }
        try s.save(to: dir)
        let back = try ShowFile.load(from: dir)
        XCTAssertEqual(back.transferTraces, s.transferTraces)
        XCTAssertEqual(back.align.smoothing, 6)
        XCTAssertTrue(back.align.unwrap)
        XCTAssertFalse(back.scope.harmonicCheck)

        let f = s.fresh()
        XCTAssertEqual(f.deviceName, "ZOOM AMS-24")
        XCTAssertEqual(f.calibrations, s.calibrations)
        XCTAssertEqual(f.align, s.align)
        XCTAssertTrue(f.events.isEmpty && f.transferTraces.isEmpty && f.notes.isEmpty)
    }
}

final class RingAnalysisTests: XCTestCase {
    private func floor(_ seconds: Double, _ gain: Float = 0.002) -> [Float] { TestSignals.pink(Int(fs * seconds), seed: 3).map { $0 * gain } }

    func testASteadyLineIsNamedToTheHertzAtItsLevel() {
        var x = floor(4)
        let tone = TestSignals.sine(1003.4, peakDBFS: -27, seconds: 4, sampleRate: fs)     // -30 dBFS RMS
        for i in 0..<x.count { x[i] += tone[i] }
        let c = RingAnalysis.analyze(x, sampleRate: fs).candidates
        XCTAssertEqual(c.first?.frequency ?? 0, 1003.4, accuracy: 0.5)
        XCTAssertEqual(c.first?.levelDB ?? 0, -30, accuracy: 0.5)
        XCTAssertEqual(c.first?.kind, .held)
        XCTAssertGreaterThan(c.first?.presentFraction ?? 0, 0.95)
    }

    func testFeedbackThatBuildsIsCalledGrowingWithItsRate() {
        var x = floor(4)
        let start = Int(fs * 1.2)
        for i in start..<x.count {
            let t = Double(i - start) / fs
            x[i] += Float(0.002 * pow(10, 6 * t / 20) * sin(2 * Double.pi * 3150 * Double(i) / fs))
        }
        let c = RingAnalysis.analyze(x, sampleRate: fs).candidates.first
        XCTAssertEqual(c?.frequency ?? 0, 3150, accuracy: 1)
        XCTAssertEqual(c?.kind, .growing)
        XCTAssertEqual(c?.slopeDBPerSecond ?? 0, 6, accuracy: 1.5)
        XCTAssertEqual(c?.startedSecondsAgo ?? 0, 2.8, accuracy: 0.6)
    }

    func testARingAfterAHitIsCalledDying() {
        let scene = TestSignals.ringScene(sampleRate: fs, hits: 2, gap: 3, ringHz: 2400)
        let x = Array(scene[Int(fs * 0.7)..<Int(fs * 4.7)])       // the first hit is 0.3 s in
        let c = RingAnalysis.analyze(x, sampleRate: fs).candidates.first
        XCTAssertEqual(c?.frequency ?? 0, 2400, accuracy: 3)
        XCTAssertEqual(c?.kind, .dying)
    }

    func testARingStruckAgainInThePeriodIsStillDying() {
        let scene = TestSignals.ringScene(sampleRate: fs, hits: 3, gap: 3, ringHz: 2400)
        for start in [1.5, 2.2, 2.9, 3.2] {                      // the second hit lands early, mid and late in the period
            let x = Array(scene[Int(fs * start)..<Int(fs * (start + 4))])
            let c = RingAnalysis.analyze(x, sampleRate: fs).candidates.first
            XCTAssertEqual(c?.frequency ?? 0, 2400, accuracy: 3, "start \(start)")
            XCTAssertEqual(c?.kind, .dying, "start \(start) slope \(c?.slopeDBPerSecond ?? 0)")
        }
    }

    func testTheLinePointedAtComesFirstEvenWhenQuieter() {
        var x = floor(4)
        for i in 0..<x.count {
            let t = Double(i) / fs
            x[i] += Float(0.05 * sin(2 * Double.pi * 1000 * t) + 0.0006 * sin(2 * Double.pi * 5000 * t))
        }
        XCTAssertEqual(RingAnalysis.analyze(x, sampleRate: fs).candidates.first?.frequency ?? 0, 1000, accuracy: 1)
        XCTAssertEqual(RingAnalysis.analyze(x, sampleRate: fs, focus: 5200).candidates.first?.frequency ?? 0, 5000, accuracy: 2)
        // Pointing where there is nothing leaves the ordinary answer.
        XCTAssertEqual(RingAnalysis.analyze(x, sampleRate: fs, focus: 300).candidates.first?.frequency ?? 0, 1000, accuracy: 1)
    }

    func testALineFarUnderTheRestOfTheSoundIsFaint() {
        var x = floor(4, 0.00002)
        for i in 0..<x.count {
            let t = Double(i) / fs
            x[i] += Float(0.001 * sin(2 * Double.pi * 150 * t) + 0.0006 * sin(2 * Double.pi * 450 * t) + 0.0004 * sin(2 * Double.pi * 300 * t))
            x[i] += Float(0.00002 * sin(2 * Double.pi * 4180 * t))        // a whine 30 dB under the hum's third harmonic
        }
        let all = RingAnalysis.analyze(x, sampleRate: fs, limit: 8).candidates
        let whine = all.first { abs($0.frequency - 4180) < 5 }
        XCTAssertEqual(whine?.faint, true, "\(all)")
        XCTAssertFalse(RingAnalysis.advice(whine!).cut)
        // A ring that is quiet next to the hit before it, but clear once the hit has passed, is not faint.
        let scene = TestSignals.ringScene(sampleRate: fs, hits: 2, gap: 3, ringHz: 2400)
        XCTAssertEqual(RingAnalysis.analyze(Array(scene[Int(fs * 0.1)..<Int(fs * 4.1)]), sampleRate: fs).candidates.first?.faint, false)
    }

    func testAdviceNamesTheFaderAndLeavesNotesAlone() {
        func c(_ f: Double, _ kind: RingAnalysis.Kind) -> RingAnalysis.Candidate {
            .init(frequency: f, levelDB: -40, prominenceDB: 20, slopeDBPerSecond: 0, presentFraction: 1, heardSeconds: 4, startedSecondsAgo: 4, kind: kind)
        }
        let on = RingAnalysis.advice(c(2500, .held))
        XCTAssertTrue(on.cut)
        XCTAssertEqual(BandLayout.thirdOctaveNames[on.thirdOctave], "2.5k")
        XCTAssertFalse(on.betweenFaders)
        XCTAssertTrue(RingAnalysis.advice(c(2250, .growing)).betweenFaders)
        XCTAssertFalse(RingAnalysis.advice(c(440, .note)).cut)
    }

    func testANoteGoesBehindALineWithNoHarmonics() {
        var x = floor(4)
        for i in 0..<x.count {
            let t = Double(i) / fs
            for (h, a) in [(1.0, 0.05), (2.0, 0.03), (3.0, 0.02), (4.0, 0.01)] { x[i] += Float(a * sin(2 * Double.pi * 220 * h * t)) }
            x[i] += Float(0.004 * sin(2 * Double.pi * 2500 * t))
        }
        let c = RingAnalysis.analyze(x, sampleRate: fs, limit: 6).candidates
        XCTAssertEqual(c.first?.frequency ?? 0, 2500, accuracy: 1, "\(c)")
        XCTAssertNotEqual(c.first?.kind, .note)
        XCTAssertTrue(c.dropFirst().allSatisfy { $0.kind == .note }, "\(c)")
        XCTAssertTrue(c.contains { abs($0.frequency - 220) < 1 })
    }

    func testNoiseAloneNamesNothingAndOldShowFilesStillOpen() throws {
        XCTAssertEqual(RingAnalysis.analyze(floor(4, 0.05), sampleRate: fs).candidates, [])
        XCTAssertEqual(RingAnalysis.analyze([Float](repeating: 0, count: 1000), sampleRate: fs).candidates, [])
        let c = RingAnalysis.Candidate(frequency: 800, levelDB: -40, prominenceDB: 30, slopeDBPerSecond: -10, presentFraction: 0.5,
                                       heardSeconds: 2, startedSecondsAgo: 3, kind: .dying)
        let entry = RingLogEntry(marked: c, band: 128, thirdOctave: 16, date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(entry.marked)
        XCTAssertEqual(entry.decayMs ?? 0, 2000, accuracy: 1)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
        for key in ["manual", "verdict", "slopeDBPerSecond"] { json[key] = nil }
        let old = try JSONDecoder().decode(RingLogEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.marked)
        XCTAssertNil(old.verdict)
    }
}

final class WAVTests: XCTestCase {
    func testHeaderSizesAndSamples() {
        let d = WAV.data([0, 0.5, -1, 2], sampleRate: 48_000, bits: 24)
        XCTAssertEqual(d.count, 44 + 12)
        XCTAssertEqual(String(decoding: d[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: d[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(d[24...27].reversed().reduce(0) { $0 << 8 | Int($1) }, 48_000)
        XCTAssertEqual(Int(d[34]), 24)
        XCTAssertEqual(d[40...43].reversed().reduce(0) { $0 << 8 | Int($1) }, 12)
        func sample(_ i: Int) -> Int { let b = 44 + i * 3; let v = Int(d[b]) | Int(d[b + 1]) << 8 | Int(d[b + 2]) << 16; return v >= 1 << 23 ? v - (1 << 24) : v }
        XCTAssertEqual(sample(0), 0)
        XCTAssertEqual(sample(1), 4_194_304, accuracy: 1)
        XCTAssertEqual(sample(2), -8_388_607)
        XCTAssertEqual(sample(3), 8_388_607, "past full scale is clipped")
        XCTAssertEqual(WAV.normalizingGain([0.001, -0.007]), 100, accuracy: 0.01)
        XCTAssertEqual(WAV.normalizingGain([0, 0]), 1)
    }
}

final class AxisZoomTests: XCTestCase {
    func testTheWindowStaysOnTheAxisAndKeepsItsWidth() {
        var s = ScopeSettings()
        XCTAssertFalse(s.zoomed)
        s.axisLo = 0.8; s.axisHi = 1.3          // dragged off the top end
        s.clampAxis()
        XCTAssertEqual(s.axisLo, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.axisHi, 1.0, accuracy: 1e-9)
        s.axisLo = 0.40; s.axisHi = 0.41        // pinched past one octave
        s.clampAxis()
        XCTAssertEqual(s.axisHi - s.axisLo, ScopeSettings.minimumAxisSpan, accuracy: 1e-9)
        XCTAssertTrue(s.zoomed)
        s.axisLo = -2; s.axisHi = 5
        s.clampAxis()
        XCTAssertEqual([s.axisLo, s.axisHi], [0, 1])
    }
}

final class ExportTests: XCTestCase {
    func testCSVQuotesWhatNeedsIt() {
        XCTAssertEqual(Export.csv([["a", "b,c", "say \"hi\""]]), "a,\"b,c\",\"say \"\"hi\"\"\"\r\n")
    }

    func testSpectrumAndLogsHaveOneRowPerItem() {
        let l = BandLayout(fraction: 3)
        var levels = [Float](repeating: -50, count: 31)
        levels[0] = -160
        let s = Export.spectrum(layout: l, unit: "dBFS", columns: [("live", levels)]).split(separator: "\r\n")
        XCTAssertEqual(s.count, 32)
        XCTAssertEqual(s[0], "Hz,live (dBFS)")
        XCTAssertTrue(s[1].hasSuffix(","), "an empty band is left blank")
        XCTAssertTrue(s[18].hasPrefix("1000.00,-50.00"))
        let e = Export.events([ScopeEvent(kind: .referenceClip, channel: 1, detail: "ceiling -9.1 dBFS, 4 flat tops")]).split(separator: "\r\n")
        XCTAssertEqual(e.count, 2)
        XCTAssertTrue(e[1].contains("referenceClip,2,\"ceiling -9.1 dBFS, 4 flat tops\""))
    }
}
