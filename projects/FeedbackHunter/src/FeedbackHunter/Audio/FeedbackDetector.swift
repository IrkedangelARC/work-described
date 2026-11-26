import Foundation

/// Detects potential feedback frequencies using multiple algorithms:
/// 1. Peak prominence - significantly louder than median
/// 2. Sustained detection - consistent high level over time
/// 3. Trend detection - linear regression for increasing levels
final class FeedbackDetector: ObservableObject {

    // MARK: - Configuration

    /// dB above median to flag as prominent peak
    @Published var prominenceThreshold: Float = 8.0

    /// Time in seconds to consider a peak "sustained"
    @Published var sustainedTimeThreshold: Double = 0.5

    /// Minimum dB increase per second to flag as "increasing"
    @Published var increasingRateThreshold: Float = 3.0

    /// Minimum absolute level to consider (ignore quiet noise)
    @Published var minimumLevelThreshold: Float = -60.0

    /// Maximum variance in dB for a tone to be considered "constant"
    @Published var maxVarianceForConstant: Float = 10.0

    /// Sample rate for timing calculations (updates per second)
    var updateRate: Double = 60.0

    // MARK: - State

    /// Number of samples to keep for sustained detection
    private var samplesForSustained: Int {
        Int(sustainedTimeThreshold * updateRate)
    }

    /// Number of samples for trend detection (last 0.5 seconds)
    private var samplesForTrend: Int {
        Int(0.5 * updateRate)
    }

    // MARK: - Detection

    /// Analyze bands and update feedback flags
    /// - Parameter bands: Array of frequency bands with current magnitudes
    /// - Returns: Updated bands with feedback detection flags
    func analyze(_ bands: [FrequencyBand]) -> [FrequencyBand] {
        var updatedBands = bands

        // Calculate median level across all bands
        let magnitudes = bands.map { $0.magnitude }
        let median = calculateMedian(magnitudes)

        for i in updatedBands.indices {
            let band = updatedBands[i]

            // Reset flags
            updatedBands[i].isSustained = false
            updatedBands[i].isIncreasing = false
            updatedBands[i].isFeedbackAlert = false

            // Skip if below minimum threshold
            guard band.magnitude > minimumLevelThreshold else { continue }

            // Check prominence (significantly above median)
            let isProminent = band.magnitude > (median + prominenceThreshold)

            // Check if sustained (consistent high level)
            let isSustained = checkSustained(history: band.history)
            updatedBands[i].isSustained = isSustained

            // Check if increasing (runaway gain trend)
            let isIncreasing = checkIncreasing(history: band.history)
            updatedBands[i].isIncreasing = isIncreasing

            // Flag as feedback if prominent AND sustained (constant tone for 0.5+ seconds)
            updatedBands[i].isFeedbackAlert = isProminent && isSustained
        }

        return updatedBands
    }

    // MARK: - Sustained Detection

    /// Check if a band has sustained high level
    private func checkSustained(history: [Float]) -> Bool {
        guard history.count >= samplesForSustained else { return false }

        // Check recent samples
        let recentSamples = Array(history.suffix(samplesForSustained))

        // All samples must be above minimum threshold
        let allAboveThreshold = recentSamples.allSatisfy { $0 > minimumLevelThreshold }
        guard allAboveThreshold else { return false }

        // Calculate variance - feedback is consistent, music varies
        let variance = calculateVariance(recentSamples)

        // Low variance indicates sustained constant tone (feedback)
        return variance < maxVarianceForConstant
    }

    // MARK: - Trend Detection

    /// Check if level is increasing (linear regression)
    private func checkIncreasing(history: [Float]) -> Bool {
        guard history.count >= samplesForTrend else { return false }

        let recentSamples = Array(history.suffix(samplesForTrend))

        // Simple linear regression to find slope
        let slope = calculateSlope(recentSamples)

        // Convert slope from dB/sample to dB/second
        let slopePerSecond = slope * Float(updateRate)

        return slopePerSecond > increasingRateThreshold
    }

    // MARK: - Statistics Helpers

    private func calculateMedian(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return Theme.dbMin }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        } else {
            return sorted[mid]
        }
    }

    private func calculateVariance(_ values: [Float]) -> Float {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Float(values.count)
        let squaredDiffs = values.map { ($0 - mean) * ($0 - mean) }
        return squaredDiffs.reduce(0, +) / Float(values.count - 1)
    }

    private func calculateSlope(_ values: [Float]) -> Float {
        guard values.count > 1 else { return 0 }

        let n = Float(values.count)
        var sumX: Float = 0
        var sumY: Float = 0
        var sumXY: Float = 0
        var sumXX: Float = 0

        for (i, y) in values.enumerated() {
            let x = Float(i)
            sumX += x
            sumY += y
            sumXY += x * y
            sumXX += x * x
        }

        let denominator = n * sumXX - sumX * sumX
        guard denominator != 0 else { return 0 }

        return (n * sumXY - sumX * sumY) / denominator
    }
}
