import SwiftUI

/// Industrial minimalist color palette
/// "NASA control room, not nightclub"
extension Color {

    // MARK: - Background Colors

    /// Primary background - near black (#0D0D0D)
    static let appBackground = Color(red: 0.051, green: 0.051, blue: 0.051)

    /// Grid and secondary elements (#262626)
    static let gridColor = Color(red: 0.149, green: 0.149, blue: 0.149)

    /// Tertiary/subtle elements (#1A1A1A)
    static let surfaceColor = Color(red: 0.102, green: 0.102, blue: 0.102)

    // MARK: - Bar Colors

    /// Standard bar fill (#666666)
    static let barNormal = Color(red: 0.4, green: 0.4, blue: 0.4)

    /// Peak hold indicator (#FF6619)
    static let barPeak = Color(red: 1.0, green: 0.4, blue: 0.098)

    /// Alert/feedback detected (#FF3333)
    static let barAlert = Color(red: 1.0, green: 0.2, blue: 0.2)

    /// Caution level (approaching feedback) (#FF9933)
    static let barCaution = Color(red: 1.0, green: 0.6, blue: 0.2)

    // MARK: - Text Colors

    /// Primary text - muted white (#B3B3B3)
    static let textPrimary = Color(red: 0.702, green: 0.702, blue: 0.702)

    /// Secondary text - dimmer (#666666)
    static let textSecondary = Color(red: 0.4, green: 0.4, blue: 0.4)

    /// Accent text - for important values (#FFFFFF)
    static let textAccent = Color.white

    // MARK: - SPL Meter Colors

    /// Safe level (green zone)
    static let splSafe = Color(red: 0.2, green: 0.6, blue: 0.2)

    /// Moderate level (yellow zone)
    static let splModerate = Color(red: 0.8, green: 0.7, blue: 0.2)

    /// High level (red zone)
    static let splHigh = Color(red: 0.9, green: 0.2, blue: 0.2)
}

// MARK: - Theme Constants

enum Theme {

    /// Standard animation duration
    static let animationDuration: Double = 0.1

    /// Corner radius for cards/containers
    static let cornerRadius: CGFloat = 8

    /// Standard padding
    static let padding: CGFloat = 16

    /// Compact padding
    static let paddingSmall: CGFloat = 8

    /// Bar spacing in RTA display
    static let barSpacing: CGFloat = 2

    /// Minimum bar width
    static let minBarWidth: CGFloat = 8

    /// Grid line width
    static let gridLineWidth: CGFloat = 0.5

    /// Peak hold decay time in seconds
    static let peakHoldTime: Double = 2.0

    /// dB range for display
    static let dbMin: Float = -60.0
    static let dbMax: Float = 0.0
}
