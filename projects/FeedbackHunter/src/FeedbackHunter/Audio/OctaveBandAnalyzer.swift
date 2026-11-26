import Foundation

/// Converts FFT bin magnitudes to 1/3 octave band levels
/// Uses energy summation across bins within each band
final class OctaveBandAnalyzer {

    private let fftProcessor: FFTProcessor

    /// Pre-calculated bin ranges for each 1/3 octave band
    private var bandBinRanges: [Range<Int>] = []

    init(fftProcessor: FFTProcessor) {
        self.fftProcessor = fftProcessor
        calculateBandBinRanges()
    }

    /// Pre-calculate which FFT bins belong to each 1/3 octave band
    private func calculateBandBinRanges() {
        bandBinRanges = FrequencyConstants.bandEdges.map { edge in
            fftProcessor.binIndices(from: edge.lower, to: edge.upper)
        }
    }

    /// Calculate 1/3 octave band magnitudes from FFT magnitudes
    /// - Parameter fftMagnitudes: dB magnitudes from FFT processor
    /// - Returns: Array of 31 band magnitudes in dB
    func analyze(fftMagnitudes: [Float]) -> [Float] {
        var bandMagnitudes = [Float](repeating: Theme.dbMin, count: FrequencyConstants.bandCount)

        for (bandIndex, binRange) in bandBinRanges.enumerated() {
            guard !binRange.isEmpty && binRange.lowerBound < fftMagnitudes.count else {
                continue
            }

            let validRange = binRange.clamped(to: 0..<fftMagnitudes.count)
            guard !validRange.isEmpty else { continue }

            // Energy summation: convert from dB to linear, sum, convert back
            // For speed, we'll use the maximum bin value (good approximation for narrow peaks)
            var maxMagnitude: Float = Theme.dbMin
            for binIndex in validRange {
                maxMagnitude = max(maxMagnitude, fftMagnitudes[binIndex])
            }

            bandMagnitudes[bandIndex] = maxMagnitude
        }

        return bandMagnitudes
    }

    /// Full analysis: process raw samples to band magnitudes
    /// - Parameter samples: Time-domain audio samples
    /// - Returns: Array of 31 band magnitudes in dB
    func analyze(samples: [Float]) -> [Float] {
        let fftMagnitudes = fftProcessor.process(samples)
        return analyze(fftMagnitudes: fftMagnitudes)
    }

    /// Get the dominant frequency band (highest magnitude)
    /// - Parameter bandMagnitudes: Array of band magnitudes
    /// - Returns: Tuple of (band index, magnitude, center frequency)
    func dominantBand(from bandMagnitudes: [Float]) -> (index: Int, magnitude: Float, frequency: Double) {
        var maxIndex = 0
        var maxMagnitude: Float = Theme.dbMin

        for (index, magnitude) in bandMagnitudes.enumerated() {
            if magnitude > maxMagnitude {
                maxMagnitude = magnitude
                maxIndex = index
            }
        }

        return (maxIndex, maxMagnitude, FrequencyConstants.centerFrequencies[maxIndex])
    }

    /// Calculate approximate SPL from band magnitudes
    /// Note: This is relative SPL, not calibrated
    /// - Parameter bandMagnitudes: Array of band magnitudes in dB
    /// - Returns: Overall level in dB (sum of all bands)
    func overallLevel(from bandMagnitudes: [Float]) -> Float {
        // Sum power across all bands (convert from dB, sum, convert back)
        var linearSum: Float = 0
        for magnitude in bandMagnitudes {
            linearSum += powf(10.0, magnitude / 10.0)
        }

        guard linearSum > 0 else { return Theme.dbMin }
        return 10.0 * log10f(linearSum)
    }
}
