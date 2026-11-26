import Foundation

/// Data structure for Watch communication
struct WatchData: Codable {
    let overallLevel: Float
    let dominantBandIndex: Int
    let dominantFrequency: Double
    let dominantFrequencyLabel: String
    let hasFeedbackAlert: Bool
}
