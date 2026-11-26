//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Dispatches rendering to the correct template view based on the graphic's template type.
/// Used by both StageOutputView (full resolution) and editor canvas (scaled).
///
/// Composites three layers: background image → template content → overlay image.
/// When `isMatte` is true, templates render white silhouettes on black for the
/// ATEM linear key signal (Fill + Key mode).
struct TemplateRendererView: View {
    let graphic: Graphic
    var scale: CGFloat = 1.0
    var isMatte: Bool = false
    var reportBounds: Bool = false

    var body: some View {
        // Template content drives layout size.
        // Background/overlay use .background/.overlay so they don't expand the frame.
        templateContent
            .background { backgroundLayer }
            .overlay { overlayLayer }
    }

    // MARK: - Template Dispatch

    @ViewBuilder
    private var templateContent: some View {
        switch graphic.template {
        case .fullWidth:
            FullWidthTemplate(graphic: graphic, scale: scale, isMatte: isMatte, reportBounds: reportBounds)
        case .roundedBar:
            RoundedBarTemplate(graphic: graphic, scale: scale, isMatte: isMatte, reportBounds: reportBounds)
        case .stackedBar:
            StackedBarTemplate(graphic: graphic, scale: scale, isMatte: isMatte, reportBounds: reportBounds)
        case .boldName:
            BoldNameTemplate(graphic: graphic, scale: scale, isMatte: isMatte, reportBounds: reportBounds)
        case .underlineFade:
            UnderlineFadeTemplate(graphic: graphic, scale: scale, isMatte: isMatte, reportBounds: reportBounds)
        case .sideStripe:
            SideStripeTemplate(graphic: graphic, scale: scale, isMatte: isMatte, reportBounds: reportBounds)
        case .cornerBracket:
            CornerBracketTemplate(graphic: graphic, scale: scale, isMatte: isMatte, reportBounds: reportBounds)
        case .glassPanel:
            GlassPanelTemplate(graphic: graphic, scale: scale, isMatte: isMatte, reportBounds: reportBounds)
        case .custom:
            CustomTemplate(graphic: graphic, scale: scale, isMatte: isMatte, reportBounds: reportBounds)
        }
    }

    // MARK: - Background Image Layer

    @ViewBuilder
    private var backgroundLayer: some View {
        if let bgData = graphic.backgroundData, let nsImage = NSImage(data: bgData) {
            let image = Image(nsImage: nsImage).resizable()

            if isMatte {
                // Matte: render as white silhouette for key signal
                fittedImage(image, fitMode: graphic.backgroundFitMode)
                    .colorMultiply(.white)
                    .opacity(graphic.backgroundImageOpacity > 0 ? 1 : 0)
                    .scaleEffect(graphic.backgroundScale)
            } else {
                fittedImage(image, fitMode: graphic.backgroundFitMode)
                    .opacity(graphic.backgroundImageOpacity)
                    .scaleEffect(graphic.backgroundScale)
                    .reportElementBounds(.backgroundImage, active: reportBounds)
            }
        }
    }

    // MARK: - Overlay Image Layer

    @ViewBuilder
    private var overlayLayer: some View {
        if let ovData = graphic.overlayData, let nsImage = NSImage(data: ovData) {
            let image = Image(nsImage: nsImage).resizable().scaledToFit()

            if isMatte {
                image
                    .colorMultiply(.white)
                    .opacity(graphic.overlayOpacity > 0 ? 1 : 0)
                    .scaleEffect(graphic.overlayScale)
                    .offset(
                        x: graphic.overlayOffsetX * scale,
                        y: graphic.overlayOffsetY * scale
                    )
            } else {
                image
                    .opacity(graphic.overlayOpacity)
                    .scaleEffect(graphic.overlayScale)
                    .offset(
                        x: graphic.overlayOffsetX * scale,
                        y: graphic.overlayOffsetY * scale
                    )
                    .reportElementBounds(.overlayImage, active: reportBounds)
            }
        }
    }

    // MARK: - Image Fitting

    @ViewBuilder
    private func fittedImage(_ image: Image, fitMode: ImageFitMode) -> some View {
        switch fitMode {
        case .fill:
            image.scaledToFill()
        case .fit:
            image.scaledToFit()
        case .stretch:
            image // resizable() already applied, stretches to fill frame
        }
    }
}
