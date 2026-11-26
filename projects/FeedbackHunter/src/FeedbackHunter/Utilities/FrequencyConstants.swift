import Foundation

/// ISO 266 1/3 octave center frequencies (20Hz - 20kHz)
/// 31 bands standard for professional audio analysis
enum FrequencyConstants {

    /// 1/3 octave center frequencies in Hz
    static let centerFrequencies: [Double] = [
        20.0, 25.0, 31.5, 40.0, 50.0, 63.0, 80.0, 100.0, 125.0, 160.0,
        200.0, 250.0, 315.0, 400.0, 500.0, 630.0, 800.0, 1000.0, 1250.0, 1600.0,
        2000.0, 2500.0, 3150.0, 4000.0, 5000.0, 6300.0, 8000.0, 10000.0, 12500.0, 16000.0,
        20000.0
    ]

    /// Display labels for each band
    static let frequencyLabels: [String] = [
        "20", "25", "31.5", "40", "50", "63", "80", "100", "125", "160",
        "200", "250", "315", "400", "500", "630", "800", "1k", "1.25k", "1.6k",
        "2k", "2.5k", "3.15k", "4k", "5k", "6.3k", "8k", "10k", "12.5k", "16k",
        "20k"
    ]

    /// Number of 1/3 octave bands
    static let bandCount = 31

    /// 1/3 octave bandwidth factor (2^(1/6))
    static let bandwidthFactor: Double = 1.12246204830937

    /// Calculate lower edge frequency for a center frequency
    static func lowerEdge(for centerFreq: Double) -> Double {
        return centerFreq / bandwidthFactor
    }

    /// Calculate upper edge frequency for a center frequency
    static func upperEdge(for centerFreq: Double) -> Double {
        return centerFreq * bandwidthFactor
    }

    /// Get band edges for all 31 bands
    static var bandEdges: [(lower: Double, center: Double, upper: Double)] {
        centerFrequencies.map { center in
            (lower: lowerEdge(for: center), center: center, upper: upperEdge(for: center))
        }
    }
}
