import Foundation

/// Represents a single 1/3 octave frequency band with current and peak values
struct FrequencyBand: Identifiable {
    let id: Int
    let centerFrequency: Double
    let label: String

    /// Current magnitude in dB (relative to full scale)
    var magnitude: Float = Theme.dbMin

    /// Peak hold value in dB
    var peakMagnitude: Float = Theme.dbMin

    /// Timestamp of last peak
    var peakTime: Date = .distantPast

    /// Whether this band is flagged as potential feedback
    var isFeedbackAlert: Bool = false

    /// Whether this band is showing sustained activity
    var isSustained: Bool = false

    /// Whether this band's level is increasing (runaway gain)
    var isIncreasing: Bool = false

    /// Historical magnitudes for trend detection (last N samples)
    var history: [Float] = []

    /// Maximum history samples to keep (about 2 seconds at 60fps)
    static let maxHistoryCount = 120

    init(id: Int, centerFrequency: Double, label: String) {
        self.id = id
        self.centerFrequency = centerFrequency
        self.label = label
    }

    /// Update magnitude and manage peak hold
    mutating func update(magnitude: Float, at time: Date = Date()) {
        self.magnitude = magnitude

        // Update peak hold
        if magnitude > peakMagnitude {
            peakMagnitude = magnitude
            peakTime = time
        } else if time.timeIntervalSince(peakTime) > Theme.peakHoldTime {
            // Decay peak after hold time
            peakMagnitude = max(magnitude, peakMagnitude - 1.0) // 1dB per update
        }

        // Update history for trend detection
        history.append(magnitude)
        if history.count > Self.maxHistoryCount {
            history.removeFirst()
        }
    }

    /// Reset all values
    mutating func reset() {
        magnitude = Theme.dbMin
        peakMagnitude = Theme.dbMin
        peakTime = .distantPast
        isFeedbackAlert = false
        isSustained = false
        isIncreasing = false
        history.removeAll()
    }
}

/// Alert state for a band
enum BandAlertState {
    case normal
    case caution      // Elevated but not feedback
    case sustained    // Sustained high level
    case feedback     // Active feedback detected
}

extension FrequencyBand {
    var alertState: BandAlertState {
        if isFeedbackAlert { return .feedback }
        if isSustained { return .sustained }
        if isIncreasing { return .caution }
        return .normal
    }
}
