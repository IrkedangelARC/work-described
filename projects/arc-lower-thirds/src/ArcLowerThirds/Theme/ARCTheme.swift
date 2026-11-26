//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

enum ARCTheme {
    // MARK: - Brand
    static let arcRed = Color(red: 0xC1/255, green: 0x27/255, blue: 0x2D/255)   // #C1272D, the logo red (arc-style/brand/arc_brand.json)

    // MARK: - UI Colors
    static let background = Color(red: 0.07, green: 0.07, blue: 0.08)  // Near-black
    static let surface = Color(red: 0.12, green: 0.12, blue: 0.14)     // Card/panel
    static let surfaceLight = Color(red: 0.18, green: 0.18, blue: 0.20)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.6)
    static let textTertiary = Color(white: 0.4)
    static let accent = Color(red: 0.2, green: 0.851, blue: 0.961)     // Cyan
    static let divider = Color(white: 0.2)

    // MARK: - State Colors
    static let liveRed = Color(red: 1, green: 0.091, blue: 0.267)      // #FF1744 — on-air
    static let readyGreen = Color(red: 0, green: 0.784, blue: 0.325)   // #00C853 — ready

    // MARK: - Lower Third Fonts (stage output — readable on HDMI from across room)
    static let ltLine1 = Font.system(size: 48, weight: .bold)
    static let ltLine2 = Font.system(size: 36, weight: .medium)
    static let ltLine3 = Font.system(size: 28, weight: .regular)

    // MARK: - Operator Fonts
    static let headerBar = Font.system(size: 20, weight: .semibold, design: .monospaced)
    static let bodyText = Font.system(size: 16, weight: .regular)
    static let caption = Font.system(size: 13, weight: .medium)
    static let hotButtonTitle = Font.system(size: 18, weight: .semibold)
    static let hotButtonSubtitle = Font.system(size: 14, weight: .regular)
    static let fireButton = Font.system(size: 28, weight: .heavy)

    // MARK: - Preview Panel Fonts (scaled for 16:9 miniature)
    static let previewLine1 = Font.system(size: 24, weight: .bold)
    static let previewLine2 = Font.system(size: 18, weight: .medium)
    static let previewLine3 = Font.system(size: 14, weight: .regular)

    // MARK: - Spacing
    static let paddingSmall: CGFloat = 8
    static let paddingMedium: CGFloat = 16
    static let paddingLarge: CGFloat = 24
    static let cornerRadius: CGFloat = 12
    static let sidebarWidth: CGFloat = 280

    // MARK: - Lower Third Layout
    static let ltBarWidth: CGFloat = 6          // Accent bar thickness
    static let ltPaddingH: CGFloat = 32         // Horizontal padding inside LT
    static let ltPaddingV: CGFloat = 16         // Vertical padding inside LT
    static let ltBottomOffset: CGFloat = 80     // Distance from bottom of frame
    static let ltMaxWidth: CGFloat = 0.65       // Fraction of screen width

    // MARK: - Editor Layout
    static let inspectorWidth: CGFloat = 320
    static let editorSidebarWidth: CGFloat = 280

    // MARK: - Color Parsing
    static func color(from hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6,
              let value = UInt64(cleaned, radix: 16) else { return accent }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    /// Create a Font with optional custom family, with system fallback.
    static func font(family: String?, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let family, !family.isEmpty {
            return .custom(family, size: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }
}

extension Color {
    /// Approximate relative luminance (sRGB) for contrast checking
    var relativeLuminance: Double {
        let resolved = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linearize(_ v: CGFloat) -> Double {
            v <= 0.03928 ? Double(v) / 12.92 : pow((Double(v) + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }
}
