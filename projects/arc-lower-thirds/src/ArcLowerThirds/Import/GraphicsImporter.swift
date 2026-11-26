//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Imports a show with graphics from a JSON file.
/// Expected format matches sample_graphics.json.
enum GraphicsImporter {

    struct ImportedShow: Codable {
        let name: String
        let arcNumber: String?
        let venue: String?
        let defaultAnimation: String?
        let defaultTemplate: String?
        let graphics: [ImportedGraphic]
    }

    struct ImportedGraphic: Codable {
        let line1: String
        let line2: String?
        let line3: String?
        let animation: String?
        let accentColor: String?
        let notes: String?
        let template: String?
        let position: String?
        let fontFamily: String?

        // v2 fields (all optional for backwards compatibility)
        let line1FontSize: Double?
        let line2FontSize: Double?
        let line3FontSize: Double?
        let line1Weight: String?
        let line2Weight: String?
        let line3Weight: String?
        let line1Color: String?
        let line2Color: String?
        let line3Color: String?
        let line1Opacity: Double?
        let line2Opacity: Double?
        let line3Opacity: Double?
        let backgroundOpacity: Double?
        let titleBgColor: String?
        let titleBgOpacity: Double?
        let gradientEnabled: Bool?
        let gradientEndColor: String?
        let accentBarSize: Double?
        let namePaddingH: Double?
        let namePaddingV: Double?
        let titlePaddingH: Double?
        let titlePaddingV: Double?
        let elementGap: Double?
        let lineSpacing: Double?
        let cornerRadius: Double?
        let bottomOffset: Double?
        let horizontalMargin: Double?
        let maxWidthFraction: Double?
        let hardEdge: Bool?
        let shadowEnabled: Bool?
        let shadowRadius: Double?
        let shadowOpacity: Double?
        let animationInDuration: Double?
        let animationOutDuration: Double?
        let logoPosition: String?
        let logoSize: Double?

        // v3 fields: graphic type & layer (Phase 3)
        let graphicType: String?
        let layer: String?
        let tickerSpeed: Double?
        let tickerSeparator: String?
        let clockFormat: String?
        let clockShowSeconds: Bool?
        let bugCorner: String?
        let bugMarginH: Double?
        let bugMarginV: Double?

        // v4 fields: image layers, logo offset, custom text (Phase 4)
        let logoOffsetX: Double?
        let logoOffsetY: Double?
        let backgroundScale: Double?
        let backgroundImageOpacity: Double?
        let backgroundFitMode: String?
        let overlayScale: Double?
        let overlayOpacity: Double?
        let overlayOffsetX: Double?
        let overlayOffsetY: Double?
        let customTextOffsetX: Double?
        let customTextOffsetY: Double?
        let customTextAlignment: String?
    }

    /// Import a Show from JSON data. Does not insert into ModelContext — caller does that.
    static func importShow(from data: Data) throws -> Show {
        let decoder = JSONDecoder()
        let imported = try decoder.decode(ImportedShow.self, from: data)

        let defaultAnim = AnimationPreset(rawValue: imported.defaultAnimation ?? "slideFromLeft") ?? .slideFromLeft
        let defaultTemplate = GraphicTemplate(rawValue: imported.defaultTemplate ?? "fullWidth") ?? .fullWidth

        let show = Show(
            name: imported.name,
            arcNumber: imported.arcNumber,
            venue: imported.venue,
            defaultAnimation: defaultAnim,
            defaultTemplate: defaultTemplate
        )

        for (index, g) in imported.graphics.enumerated() {
            let preset = AnimationPreset(rawValue: g.animation ?? "") ?? defaultAnim
            let template = GraphicTemplate(rawValue: g.template ?? "") ?? defaultTemplate
            let position = PositionPreset(rawValue: g.position ?? "") ?? .bottomLeft

            // Split init to avoid Swift type-checker timeout on 50+ params
            let graphic = Graphic(
                line1: g.line1,
                line2: g.line2,
                line3: g.line3,
                animationPreset: preset,
                accentColor: g.accentColor ?? "#33D9F5",
                sortOrder: index,
                notes: g.notes,
                template: template,
                positionPreset: position,
                fontFamily: g.fontFamily,
                line1FontSize: g.line1FontSize ?? 48,
                line2FontSize: g.line2FontSize ?? 36,
                line3FontSize: g.line3FontSize ?? 28,
                line1Weight: FontWeightOption(rawValue: g.line1Weight ?? "") ?? .bold,
                line2Weight: FontWeightOption(rawValue: g.line2Weight ?? "") ?? .medium,
                line3Weight: FontWeightOption(rawValue: g.line3Weight ?? "") ?? .regular,
                line1Color: g.line1Color,
                line2Color: g.line2Color,
                line3Color: g.line3Color,
                line1Opacity: g.line1Opacity ?? 1.0,
                line2Opacity: g.line2Opacity ?? 0.9,
                line3Opacity: g.line3Opacity ?? 0.75,
                backgroundOpacity: g.backgroundOpacity ?? 1.0,
                titleBgColor: g.titleBgColor,
                titleBgOpacity: g.titleBgOpacity ?? 0.9,
                gradientEnabled: g.gradientEnabled ?? false,
                gradientEndColor: g.gradientEndColor
            )

            // Extended properties (post-init to avoid type-checker timeout)
            graphic.accentBarSize = g.accentBarSize ?? 4
            graphic.namePaddingH = g.namePaddingH ?? 24
            graphic.namePaddingV = g.namePaddingV ?? 14
            graphic.titlePaddingH = g.titlePaddingH ?? 20
            graphic.titlePaddingV = g.titlePaddingV ?? 14
            graphic.elementGap = g.elementGap ?? 0
            graphic.lineSpacing = g.lineSpacing ?? 4
            graphic.cornerRadius = g.cornerRadius ?? 6
            graphic.bottomOffset = g.bottomOffset ?? 80
            graphic.horizontalMargin = g.horizontalMargin ?? 40
            graphic.maxWidthFraction = g.maxWidthFraction ?? 0.65
            graphic.hardEdge = g.hardEdge ?? false
            graphic.shadowEnabled = g.shadowEnabled ?? false
            graphic.shadowRadius = g.shadowRadius ?? 4
            graphic.shadowOpacity = g.shadowOpacity ?? 0.8
            graphic.animationInDuration = g.animationInDuration ?? 0
            graphic.animationOutDuration = g.animationOutDuration ?? 0
            graphic.logoPosition = LogoPosition(rawValue: g.logoPosition ?? "") ?? .left
            graphic.logoSize = g.logoSize ?? 48

            // Phase 3: type & layer properties
            graphic.graphicType = GraphicType(rawValue: g.graphicType ?? "") ?? .lowerThird
            graphic.layer = g.layer.flatMap { GraphicLayer(rawValue: $0) }
            graphic.tickerSpeed = g.tickerSpeed ?? 60
            graphic.tickerSeparator = g.tickerSeparator
            graphic.clockFormat = g.clockFormat ?? "h:mm a"
            graphic.clockShowSeconds = g.clockShowSeconds ?? false
            graphic.bugCorner = BugCorner(rawValue: g.bugCorner ?? "") ?? .topRight
            graphic.bugMarginH = g.bugMarginH ?? 40
            graphic.bugMarginV = g.bugMarginV ?? 40

            // Phase 4: image layers, logo offset, custom text
            graphic.logoOffsetX = g.logoOffsetX ?? 0
            graphic.logoOffsetY = g.logoOffsetY ?? 0
            graphic.backgroundScale = g.backgroundScale ?? 1.0
            graphic.backgroundImageOpacity = g.backgroundImageOpacity ?? 1.0
            graphic.backgroundFitMode = ImageFitMode(rawValue: g.backgroundFitMode ?? "") ?? .fill
            graphic.overlayScale = g.overlayScale ?? 1.0
            graphic.overlayOpacity = g.overlayOpacity ?? 1.0
            graphic.overlayOffsetX = g.overlayOffsetX ?? 0
            graphic.overlayOffsetY = g.overlayOffsetY ?? 0
            graphic.customTextOffsetX = g.customTextOffsetX ?? 100
            graphic.customTextOffsetY = g.customTextOffsetY ?? 40
            graphic.customTextAlignment = TextAlignmentOption(rawValue: g.customTextAlignment ?? "") ?? .leading

            graphic.show = show
            show.graphics.append(graphic)
        }

        return show
    }

    /// Export a Show to JSON data.
    static func exportShow(_ show: Show) throws -> Data {
        let exported = ImportedShow(
            name: show.name,
            arcNumber: show.arcNumber,
            venue: show.venue,
            defaultAnimation: show.defaultAnimation.rawValue,
            defaultTemplate: show.defaultTemplate.rawValue,
            graphics: show.sortedGraphics.map { g in
                ImportedGraphic(
                    line1: g.line1,
                    line2: g.line2,
                    line3: g.line3,
                    animation: g.animationPreset.rawValue,
                    accentColor: g.accentColor,
                    notes: g.notes,
                    template: g.template.rawValue,
                    position: g.positionPreset.rawValue,
                    fontFamily: g.fontFamily,
                    line1FontSize: g.line1FontSize,
                    line2FontSize: g.line2FontSize,
                    line3FontSize: g.line3FontSize,
                    line1Weight: g.line1Weight.rawValue,
                    line2Weight: g.line2Weight.rawValue,
                    line3Weight: g.line3Weight.rawValue,
                    line1Color: g.line1Color,
                    line2Color: g.line2Color,
                    line3Color: g.line3Color,
                    line1Opacity: g.line1Opacity,
                    line2Opacity: g.line2Opacity,
                    line3Opacity: g.line3Opacity,
                    backgroundOpacity: g.backgroundOpacity,
                    titleBgColor: g.titleBgColor,
                    titleBgOpacity: g.titleBgOpacity,
                    gradientEnabled: g.gradientEnabled,
                    gradientEndColor: g.gradientEndColor,
                    accentBarSize: g.accentBarSize,
                    namePaddingH: g.namePaddingH,
                    namePaddingV: g.namePaddingV,
                    titlePaddingH: g.titlePaddingH,
                    titlePaddingV: g.titlePaddingV,
                    elementGap: g.elementGap,
                    lineSpacing: g.lineSpacing,
                    cornerRadius: g.cornerRadius,
                    bottomOffset: g.bottomOffset,
                    horizontalMargin: g.horizontalMargin,
                    maxWidthFraction: g.maxWidthFraction,
                    hardEdge: g.hardEdge,
                    shadowEnabled: g.shadowEnabled,
                    shadowRadius: g.shadowRadius,
                    shadowOpacity: g.shadowOpacity,
                    animationInDuration: g.animationInDuration,
                    animationOutDuration: g.animationOutDuration,
                    logoPosition: g.logoPosition.rawValue,
                    logoSize: g.logoSize,
                    graphicType: g.graphicType.rawValue,
                    layer: g.layer?.rawValue,
                    tickerSpeed: g.tickerSpeed,
                    tickerSeparator: g.tickerSeparator,
                    clockFormat: g.clockFormat,
                    clockShowSeconds: g.clockShowSeconds,
                    bugCorner: g.bugCorner.rawValue,
                    bugMarginH: g.bugMarginH,
                    bugMarginV: g.bugMarginV,
                    logoOffsetX: g.logoOffsetX,
                    logoOffsetY: g.logoOffsetY,
                    backgroundScale: g.backgroundScale,
                    backgroundImageOpacity: g.backgroundImageOpacity,
                    backgroundFitMode: g.backgroundFitMode.rawValue,
                    overlayScale: g.overlayScale,
                    overlayOpacity: g.overlayOpacity,
                    overlayOffsetX: g.overlayOffsetX,
                    overlayOffsetY: g.overlayOffsetY,
                    customTextOffsetX: g.customTextOffsetX,
                    customTextOffsetY: g.customTextOffsetY,
                    customTextAlignment: g.customTextAlignment.rawValue
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(exported)
    }
}
