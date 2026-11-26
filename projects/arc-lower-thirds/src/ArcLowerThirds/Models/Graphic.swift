//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import SwiftUI
import SwiftData

@Model
final class Graphic {
    var id: UUID
    var line1: String
    var line2: String?
    var line3: String?
    var animationPreset: AnimationPreset
    var accentColor: String  // hex string e.g. "#33D9F5"
    var sortOrder: Int
    var notes: String?

    // Template & positioning
    var template: GraphicTemplate
    var positionPreset: PositionPreset

    // Font customization
    var fontFamily: String?       // nil = system default (SF Pro)
    var line1FontSize: Double
    var line2FontSize: Double
    var line3FontSize: Double
    var line1Weight: FontWeightOption
    var line2Weight: FontWeightOption
    var line3Weight: FontWeightOption

    // Per-line color (nil = use template default: white)
    var line1Color: String?
    var line2Color: String?
    var line3Color: String?

    // Per-line opacity
    var line1Opacity: Double
    var line2Opacity: Double
    var line3Opacity: Double

    // Background & layout
    var backgroundOpacity: Double
    var titleBgColor: String?         // nil = dark gray (#222222)
    var titleBgOpacity: Double        // opacity for title/info section background
    var gradientEnabled: Bool         // enable gradient on accent/bg sections
    var gradientEndColor: String?     // end color for gradient (nil = transparent fade)

    // Per-element sizing
    var accentBarSize: Double         // accent bar thickness (width or height depending on template)
    var namePaddingH: Double          // horizontal padding inside name block
    var namePaddingV: Double          // vertical padding inside name block
    var titlePaddingH: Double         // horizontal padding inside title block
    var titlePaddingV: Double         // vertical padding inside title block
    var elementGap: Double            // gap between name and title sections

    var lineSpacing: Double           // points between text lines
    var cornerRadius: Double          // template corner radius
    var bottomOffset: Double          // distance from bottom of frame
    var horizontalMargin: Double      // side margin for positioned graphics
    var maxWidthFraction: Double      // fraction of screen width (0.3–1.0)

    // Graphic type & layer
    var graphicType: GraphicType     // what kind of graphic (lowerThird, ticker, etc.)
    var layer: GraphicLayer?         // nil = use graphicType.defaultLayer

    // Ticker-specific
    var tickerSpeed: Double          // scroll speed in points/second
    var tickerSeparator: String?     // text between repeats e.g. " /// "

    // Clock-specific
    var clockFormat: String          // DateFormatter format e.g. "h:mm a"
    var clockShowSeconds: Bool       // show seconds in clock display

    // Logo bug-specific (image uses logoData, size uses logoSize)
    var bugCorner: BugCorner         // which corner to position the bug
    var bugMarginH: Double           // horizontal margin from edge
    var bugMarginV: Double           // vertical margin from edge

    // ATEM keying
    var hardEdge: Bool               // disable gradients for clean luma key

    // Text shadow
    var shadowEnabled: Bool
    var shadowRadius: Double
    var shadowOpacity: Double

    // Animation overrides (0 = use preset default)
    var animationInDuration: Double
    var animationOutDuration: Double

    // Logo
    var logoData: Data?
    var logoPosition: LogoPosition
    var logoSize: Double              // height in points
    var logoOffsetX: Double           // X fine-tune from enum position
    var logoOffsetY: Double           // Y fine-tune from enum position

    // Background image layer (behind template content)
    var backgroundData: Data?         // PNG/JPEG stored in SwiftData
    var backgroundScale: Double       // 1.0 = 100%
    var backgroundImageOpacity: Double // 0.0-1.0
    var backgroundFitMode: ImageFitMode

    // Overlay/foreground image layer (on top of template content)
    var overlayData: Data?            // PNG/JPEG decoration
    var overlayScale: Double          // 1.0 = 100%
    var overlayOpacity: Double        // 0.0-1.0
    var overlayOffsetX: Double        // horizontal offset in points
    var overlayOffsetY: Double        // vertical offset in points

    // Custom template text positioning
    var customTextOffsetX: Double     // text block X offset for .custom template
    var customTextOffsetY: Double     // text block Y offset for .custom template
    var customTextAlignment: TextAlignmentOption

    var show: Show?

    init(
        line1: String,
        line2: String? = nil,
        line3: String? = nil,
        animationPreset: AnimationPreset = .slideFromLeft,
        accentColor: String = "#33D9F5",
        sortOrder: Int = 0,
        notes: String? = nil,
        template: GraphicTemplate = .fullWidth,
        positionPreset: PositionPreset = .bottomLeft,
        fontFamily: String? = nil,
        line1FontSize: Double = 48,
        line2FontSize: Double = 36,
        line3FontSize: Double = 28,
        line1Weight: FontWeightOption = .bold,
        line2Weight: FontWeightOption = .medium,
        line3Weight: FontWeightOption = .regular,
        line1Color: String? = nil,
        line2Color: String? = nil,
        line3Color: String? = nil,
        line1Opacity: Double = 1.0,
        line2Opacity: Double = 0.9,
        line3Opacity: Double = 0.75,
        backgroundOpacity: Double = 1.0,
        titleBgColor: String? = nil,
        titleBgOpacity: Double = 0.9,
        gradientEnabled: Bool = false,
        gradientEndColor: String? = nil,
        accentBarSize: Double = 4,
        namePaddingH: Double = 24,
        namePaddingV: Double = 14,
        titlePaddingH: Double = 20,
        titlePaddingV: Double = 14,
        elementGap: Double = 0,
        lineSpacing: Double = 4,
        cornerRadius: Double = 6,
        bottomOffset: Double = 80,
        horizontalMargin: Double = 40,
        maxWidthFraction: Double = 0.65,
        graphicType: GraphicType = .lowerThird,
        layer: GraphicLayer? = nil,
        tickerSpeed: Double = 60,
        tickerSeparator: String? = nil,
        clockFormat: String = "h:mm a",
        clockShowSeconds: Bool = false,
        bugCorner: BugCorner = .topRight,
        bugMarginH: Double = 40,
        bugMarginV: Double = 40,
        hardEdge: Bool = false,
        shadowEnabled: Bool = false,
        shadowRadius: Double = 4,
        shadowOpacity: Double = 0.8,
        animationInDuration: Double = 0,
        animationOutDuration: Double = 0,
        logoPosition: LogoPosition = .left,
        logoSize: Double = 48
    ) {
        self.id = UUID()
        self.line1 = line1
        self.line2 = line2
        self.line3 = line3
        self.animationPreset = animationPreset
        self.accentColor = accentColor
        self.sortOrder = sortOrder
        self.notes = notes
        self.template = template
        self.positionPreset = positionPreset
        self.fontFamily = fontFamily
        self.line1FontSize = line1FontSize
        self.line2FontSize = line2FontSize
        self.line3FontSize = line3FontSize
        self.line1Weight = line1Weight
        self.line2Weight = line2Weight
        self.line3Weight = line3Weight
        self.line1Color = line1Color
        self.line2Color = line2Color
        self.line3Color = line3Color
        self.line1Opacity = line1Opacity
        self.line2Opacity = line2Opacity
        self.line3Opacity = line3Opacity
        self.backgroundOpacity = backgroundOpacity
        self.titleBgColor = titleBgColor
        self.titleBgOpacity = titleBgOpacity
        self.gradientEnabled = gradientEnabled
        self.gradientEndColor = gradientEndColor
        self.accentBarSize = accentBarSize
        self.namePaddingH = namePaddingH
        self.namePaddingV = namePaddingV
        self.titlePaddingH = titlePaddingH
        self.titlePaddingV = titlePaddingV
        self.elementGap = elementGap
        self.lineSpacing = lineSpacing
        self.cornerRadius = cornerRadius
        self.bottomOffset = bottomOffset
        self.horizontalMargin = horizontalMargin
        self.maxWidthFraction = maxWidthFraction
        self.graphicType = graphicType
        self.layer = layer
        self.tickerSpeed = tickerSpeed
        self.tickerSeparator = tickerSeparator
        self.clockFormat = clockFormat
        self.clockShowSeconds = clockShowSeconds
        self.bugCorner = bugCorner
        self.bugMarginH = bugMarginH
        self.bugMarginV = bugMarginV
        self.hardEdge = hardEdge
        self.shadowEnabled = shadowEnabled
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.animationInDuration = animationInDuration
        self.animationOutDuration = animationOutDuration
        self.logoPosition = logoPosition
        self.logoSize = logoSize
        self.logoOffsetX = 0
        self.logoOffsetY = 0
        self.backgroundScale = 1.0
        self.backgroundImageOpacity = 1.0
        self.backgroundFitMode = .fill
        self.overlayScale = 1.0
        self.overlayOpacity = 1.0
        self.overlayOffsetX = 0
        self.overlayOffsetY = 0
        self.customTextOffsetX = 100
        self.customTextOffsetY = 40
        self.customTextAlignment = .leading
    }

    /// Resolved compositing layer (explicit override or type default)
    var effectiveLayer: GraphicLayer {
        layer ?? graphicType.defaultLayer
    }

    /// Number of active text lines (1-3)
    var lineCount: Int {
        var count = 1
        if line2 != nil && !(line2?.isEmpty ?? true) { count += 1 }
        if line3 != nil && !(line3?.isEmpty ?? true) { count += 1 }
        return count
    }

    /// Display label for list views
    var displayLabel: String {
        if let line2, !line2.isEmpty {
            return "\(line1) — \(line2)"
        }
        return line1
    }

    /// Resolved effective in-duration (graphic override or preset default)
    var effectiveInDuration: Double {
        animationInDuration > 0 ? animationInDuration : animationPreset.inDuration
    }

    /// Resolved effective out-duration (graphic override or preset default)
    var effectiveOutDuration: Double {
        animationOutDuration > 0 ? animationOutDuration : animationPreset.outDuration
    }

    /// Resolved color for a given line (custom or white)
    func colorForLine(_ line: Int) -> Color {
        let hex: String?
        switch line {
        case 1: hex = line1Color
        case 2: hex = line2Color
        case 3: hex = line3Color
        default: hex = nil
        }
        guard let hex, !hex.isEmpty else { return .white }
        return ARCTheme.color(from: hex)
    }

    /// Resolved opacity for a given line
    func opacityForLine(_ line: Int) -> Double {
        switch line {
        case 1: return line1Opacity
        case 2: return line2Opacity
        case 3: return line3Opacity
        default: return 1.0
        }
    }

    /// Resolved title section background color
    var resolvedTitleBgColor: Color {
        if let hex = titleBgColor, !hex.isEmpty {
            return ARCTheme.color(from: hex)
        }
        return Color(red: 0.13, green: 0.13, blue: 0.13)  // #222222 default
    }

    /// Resolved gradient end color (nil = gradient disabled)
    var resolvedGradientEndColor: Color? {
        guard gradientEnabled else { return nil }
        if let hex = gradientEndColor, !hex.isEmpty {
            return ARCTheme.color(from: hex)
        }
        return .clear  // gradient enabled, no end color = fade to transparent
    }

    /// Check if any text line has poor contrast against its background
    var hasLegibilityWarning: Bool {
        let bgLum = resolvedTitleBgColor.relativeLuminance
        for line in 1...3 {
            let textLum = colorForLine(line).relativeLuminance
            let ratio = (max(bgLum, textLum) + 0.05) / (min(bgLum, textLum) + 0.05)
            if ratio < 2.0 { return true }
        }
        return false
    }

    /// Resolved font for line 1 (respects custom family, size, weight)
    func fontForLine1(scale: CGFloat = 1.0) -> Font {
        let size = line1FontSize * scale
        let w = line1Weight.fontWeight
        if let family = fontFamily, !family.isEmpty {
            return .custom(family, size: size).weight(w)
        }
        return .system(size: size, weight: w)
    }

    /// Resolved font for line 2
    func fontForLine2(scale: CGFloat = 1.0) -> Font {
        let size = line2FontSize * scale
        let w = line2Weight.fontWeight
        if let family = fontFamily, !family.isEmpty {
            return .custom(family, size: size).weight(w)
        }
        return .system(size: size, weight: w)
    }

    /// Resolved font for line 3
    func fontForLine3(scale: CGFloat = 1.0) -> Font {
        let size = line3FontSize * scale
        let w = line3Weight.fontWeight
        if let family = fontFamily, !family.isEmpty {
            return .custom(family, size: size).weight(w)
        }
        return .system(size: size, weight: w)
    }

    /// Text shadow modifier — concrete return type for use in ternary expressions
    func textShadow(scale: CGFloat = 1.0) -> TextShadowModifier {
        TextShadowModifier(
            enabled: shadowEnabled,
            radius: shadowRadius * scale,
            opacity: shadowOpacity
        )
    }
}

// MARK: - Text Shadow Modifier

struct TextShadowModifier: ViewModifier {
    let enabled: Bool
    let radius: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        if enabled {
            content.shadow(color: .black.opacity(opacity), radius: radius, x: 0, y: radius * 0.5)
        } else {
            content
        }
    }
}

// MARK: - Font Weight Option

enum FontWeightOption: String, Codable, CaseIterable, Identifiable {
    case ultraLight
    case thin
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy
    case black

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ultraLight: return "Ultra Light"
        case .thin: return "Thin"
        case .light: return "Light"
        case .regular: return "Regular"
        case .medium: return "Medium"
        case .semibold: return "Semibold"
        case .bold: return "Bold"
        case .heavy: return "Heavy"
        case .black: return "Black"
        }
    }

    var fontWeight: Font.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

// MARK: - Logo Position

enum LogoPosition: String, Codable, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}
