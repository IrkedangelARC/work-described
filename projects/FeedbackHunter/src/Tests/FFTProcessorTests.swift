import XCTest
@testable import FeedbackHunter

final class FFTProcessorTests: XCTestCase {

    var fftProcessor: FFTProcessor!
    var octaveBandAnalyzer: OctaveBandAnalyzer!

    let sampleRate: Double = 48000
    let fftSize: Int = 4096

    override func setUpWithError() throws {
        fftProcessor = FFTProcessor(fftSize: fftSize, sampleRate: sampleRate)
        octaveBandAnalyzer = OctaveBandAnalyzer(fftProcessor: fftProcessor)
    }

    override func tearDownWithError() throws {
        fftProcessor = nil
        octaveBandAnalyzer = nil
    }

    // MARK: - Synthetic Signal Generation

    /// Generate a pure sine wave at a specific frequency
    func generateSineWave(frequency: Double, amplitude: Float = 0.8, sampleCount: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: sampleCount)
        let omega = 2.0 * Double.pi * frequency / sampleRate

        for i in 0..<sampleCount {
            samples[i] = amplitude * Float(sin(omega * Double(i)))
        }

        return samples
    }

    /// Generate multiple sine waves combined
    func generateMultiTone(frequencies: [(frequency: Double, amplitude: Float)], sampleCount: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: sampleCount)

        for (frequency, amplitude) in frequencies {
            let omega = 2.0 * Double.pi * frequency / sampleRate
            for i in 0..<sampleCount {
                samples[i] += amplitude * Float(sin(omega * Double(i)))
            }
        }

        return samples
    }

    // MARK: - FFT Processor Tests

    func testFFTProcessorIdentifiesSingleFrequency() throws {
        // Generate 1kHz tone
        let testFrequency: Double = 1000
        let samples = generateSineWave(frequency: testFrequency, sampleCount: fftSize)

        // Process
        let magnitudes = fftProcessor.process(samples)

        // Find peak bin
        var peakBin = 0
        var peakMagnitude: Float = -Float.greatestFiniteMagnitude
        for (i, mag) in magnitudes.enumerated() {
            if mag > peakMagnitude {
                peakMagnitude = mag
                peakBin = i
            }
        }

        // Calculate detected frequency
        let detectedFrequency = fftProcessor.frequency(for: peakBin)

        // Should be within 1 bin of the expected frequency
        let frequencyResolution = sampleRate / Double(fftSize)
        XCTAssertEqual(detectedFrequency, testFrequency, accuracy: frequencyResolution * 2,
                       "Detected frequency \(detectedFrequency)Hz should be close to \(testFrequency)Hz")

        // Peak should be significantly above noise floor
        XCTAssertGreaterThan(peakMagnitude, -20, "Peak should be above -20 dB")
    }

    func testFFTProcessorIdentifiesMultipleFrequencies() throws {
        // Generate two tones
        let frequencies: [(frequency: Double, amplitude: Float)] = [
            (500, 0.5),
            (2000, 0.5)
        ]
        let samples = generateMultiTone(frequencies: frequencies, sampleCount: fftSize)

        // Process
        let magnitudes = fftProcessor.process(samples)

        // Find peaks (local maxima above threshold)
        var peaks: [(bin: Int, magnitude: Float)] = []
        let threshold: Float = -30

        for i in 1..<(magnitudes.count - 1) {
            if magnitudes[i] > threshold &&
               magnitudes[i] > magnitudes[i-1] &&
               magnitudes[i] > magnitudes[i+1] {
                peaks.append((i, magnitudes[i]))
            }
        }

        // Sort by magnitude
        peaks.sort { $0.magnitude > $1.magnitude }

        // Should find at least 2 significant peaks
        XCTAssertGreaterThanOrEqual(peaks.count, 2, "Should detect at least 2 frequency peaks")

        // Check that peaks are near expected frequencies
        let detectedFreqs = peaks.prefix(2).map { fftProcessor.frequency(for: $0.bin) }
        let expectedFreqs: [Double] = [500, 2000]
        let tolerance = sampleRate / Double(fftSize) * 2

        for expected in expectedFreqs {
            let found = detectedFreqs.contains { abs($0 - expected) < tolerance }
            XCTAssertTrue(found, "Should detect frequency near \(expected)Hz")
        }
    }

    func testFrequencyResolution() throws {
        // Verify frequency resolution calculation
        let expectedResolution = sampleRate / Double(fftSize)
        XCTAssertEqual(fftProcessor.frequencyResolution, expectedResolution, accuracy: 0.001)
    }

    // MARK: - Octave Band Analyzer Tests

    func testOctaveBandAnalyzerIdentifiesBand() throws {
        // Generate 1kHz tone (should appear in the 1kHz band, index 17)
        let samples = generateSineWave(frequency: 1000, sampleCount: fftSize)

        // Analyze
        let bandMagnitudes = octaveBandAnalyzer.analyze(samples: samples)

        // Find dominant band
        let dominant = octaveBandAnalyzer.dominantBand(from: bandMagnitudes)

        // 1kHz should be in band 17 (1000Hz center frequency)
        let expected1kBandIndex = 17
        XCTAssertEqual(dominant.index, expected1kBandIndex,
                       "1kHz tone should peak in band \(expected1kBandIndex), got \(dominant.index)")

        // Verify center frequency
        XCTAssertEqual(FrequencyConstants.centerFrequencies[dominant.index], 1000, accuracy: 1)
    }

    func testOctaveBandCount() throws {
        let samples = generateSineWave(frequency: 440, sampleCount: fftSize)
        let bandMagnitudes = octaveBandAnalyzer.analyze(samples: samples)

        XCTAssertEqual(bandMagnitudes.count, FrequencyConstants.bandCount,
                       "Should have \(FrequencyConstants.bandCount) bands")
    }

    func testOverallLevelCalculation() throws {
        // Full scale sine wave should be near 0 dB
        let samples = generateSineWave(frequency: 1000, amplitude: 1.0, sampleCount: fftSize)
        let bandMagnitudes = octaveBandAnalyzer.analyze(samples: samples)
        let level = octaveBandAnalyzer.overallLevel(from: bandMagnitudes)

        // Should be between -10 and 0 dB for full scale
        XCTAssertGreaterThan(level, -20, "Full scale signal should be above -20 dB")
        XCTAssertLessThan(level, 10, "Level should be below +10 dB")

        // Quiet signal
        let quietSamples = generateSineWave(frequency: 1000, amplitude: 0.01, sampleCount: fftSize)
        let quietBands = octaveBandAnalyzer.analyze(samples: quietSamples)
        let quietLevel = octaveBandAnalyzer.overallLevel(from: quietBands)

        XCTAssertLessThan(quietLevel, level - 30,
                         "Quiet signal should be significantly lower than loud signal")
    }

    // MARK: - Performance Tests

    func testFFTProcessorPerformance() throws {
        let samples = generateSineWave(frequency: 1000, sampleCount: fftSize)

        measure {
            for _ in 0..<100 {
                _ = fftProcessor.process(samples)
            }
        }
    }

    func testFullPipelinePerformance() throws {
        let samples = generateSineWave(frequency: 1000, sampleCount: fftSize)

        measure {
            for _ in 0..<100 {
                _ = octaveBandAnalyzer.analyze(samples: samples)
            }
        }
    }
}
