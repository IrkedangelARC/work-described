//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

// MARK: - Progress Bar Visual Style

enum ProgressBarStyle {
    case segmented   // Colored zone backgrounds + boundary markers (ARC Default)
    case solid       // Single-color fill on dark track, no zones (High Contrast)
    case thinLine    // Minimal thin bar, no zones (Broadcast)
    case hidden      // No progress bar visible (Low Light)
}

enum ProgressBarPosition {
    case bottom      // Below countdown (default)
    case top         // Above cue info (broadcast feel)
}

/// Selectable visual preset for the timer display.
/// Each preset defines a distinct font, color palette, progress style, and layout.
enum DisplayColorScheme: String, CaseIterable, Identifiable, Codable {
    case arcDefault
    case highContrast
    case broadcast
    case warmAmber
    case daylight
    case paper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .arcDefault: "ARC Default"
        case .highContrast: "High Contrast"
        case .broadcast: "Broadcast"
        case .warmAmber: "Low Light"
        case .daylight: "Daylight"
        case .paper: "Paper"
        }
    }

    var description: String {
        switch self {
        case .arcDefault: "Monospaced · Green/Yellow/Red · Dark"
        case .highContrast: "Bold · White/Amber/Red · Dark · Giant countdown"
        case .broadcast: "Rounded · Blue/Gold/Magenta · Dark"
        case .warmAmber: "Serif · Teal/Amber/Orange · Dark · Minimal"
        case .daylight: "Dark text on white · High ambient light"
        case .paper: "Rounded · Dark text on warm white · Conference"
        }
    }

    // MARK: - Light vs Dark

    var isLightBackground: Bool {
        switch self {
        case .daylight, .paper: true
        default: false
        }
    }

    /// Base background color for the stage display
    var stageBackground: Color {
        switch self {
        case .daylight: .white
        case .paper: Color(red: 0.980, green: 0.973, blue: 0.961)  // #FAF8F5 warm off-white
        default: .black
        }
    }

    // MARK: - Stage Text Colors (for CueInfoPanel, messages, offset)

    var textPrimary: Color {
        switch self {
        case .daylight: .black
        case .paper: Color(red: 0.03, green: 0.03, blue: 0.05)
        default: .white
        }
    }

    var textSecondary: Color {
        switch self {
        case .daylight: Color(white: 0.10)
        case .paper: Color(white: 0.12)
        default: Color(white: 0.75)
        }
    }

    var textTertiary: Color {
        switch self {
        case .daylight: Color(white: 0.22)
        case .paper: Color(white: 0.25)
        default: Color(white: 0.55)
        }
    }

    /// Who is speaking, on the stage screen. It was cyan, which is nobody's brand; ARC red on a dark ground,
    /// and a dark ARC red on the two light schemes so it still passes contrast on a lit stage.
    var stageAccent: Color {
        switch self {
        case .daylight, .paper: Color(red: 0x8C / 255, green: 0x0B / 255, blue: 0x20 / 255)   // ARC red, darkened for white grounds
        case .broadcast: Color(red: 0xE0 / 255, green: 0x91 / 255, blue: 0x43 / 255)          // amber: red belongs to the keyer on a broadcast feed
        default: ARCTheme.arcRed
        }
    }

    // MARK: - Font

    var fontDesign: Font.Design {
        switch self {
        case .arcDefault: .monospaced
        case .highContrast: .default
        case .broadcast: .rounded
        case .warmAmber: .serif
        case .daylight: .default
        case .paper: .rounded
        }
    }

    var countdownWeight: Font.Weight {
        switch self {
        case .arcDefault: .light
        case .highContrast: .heavy
        case .broadcast: .medium
        case .warmAmber: .ultraLight
        case .daylight: .semibold
        case .paper: .light
        }
    }

    var titleWeight: Font.Weight {
        switch self {
        case .arcDefault: .semibold
        case .highContrast: .bold
        case .broadcast: .semibold
        case .warmAmber: .light
        case .daylight: .bold
        case .paper: .medium
        }
    }

    var subtitleWeight: Font.Weight {
        switch self {
        case .arcDefault: .regular
        case .highContrast: .semibold
        case .broadcast: .regular
        case .warmAmber: .thin
        case .daylight: .medium
        case .paper: .regular
        }
    }

    var speakersWeight: Font.Weight {
        switch self {
        case .arcDefault: .medium
        case .highContrast: .semibold
        case .broadcast: .medium
        case .warmAmber: .light
        case .daylight: .semibold
        case .paper: .medium
        }
    }

    // MARK: - Timer State Colors

    var nominal: Color {
        switch self {
        case .arcDefault: Color(red: 0, green: 0.784, blue: 0.325)       // #00C853
        case .highContrast: .white
        case .broadcast: Color(red: 0.267, green: 0.541, blue: 1.0)      // #448AFF
        case .warmAmber: Color(red: 0.149, green: 0.651, blue: 0.604)    // #26A69A
        case .daylight: Color(red: 0.180, green: 0.490, blue: 0.196)     // #2E7D32 deep green
        case .paper: Color(red: 0.157, green: 0.220, blue: 0.576)        // #283593 deep indigo
        }
    }

    var warning: Color {
        switch self {
        case .arcDefault: Color(red: 1, green: 0.839, blue: 0)           // #FFD600
        case .highContrast: Color(red: 1, green: 0.671, blue: 0)         // #FFAB00
        case .broadcast: Color(red: 1, green: 0.843, blue: 0.251)        // #FFD740
        case .warmAmber: Color(red: 1, green: 0.702, blue: 0)            // #FFB300
        case .daylight: Color(red: 0.902, green: 0.318, blue: 0)         // #E65100 dark amber
        case .paper: Color(red: 0.749, green: 0.212, blue: 0.047)        // #BF360C burnt orange
        }
    }

    var danger: Color {
        switch self {
        case .arcDefault: Color(red: 1, green: 0.091, blue: 0.267)       // #FF1744
        case .highContrast: Color(red: 1, green: 0.091, blue: 0.267)     // #FF1744
        case .broadcast: Color(red: 1, green: 0.251, blue: 0.506)        // #FF4081
        case .warmAmber: Color(red: 1, green: 0.239, blue: 0)            // #FF3D00
        case .daylight: Color(red: 0.776, green: 0.157, blue: 0.157)     // #C62828 dark red
        case .paper: Color(red: 0.678, green: 0.078, blue: 0.341)        // #AD1457 crimson
        }
    }

    var idle: Color {
        switch self {
        case .highContrast: .white.opacity(0.5)
        case .daylight: Color(white: 0.6)
        case .paper: Color(white: 0.65)
        default: .gray
        }
    }

    // MARK: - Background Tint

    var backgroundOpacity: Double {
        switch self {
        case .arcDefault: 0.08
        case .highContrast: 0.02
        case .broadcast: 0.12
        case .warmAmber: 0.04
        case .daylight: 0.03
        case .paper: 0.025
        }
    }

    var overtimeBackgroundOpacity: Double {
        switch self {
        case .arcDefault: 0.15
        case .highContrast: 0.04
        case .broadcast: 0.20
        case .warmAmber: 0.08
        case .daylight: 0.05
        case .paper: 0.04
        }
    }

    // MARK: - Progress Bar

    var progressStyle: ProgressBarStyle {
        switch self {
        case .arcDefault: .segmented
        case .highContrast: .solid
        case .broadcast: .thinLine
        case .warmAmber: .hidden
        case .daylight: .solid
        case .paper: .thinLine
        }
    }

    var progressPosition: ProgressBarPosition {
        switch self {
        case .broadcast: .top
        default: .bottom
        }
    }

    var progressCornerRadius: CGFloat {
        switch self {
        case .arcDefault: 2        // ARC Style: small radii, like the console modules
        case .highContrast: 4
        case .broadcast: 1
        case .warmAmber: 8
        case .daylight: 6
        case .paper: 2
        }
    }

    /// The hairline round the progress track (ARC Style, 2026-09-17). Light grounds get a dark one.
    var progressHairline: Color {
        isLightBackground ? Color.black.opacity(0.25) : Color.white.opacity(0.22)
    }

    /// Track fill for progress bar (light bg needs dark track, dark bg needs light track)
    var progressTrackColor: Color {
        isLightBackground ? Color.black.opacity(0.08) : Color.white.opacity(0.1)
    }

    // MARK: - Layout Fractions (must sum to 1.0)

    var layoutCueInfoFraction: CGFloat {
        switch self {
        case .arcDefault: 0.32
        case .highContrast: 0.25
        case .broadcast: 0.35
        case .warmAmber: 0.29
        case .daylight: 0.31
        case .paper: 0.33
        }
    }

    var layoutCountdownFraction: CGFloat {
        switch self {
        case .arcDefault: 0.48
        case .highContrast: 0.60
        case .broadcast: 0.40
        case .warmAmber: 0.56
        case .daylight: 0.52
        case .paper: 0.44
        }
    }

    var layoutProgressFraction: CGFloat {
        switch self {
        case .arcDefault: 0.05
        case .highContrast: 0.06
        case .broadcast: 0.02
        case .warmAmber: 0.0
        case .daylight: 0.05
        case .paper: 0.03
        }
    }

    var layoutOffsetFraction: CGFloat {
        switch self {
        case .arcDefault: 0.15
        case .highContrast: 0.09
        case .broadcast: 0.23
        case .warmAmber: 0.15
        case .daylight: 0.12
        case .paper: 0.20
        }
    }

    // MARK: - Drop Shadows (light backgrounds only, 8 o'clock angle)

    var textShadowColor: Color {
        switch self {
        case .daylight: Color(white: 0.385)
        case .paper: Color(white: 0.392)
        default: .clear
        }
    }

    var elementShadowColor: Color {
        switch self {
        case .daylight: Color(white: 0.35)
        case .paper: Color(white: 0.364)
        default: .clear
        }
    }

    var textShadowRadius: CGFloat { 10 }
    var textShadowX: CGFloat { -6 }
    var textShadowY: CGFloat { 4 }

    var elementShadowRadius: CGFloat { 14 }
    var elementShadowX: CGFloat { -8 }
    var elementShadowY: CGFloat { 5 }

    // MARK: - Outline Text (High Contrast preset)

    var isOutlineText: Bool {
        switch self {
        case .highContrast: true
        default: false
        }
    }

    /// Outline width as fraction of font size (2.5% → 5pt on 200pt font)
    var outlineWidthFraction: CGFloat { 0.025 }

    var countdownHorizontalPadding: CGFloat {
        switch self {
        case .arcDefault: 20
        case .highContrast: 10
        case .broadcast: 40
        case .warmAmber: 60
        case .daylight: 20
        case .paper: 40
        }
    }
}

// MARK: - Environment Key

private struct DisplayColorSchemeKey: EnvironmentKey {
    static let defaultValue: DisplayColorScheme = .arcDefault
}

extension EnvironmentValues {
    var displayColorScheme: DisplayColorScheme {
        get { self[DisplayColorSchemeKey.self] }
        set { self[DisplayColorSchemeKey.self] = newValue }
    }
}

// MARK: - Text Outline Modifier (sharp stroke via multi-directional shadows)

extension View {
    @ViewBuilder
    func textOutline(color: Color, width: CGFloat) -> some View {
        if width > 0 {
            let d = width * 0.707
            self
                .shadow(color: color, radius: 0, x: width, y: 0)
                .shadow(color: color, radius: 0, x: -width, y: 0)
                .shadow(color: color, radius: 0, x: 0, y: width)
                .shadow(color: color, radius: 0, x: 0, y: -width)
                .shadow(color: color, radius: 0, x: d, y: d)
                .shadow(color: color, radius: 0, x: -d, y: d)
                .shadow(color: color, radius: 0, x: d, y: -d)
                .shadow(color: color, radius: 0, x: -d, y: -d)
        } else {
            self
        }
    }
}
