//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import SwiftData

@Model
final class Show {
    var id: UUID
    var name: String
    var arcNumber: String?
    var date: Date
    var venue: String?
    var notes: String?
    var defaultAnimation: AnimationPreset
    var defaultTemplate: GraphicTemplate
    var keyMode: KeyMode
    @Relationship(deleteRule: .cascade, inverse: \Graphic.show)
    var graphics: [Graphic]
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        arcNumber: String? = nil,
        date: Date = .now,
        venue: String? = nil,
        notes: String? = nil,
        defaultAnimation: AnimationPreset = .slideFromLeft,
        defaultTemplate: GraphicTemplate = .fullWidth,
        keyMode: KeyMode = .lumaKey,
        graphics: [Graphic] = []
    ) {
        self.id = UUID()
        self.name = name
        self.arcNumber = arcNumber
        self.date = date
        self.venue = venue
        self.notes = notes
        self.defaultAnimation = defaultAnimation
        self.defaultTemplate = defaultTemplate
        self.keyMode = keyMode
        self.graphics = graphics
        self.createdAt = .now
        self.updatedAt = .now
    }

    var sortedGraphics: [Graphic] {
        graphics.sorted { $0.sortOrder < $1.sortOrder }
    }

    var graphicCount: Int {
        graphics.count
    }

    func deepCopy() -> Show {
        let copy = Show(
            name: name + " (Copy)",
            arcNumber: arcNumber,
            date: date,
            venue: venue,
            notes: notes,
            defaultAnimation: defaultAnimation,
            defaultTemplate: defaultTemplate,
            keyMode: keyMode
        )
        for graphic in sortedGraphics {
            let gCopy = Graphic(
                line1: graphic.line1,
                line2: graphic.line2,
                line3: graphic.line3,
                animationPreset: graphic.animationPreset,
                accentColor: graphic.accentColor,
                sortOrder: graphic.sortOrder,
                notes: graphic.notes,
                template: graphic.template,
                positionPreset: graphic.positionPreset,
                fontFamily: graphic.fontFamily,
                line1FontSize: graphic.line1FontSize,
                line2FontSize: graphic.line2FontSize,
                line3FontSize: graphic.line3FontSize,
                line1Weight: graphic.line1Weight,
                line2Weight: graphic.line2Weight,
                line3Weight: graphic.line3Weight,
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
                lineSpacing: graphic.lineSpacing,
                cornerRadius: graphic.cornerRadius,
                bottomOffset: graphic.bottomOffset,
                horizontalMargin: graphic.horizontalMargin,
                maxWidthFraction: graphic.maxWidthFraction,
                graphicType: graphic.graphicType,
                layer: graphic.layer,
                tickerSpeed: graphic.tickerSpeed,
                tickerSeparator: graphic.tickerSeparator,
                clockFormat: graphic.clockFormat,
                clockShowSeconds: graphic.clockShowSeconds,
                bugCorner: graphic.bugCorner,
                bugMarginH: graphic.bugMarginH,
                bugMarginV: graphic.bugMarginV,
                hardEdge: graphic.hardEdge,
                shadowEnabled: graphic.shadowEnabled,
                shadowRadius: graphic.shadowRadius,
                shadowOpacity: graphic.shadowOpacity,
                animationInDuration: graphic.animationInDuration,
                animationOutDuration: graphic.animationOutDuration,
                logoPosition: graphic.logoPosition,
                logoSize: graphic.logoSize
            )
            gCopy.logoData = graphic.logoData
            gCopy.logoOffsetX = graphic.logoOffsetX
            gCopy.logoOffsetY = graphic.logoOffsetY
            gCopy.backgroundData = graphic.backgroundData
            gCopy.backgroundScale = graphic.backgroundScale
            gCopy.backgroundImageOpacity = graphic.backgroundImageOpacity
            gCopy.backgroundFitMode = graphic.backgroundFitMode
            gCopy.overlayData = graphic.overlayData
            gCopy.overlayScale = graphic.overlayScale
            gCopy.overlayOpacity = graphic.overlayOpacity
            gCopy.overlayOffsetX = graphic.overlayOffsetX
            gCopy.overlayOffsetY = graphic.overlayOffsetY
            gCopy.customTextOffsetX = graphic.customTextOffsetX
            gCopy.customTextOffsetY = graphic.customTextOffsetY
            gCopy.customTextAlignment = graphic.customTextAlignment
            gCopy.show = copy
            copy.graphics.append(gCopy)
        }
        return copy
    }
}
