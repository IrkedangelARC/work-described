import XCTest
@testable import ScopeKit

final class TraceTests: XCTestCase {
    func testTraceCoarseBandsAreThePowerSumOfFineOnes() {
        let fine = [Float](repeating: -40, count: 248)
        let t = Trace(name: "T1", slot: 0, thirds: [Float](repeating: -31, count: 31), fine: fine)
        XCTAssertEqual(t.levels(fraction: 24), fine)
        XCTAssertEqual(t.levels(fraction: 3).count, 31)
        let twelfth = t.levels(fraction: 12), sixth = t.levels(fraction: 6)
        XCTAssertEqual(twelfth.count, 124)
        XCTAssertEqual(sixth.count, 62)
        XCTAssertEqual(twelfth[60], -40 + 3.01, accuracy: 0.01)
        XCTAssertEqual(sixth[30], -40 + 6.02, accuracy: 0.01)
    }

    func testMicFileParsesFrdCsvAndHeaders() throws {
        let text = """
        "Sens Factor =-1.2dB, SERNO: 0000000"
        * Freq(Hz)  SPL(dB)  Phase
        20.0\t-2.5\t0
        100, -0.5, 0
        1000;0.30;0
        10000 1.3 0

        20000 -3.7
        """
        let c = try MicCorrection.parse(text, name: "mic")
        XCTAssertEqual(c.frequencies, [20, 100, 1000, 10000, 20000])
        // Relative to 1 kHz, so the level calibration is not moved.
        XCTAssertEqual(c.response(at: 1000), 0, accuracy: 1e-9)
        XCTAssertEqual(c.response(at: 20), -2.8, accuracy: 1e-9)
        XCTAssertEqual(c.correctionDB(at: 10000), -1.0, accuracy: 1e-9)
        XCTAssertEqual(c.correctionDB(at: 5), 2.8, accuracy: 1e-9, "flat beyond the ends")
        // Half way between 1 k and 10 k on a log axis.
        XCTAssertEqual(c.response(at: 3162.28), 0.5, accuracy: 1e-3)
        XCTAssertThrowsError(try MicCorrection.parse("no numbers here", name: "x"))
    }

    func testCorrectionIsHeldToTheLimit() throws {
        let c = try MicCorrection.parse("20 -60\n1000 0\n20000 0", name: "deaf")
        XCTAssertEqual(c.correctionDB(at: 20), MicCorrection.limitDB)
    }

    func testCorrectionFilterMatchesTheCurve() throws {
        let c = try MicCorrection.parse("20 -6\n100 -3\n1000 0\n4000 2\n10000 4\n20000 4", name: "mic")
        let fir = c.fir(sampleRate: fs)
        for hz in [50.0, 100, 1000, 4000, 10000] {
            let x = sine(hz, peakDBFS: -20, seconds: 1)
            let f = FIRFilter(taps: fir)
            var y = [Float](repeating: 0, count: x.count)
            f.process(x, into: &y, count: x.count)
            func rms(_ v: ArraySlice<Float>) -> Double { 10 * log10(Double(v.reduce(0) { $0 + $1 * $1 }) / Double(v.count)) }
            let gain = rms(y[8000...]) - rms(x[8000...])
            XCTAssertEqual(gain, c.correctionDB(at: hz), accuracy: 0.15, "\\(hz) Hz")
        }
    }
}
