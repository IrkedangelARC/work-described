//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Vertical accent bar on the left + stacked text to the right.
/// Clean conference/keynote style — think "60 Minutes" or academic symposium.
/// No background behind text, just the vertical stripe as structural anchor.
struct SideStripeTemplate: View {
    let graphic: Graphic
    var scale: CGFloat = 1.0
    var isMatte: Bool = false
    var reportBounds: Bool = false

    private var accentColor: Color { isMatte ? .white : ARCTheme.color(from: graphic.accentColor) }
    private var titleBg: Color { isMatte ? .white : graphic.resolvedTitleBgColor }
    private func textColor(_ line: Int) -> Color { isMatte ? .white : graphic.colorForLine(line) }
    private var noShadow: TextShadowModifier { TextShadowModifier(enabled: false, radius: 0, opacity: 0) }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Logo left
            logoView(position: .left)

            // Vertical accent stripe
            RoundedRectangle(cornerRadius: 2 * scale)
                .fill(accentColor)
                .frame(width: max(graphic.accentBarSize * scale, 3 * scale))
                .reportElementBounds(.accentBar, active: reportBounds)

            // Text stack
            VStack(alignment: .leading, spacing: graphic.lineSpacing * scale) {
                // Name
                Text(graphic.line1)
                    .font(graphic.fontForLine1(scale: scale))
                    .foregroundStyle(textColor(1).opacity(graphic.line1Opacity))
                    .modifier(isMatte ? noShadow : graphic.textShadow(scale: scale))
                    .lineLimit(1)
                    .reportElementBounds(.nameBlock, active: reportBounds)

                // Title
                VStack(alignment: .leading, spacing: graphic.lineSpacing * scale) {
                    if let line2 = graphic.line2, !line2.isEmpty {
                        Text(line2)
                            .font(graphic.fontForLine2(scale: scale))
                            .foregroundStyle(textColor(2).opacity(graphic.line2Opacity))
                            .modifier(isMatte ? noShadow : graphic.textShadow(scale: scale))
                            .lineLimit(1)
                    }

                    // Org
                    if let line3 = graphic.line3, !line3.isEmpty {
                        Text(line3)
                            .font(graphic.fontForLine3(scale: scale))
                            .foregroundStyle(textColor(3).opacity(graphic.line3Opacity))
                            .modifier(isMatte ? noShadow : graphic.textShadow(scale: scale))
                            .lineLimit(1)
                    }
                }
                .reportElementBounds(.titleBlock, active: reportBounds)
            }
            .padding(.leading, graphic.namePaddingH * scale)
            .padding(.vertical, graphic.namePaddingV * scale)
            .background(
                Group {
                    if graphic.titleBgOpacity > 0 {
                        if graphic.hardEdge {
                            titleBg.opacity(graphic.titleBgOpacity)
                        } else {
                            LinearGradient(
                                colors: [
                                    titleBg.opacity(graphic.titleBgOpacity),
                                    titleBg.opacity(graphic.titleBgOpacity * 0.5),
                                    titleBg.opacity(0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        }
                    }
                }
            )

            // Logo right
            logoView(position: .right)
        }
    }

    @ViewBuilder
    private func logoView(position: LogoPosition) -> some View {
        if let logoData = graphic.logoData, graphic.logoPosition == position,
           let nsImage = NSImage(data: logoData) {
            Image(nsImage: nsImage).resizable().scaledToFit()
                .frame(height: graphic.logoSize * scale)
                .offset(x: graphic.logoOffsetX * scale, y: graphic.logoOffsetY * scale)
                .padding(position == .left ? .trailing : .leading, 12 * scale)
                .reportElementBounds(.logo, active: reportBounds)
        }
    }
}
