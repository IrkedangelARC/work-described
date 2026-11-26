//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Two stacked horizontal bars: name bar on top (accent), title bar below (dark).
/// Title bar is slightly offset to the right for a layered, dynamic look.
struct StackedBarTemplate: View {
    let graphic: Graphic
    var scale: CGFloat = 1.0
    var isMatte: Bool = false
    var reportBounds: Bool = false

    private var accentColor: Color { isMatte ? .white : ARCTheme.color(from: graphic.accentColor) }
    private var titleBg: Color { isMatte ? .white : graphic.resolvedTitleBgColor }
    private func textColor(_ line: Int) -> Color { isMatte ? .white : graphic.colorForLine(line) }
    private var noShadow: TextShadowModifier { TextShadowModifier(enabled: false, radius: 0, opacity: 0) }
    private var radius: CGFloat { graphic.cornerRadius * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: graphic.elementGap > 0 ? graphic.elementGap * scale : 2 * scale) {
            // Top bar — name on accent
            HStack(spacing: 0) {
                logoView(position: .left)

                Text(graphic.line1)
                    .font(graphic.fontForLine1(scale: scale))
                    .foregroundStyle(textColor(1).opacity(graphic.line1Opacity))
                    .modifier(isMatte ? noShadow : graphic.textShadow(scale: scale))
                    .lineLimit(1)
                    .padding(.horizontal, graphic.namePaddingH * scale)
                    .padding(.vertical, graphic.namePaddingV * scale)

                logoView(position: .right)
            }
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(accentColor.opacity(graphic.backgroundOpacity))
            )
            .reportElementBounds(.nameBlock, active: reportBounds)

            // Bottom bar — title/org on dark, offset right
            if graphic.line2 != nil || graphic.line3 != nil {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: graphic.lineSpacing * scale) {
                        if let line2 = graphic.line2, !line2.isEmpty {
                            Text(line2)
                                .font(graphic.fontForLine2(scale: scale))
                                .foregroundStyle(textColor(2).opacity(graphic.line2Opacity))
                                .modifier(isMatte ? noShadow : graphic.textShadow(scale: scale))
                                .lineLimit(1)
                        }
                        if let line3 = graphic.line3, !line3.isEmpty {
                            Text(line3)
                                .font(graphic.fontForLine3(scale: scale))
                                .foregroundStyle(textColor(3).opacity(graphic.line3Opacity))
                                .modifier(isMatte ? noShadow : graphic.textShadow(scale: scale))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, graphic.titlePaddingH * scale)
                    .padding(.vertical, graphic.titlePaddingV * scale)
                }
                .background(
                    RoundedRectangle(cornerRadius: radius)
                        .fill(titleBg.opacity(graphic.titleBgOpacity))
                )
                .reportElementBounds(.titleBlock, active: reportBounds)
                .padding(.leading, graphic.elementGap > 0 ? graphic.elementGap * 4 * scale : 40 * scale)
            }
        }
    }

    @ViewBuilder
    private func logoView(position: LogoPosition) -> some View {
        if let logoData = graphic.logoData, graphic.logoPosition == position,
           let nsImage = NSImage(data: logoData) {
            Image(nsImage: nsImage).resizable().scaledToFit()
                .frame(height: graphic.logoSize * scale)
                .offset(x: graphic.logoOffsetX * scale, y: graphic.logoOffsetY * scale)
                .padding(position == .left ? .leading : .trailing, 12 * scale)
                .reportElementBounds(.logo, active: reportBounds)
        }
    }
}
