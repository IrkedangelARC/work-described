//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Pre-rendered background image with freely-positioned text overlay.
/// The "CG skin" workflow: import a designed PNG frame, fill in dynamic text at specific coordinates.
/// No template chrome — the background image IS the design.
struct CustomTemplate: View {
    let graphic: Graphic
    var scale: CGFloat = 1.0
    var isMatte: Bool = false
    var reportBounds: Bool = false

    private func textColor(_ line: Int) -> Color { isMatte ? .white : graphic.colorForLine(line) }
    private var noShadow: TextShadowModifier { TextShadowModifier(enabled: false, radius: 0, opacity: 0) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Text block at custom offset
            VStack(alignment: graphic.customTextAlignment.horizontalAlignment, spacing: graphic.lineSpacing * scale) {
                // Line 1
                Text(graphic.line1)
                    .font(graphic.fontForLine1(scale: scale))
                    .foregroundStyle(textColor(1).opacity(graphic.line1Opacity))
                    .modifier(isMatte ? noShadow : graphic.textShadow(scale: scale))
                    .lineLimit(1)

                // Line 2
                if let line2 = graphic.line2, !line2.isEmpty {
                    Text(line2)
                        .font(graphic.fontForLine2(scale: scale))
                        .foregroundStyle(textColor(2).opacity(graphic.line2Opacity))
                        .modifier(isMatte ? noShadow : graphic.textShadow(scale: scale))
                        .lineLimit(1)
                }

                // Line 3
                if let line3 = graphic.line3, !line3.isEmpty {
                    Text(line3)
                        .font(graphic.fontForLine3(scale: scale))
                        .foregroundStyle(textColor(3).opacity(graphic.line3Opacity))
                        .modifier(isMatte ? noShadow : graphic.textShadow(scale: scale))
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(graphic.customTextAlignment.alignment)
            .offset(x: graphic.customTextOffsetX * scale, y: graphic.customTextOffsetY * scale)
            .reportElementBounds(.nameBlock, active: reportBounds)

            // Logo with offset
            logoView
        }
    }

    @ViewBuilder
    private var logoView: some View {
        if let logoData = graphic.logoData, let nsImage = NSImage(data: logoData) {
            if isMatte {
                Image(nsImage: nsImage).resizable().scaledToFit()
                    .frame(height: graphic.logoSize * scale)
                    .colorMultiply(.white)
                    .offset(
                        x: graphic.logoOffsetX * scale,
                        y: graphic.logoOffsetY * scale
                    )
                    .reportElementBounds(.logo, active: reportBounds)
            } else {
                Image(nsImage: nsImage).resizable().scaledToFit()
                    .frame(height: graphic.logoSize * scale)
                    .shadow(color: .black.opacity(0.5), radius: 4 * scale, x: 0, y: 2 * scale)
                    .offset(
                        x: graphic.logoOffsetX * scale,
                        y: graphic.logoOffsetY * scale
                    )
                    .reportElementBounds(.logo, active: reportBounds)
            }
        }
    }
}
