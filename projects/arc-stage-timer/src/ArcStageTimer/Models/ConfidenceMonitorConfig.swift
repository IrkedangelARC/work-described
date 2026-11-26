//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Operating mode for confidence monitor ATEM integration.
enum ConfidenceMode: String, Codable, CaseIterable, Identifiable {
    /// Transparent fill + key overlay. ATEM DSK keys this over the slide feed.
    case overlay
    /// Opaque surround with PIP zone. ATEM DVE places slide in the designated area.
    case pip

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .overlay: "Overlay"
        case .pip: "PIP"
        }
    }

    var description: String {
        switch self {
        case .overlay: "Timer elements float over slide feed via ATEM downstream key"
        case .pip: "Timer surround with designated area for ATEM PIP/DVE slide"
        }
    }
}

/// Layout template for confidence monitor display.
enum ConfidenceLayout: String, Codable, CaseIterable, Identifiable {
    // Overlay layouts (transparent center)
    case cornerBrackets    // timer in corners with L-bracket frames
    case glassBars         // frosted bars top + bottom
    case sidePanel         // full-height panel on one side
    case minimalCorners    // countdown in one corner, cue info in another

    // PIP layouts (opaque surround with content zone)
    case surroundClassic   // timer top, PIP center, cue + progress bottom
    case surroundWide      // timer panel left, PIP right
    case surroundStack     // compact timer top, large PIP center, info bottom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cornerBrackets: "Corner Brackets"
        case .glassBars: "Glass Bars"
        case .sidePanel: "Side Panel"
        case .minimalCorners: "Minimal"
        case .surroundClassic: "Classic"
        case .surroundWide: "Wide Panel"
        case .surroundStack: "Stacked"
        }
    }

    var isOverlayLayout: Bool {
        switch self {
        case .cornerBrackets, .glassBars, .sidePanel, .minimalCorners: true
        case .surroundClassic, .surroundWide, .surroundStack: false
        }
    }

    /// Layouts available for a given mode
    static func layouts(for mode: ConfidenceMode) -> [ConfidenceLayout] {
        allCases.filter { layout in
            switch mode {
            case .overlay: layout.isOverlayLayout
            case .pip: !layout.isOverlayLayout
            }
        }
    }
}

/// Position for accent bar on confidence monitor frame.
enum AccentBarPosition: String, Codable, CaseIterable, Identifiable {
    case top, bottom, left, right
    var id: String { rawValue }
}

/// Complete configuration for confidence monitor output.
/// Stored as JSON Data on Show model to avoid SwiftData schema complexity.
struct ConfidenceMonitorConfig: Codable, Equatable {
    var isEnabled: Bool = false
    var mode: ConfidenceMode = .overlay
    var layout: ConfidenceLayout = .cornerBrackets

    // PIP zone (normalized 0-1 coordinates within frame)
    var pipZoneX: Double = 0.15
    var pipZoneY: Double = 0.12
    var pipZoneWidth: Double = 0.7
    var pipZoneHeight: Double = 0.55

    // Element visibility
    var showCountdown: Bool = true
    var showCueInfo: Bool = true
    var showProgressBar: Bool = true
    var showOffset: Bool = true
    var showNextCue: Bool = true
    var showMessage: Bool = true
    var showClock: Bool = false

    // Element sizing (1.0 = layout default, 0.5 = half, 2.0 = double)
    var countdownScale: Double = 1.0
    var cueInfoScale: Double = 1.0
    var progressBarScale: Double = 1.0
    var offsetScale: Double = 1.0
    var messageScale: Double = 1.0

    // Global margin multiplier (1.0 = default margins per layout)
    var elementMargin: Double = 1.0

    // Overlay inset — how far from edge toward center (0 = edge, 0.3 = 30% inward)
    var overlayInset: Double = 0.0

    // Accent bar
    var accentBarPosition: AccentBarPosition = .top
    var accentBarSize: Double = 4

    static let `default` = ConfidenceMonitorConfig()
}
