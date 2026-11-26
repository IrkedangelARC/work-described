//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Bold name with accent underline + subtle dark gradient backing for readability.
/// Like Bold Name but with a soft background that fades to transparent on the right.
/// Better for keying over busy video where pure floating text gets lost.
struct UnderlineFadeTemplate: View {
    let graphic: Graphic
    var scale: CGFloat = 1.0
    var isMatte: Bool = false
    var reportBounds: Bool = false

    private var accentColor: Color { isMatte ? .white : ARCTheme.color(from: graphic.accentColor) }
    private var titleBg: Color { isMatte ? .white : graphic.resolvedTitleBgColor }
    private func textColor(_ line: Int) -> Color { isMatte ? .white : graphic.colorForLine(line) }
    private var noShadow: TextShadowModifier { TextShadowModifier(enabled: false, radius: 0, opacity: 0) }

    var body: some View {
        HStack(spacing: 12 * scale) {
            logoView(position: .left)

            VStack(alignment: .leading, spacing: graphic.lineSpacing * scale) {
                // Name
                Text(graphic.line1)
                    .font(graphic.fontForLine1(scale: scale))
                    .foregroundStyle(textColor(1).opacity(graphic.line1Opacity))
                    .modifier(isMatte ? noShadow : graphic.textShadow(scale: scale))
                    .lineLimit(1)
                    .reportElementBounds(.nameBlock, active: reportBounds)

                // Accent underline
                Rectangle()
                    .fill(accentColor)
                    .frame(height: graphic.accentBarSize * scale)
                    .reportElementBounds(.accentBar, active: reportBounds)

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

            logoView(position: .right)
        }
        .padding(.horizontal, graphic.namePaddingH * scale)
        .padding(.vertical, graphic.namePaddingV * scale)
        .background(
            Group {
                if graphic.hardEdge {
                    titleBg.opacity(graphic.titleBgOpacity)
                        .clipShape(RoundedRectangle(cornerRadius: graphic.cornerRadius * scale))
                } else {
                    LinearGradient(
                        colors: [
                            titleBg.opacity(graphic.titleBgOpacity),
                            titleBg.opacity(graphic.titleBgOpacity * 0.7),
                            titleBg.opacity(0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: graphic.cornerRadius * scale))
                }
            }
        )
    }

    @ViewBuilder
    private func logoView(position: LogoPosition) -> some View {
        if let logoData = graphic.logoData, graphic.logoPosition == position,
           let nsImage = NSImage(data: logoData) {
            Image(nsImage: nsImage).resizable().scaledToFit()
                .frame(height: graphic.logoSize * scale)
                .offset(x: graphic.logoOffsetX * scale, y: graphic.logoOffsetY * scale)
                .reportElementBounds(.logo, active: reportBounds)
        }
    }
}
