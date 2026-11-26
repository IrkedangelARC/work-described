//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Captures the visual design properties of a Graphic for save/load as a portable preset.
/// Stored as JSON files in ~/Library/Application Support/ArcLowerThirds/Presets/.
struct DesignPreset: Codable, Identifiable {
    var id: UUID
    var name: String
    var createdAt: Date

    // Template
    var template: String
    var accentColor: String

    // Typography
    var fontFamily: String?
    var line1FontSize: Double
    var line2FontSize: Double
    var line3FontSize: Double
    var line1Weight: String
    var line2Weight: String
    var line3Weight: String
    var lineSpacing: Double

    // Colors
    var line1Color: String?
    var line2Color: String?
    var line3Color: String?
    var line1Opacity: Double
    var line2Opacity: Double
    var line3Opacity: Double
    var backgroundOpacity: Double
    var titleBgColor: String?
    var titleBgOpacity: Double
    var gradientEnabled: Bool
    var gradientEndColor: String?

    // Layout
    var accentBarSize: Double
    var namePaddingH: Double
    var namePaddingV: Double
    var titlePaddingH: Double
    var titlePaddingV: Double
    var elementGap: Double
    var cornerRadius: Double
    var bottomOffset: Double
    var horizontalMargin: Double
    var maxWidthFraction: Double
    var positionPreset: String

    // Effects
    var hardEdge: Bool
    var shadowEnabled: Bool
    var shadowRadius: Double
    var shadowOpacity: Double

    // Logo
    var logoPosition: String
    var logoSize: Double
    var logoOffsetX: Double
    var logoOffsetY: Double
    var logoBase64: String?

    // Background image
    var backgroundBase64: String?
    var backgroundScale: Double
    var backgroundImageOpacity: Double
    var backgroundFitMode: String

    // Overlay image
    var overlayBase64: String?
    var overlayScale: Double
    var overlayOpacity: Double
    var overlayOffsetX: Double
    var overlayOffsetY: Double

    // Custom template
    var customTextOffsetX: Double
    var customTextOffsetY: Double
    var customTextAlignment: String

    /// Create a preset from a Graphic's current visual state.
    static func from(_ graphic: Graphic, name: String) -> DesignPreset {
        DesignPreset(
            id: UUID(),
            name: name,
            createdAt: Date(),
            template: graphic.template.rawValue,
            accentColor: graphic.accentColor,
            fontFamily: graphic.fontFamily,
            line1FontSize: graphic.line1FontSize,
            line2FontSize: graphic.line2FontSize,
            line3FontSize: graphic.line3FontSize,
            line1Weight: graphic.line1Weight.rawValue,
            line2Weight: graphic.line2Weight.rawValue,
            line3Weight: graphic.line3Weight.rawValue,
            lineSpacing: graphic.lineSpacing,
            line1Color: graphic.line1Color,
            line2Color: graphic.line2Color,
            line3Color: graphic.line3Color,
            line1Opacity: graphic.line1Opacity,
            line2Opacity: graphic.line2Opacity,
            line3Opacity: graphic.line3Opacity,
            backgroundOpacity: graphic.backgroundOpacity,
            titleBgColor: graphic.titleBgColor,
            titleBgOpacity: graphic.titleBgOpacity,
            gradientEnabled: graphic.gradientEnabled,
            gradientEndColor: graphic.gradientEndColor,
            accentBarSize: graphic.accentBarSize,
            namePaddingH: graphic.namePaddingH,
            namePaddingV: graphic.namePaddingV,
            titlePaddingH: graphic.titlePaddingH,
            titlePaddingV: graphic.titlePaddingV,
            elementGap: graphic.elementGap,
            cornerRadius: graphic.cornerRadius,
            bottomOffset: graphic.bottomOffset,
            horizontalMargin: graphic.horizontalMargin,
            maxWidthFraction: graphic.maxWidthFraction,
            positionPreset: graphic.positionPreset.rawValue,
            hardEdge: graphic.hardEdge,
            shadowEnabled: graphic.shadowEnabled,
            shadowRadius: graphic.shadowRadius,
            shadowOpacity: graphic.shadowOpacity,
            logoPosition: graphic.logoPosition.rawValue,
            logoSize: graphic.logoSize,
            logoOffsetX: graphic.logoOffsetX,
            logoOffsetY: graphic.logoOffsetY,
            logoBase64: graphic.logoData?.base64EncodedString(),
            backgroundBase64: graphic.backgroundData?.base64EncodedString(),
            backgroundScale: graphic.backgroundScale,
            backgroundImageOpacity: graphic.backgroundImageOpacity,
            backgroundFitMode: graphic.backgroundFitMode.rawValue,
            overlayBase64: graphic.overlayData?.base64EncodedString(),
            overlayScale: graphic.overlayScale,
            overlayOpacity: graphic.overlayOpacity,
            overlayOffsetX: graphic.overlayOffsetX,
            overlayOffsetY: graphic.overlayOffsetY,
            customTextOffsetX: graphic.customTextOffsetX,
            customTextOffsetY: graphic.customTextOffsetY,
            customTextAlignment: graphic.customTextAlignment.rawValue
        )
    }

    /// Apply this preset's visual design to a Graphic, preserving text content.
    func apply(to graphic: Graphic) {
        graphic.template = GraphicTemplate(rawValue: template) ?? .fullWidth
        graphic.accentColor = accentColor
        graphic.fontFamily = fontFamily
        graphic.line1FontSize = line1FontSize
        graphic.line2FontSize = line2FontSize
        graphic.line3FontSize = line3FontSize
        graphic.line1Weight = FontWeightOption(rawValue: line1Weight) ?? .bold
        graphic.line2Weight = FontWeightOption(rawValue: line2Weight) ?? .medium
        graphic.line3Weight = FontWeightOption(rawValue: line3Weight) ?? .regular
        graphic.lineSpacing = lineSpacing
        graphic.line1Color = line1Color
        graphic.line2Color = line2Color
        graphic.line3Color = line3Color
        graphic.line1Opacity = line1Opacity
        graphic.line2Opacity = line2Opacity
        graphic.line3Opacity = line3Opacity
        graphic.backgroundOpacity = backgroundOpacity
        graphic.titleBgColor = titleBgColor
        graphic.titleBgOpacity = titleBgOpacity
        graphic.gradientEnabled = gradientEnabled
        graphic.gradientEndColor = gradientEndColor
        graphic.accentBarSize = accentBarSize
        graphic.namePaddingH = namePaddingH
        graphic.namePaddingV = namePaddingV
        graphic.titlePaddingH = titlePaddingH
        graphic.titlePaddingV = titlePaddingV
        graphic.elementGap = elementGap
        graphic.cornerRadius = cornerRadius
        graphic.bottomOffset = bottomOffset
        graphic.horizontalMargin = horizontalMargin
        graphic.maxWidthFraction = maxWidthFraction
        graphic.positionPreset = PositionPreset(rawValue: positionPreset) ?? .bottomLeft
        graphic.hardEdge = hardEdge
        graphic.shadowEnabled = shadowEnabled
        graphic.shadowRadius = shadowRadius
        graphic.shadowOpacity = shadowOpacity
        graphic.logoPosition = LogoPosition(rawValue: logoPosition) ?? .left
        graphic.logoSize = logoSize
        graphic.logoOffsetX = logoOffsetX
        graphic.logoOffsetY = logoOffsetY
        graphic.logoData = logoBase64.flatMap { Data(base64Encoded: $0) }
        graphic.backgroundData = backgroundBase64.flatMap { Data(base64Encoded: $0) }
        graphic.backgroundScale = backgroundScale
        graphic.backgroundImageOpacity = backgroundImageOpacity
        graphic.backgroundFitMode = ImageFitMode(rawValue: backgroundFitMode) ?? .fill
        graphic.overlayData = overlayBase64.flatMap { Data(base64Encoded: $0) }
        graphic.overlayScale = overlayScale
        graphic.overlayOpacity = overlayOpacity
        graphic.overlayOffsetX = overlayOffsetX
        graphic.overlayOffsetY = overlayOffsetY
        graphic.customTextOffsetX = customTextOffsetX
        graphic.customTextOffsetY = customTextOffsetY
        graphic.customTextAlignment = TextAlignmentOption(rawValue: customTextAlignment) ?? .leading
    }
}
