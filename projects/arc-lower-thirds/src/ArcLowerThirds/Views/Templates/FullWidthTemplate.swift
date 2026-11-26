//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Full-width strip across the bottom of frame.
/// Accent-colored name block + dark title block. News broadcast / live event style.
struct FullWidthTemplate: View {
    let graphic: Graphic
    var scale: CGFloat = 1.0
    var isMatte: Bool = false
    var reportBounds: Bool = false

    private var accentColor: Color { isMatte ? .white : ARCTheme.color(from: graphic.accentColor) }
    private var titleBg: Color { isMatte ? .white : graphic.resolvedTitleBgColor }
    private func textColor(_ line: Int) -> Color { isMatte ? .white : graphic.colorForLine(line) }
    private var noShadow: TextShadowModifier { TextShadowModifier(enabled: false, radius: 0, opacity: 0) }

    var body: some View {
        VStack(spacing: 0) {
            // Top accent line
            Rectangle()
                .fill(accentColor)
                .frame(height: graphic.accentBarSize * scale)
                .reportElementBounds(.accentBar, active: reportBounds)

            // Main bar
            HStack(spacing: graphic.elementGap * scale) {
                // Logo left
                logoView(position: .left)

                // Name block
                Text(graphic.line1)
                    .font(graphic.fontForLine1(scale: scale))
                    .foregroundStyle(textColor(1).opacity(graphic.line1Opacity))
                    .modifier(isMatte ? noShadow : graphic.textShadow(scale: scale))
                    .lineLimit(1)
                    .padding(.horizontal, graphic.namePaddingH * scale)
                    .padding(.vertical, graphic.namePaddingV * scale)
                    .background(accentGradientOrSolid)
                    .reportElementBounds(.nameBlock, active: reportBounds)

                // Title/org block
                if graphic.line2 != nil || graphic.line3 != nil {
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
                    .background(titleGradientOrSolid)
                    .reportElementBounds(.titleBlock, active: reportBounds)
                }

                // Logo right
                logoView(position: .right)

                Spacer(minLength: 0)
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
                .padding(position == .left ? .leading : .trailing, 16 * scale)
                .reportElementBounds(.logo, active: reportBounds)
        }
    }

    @ViewBuilder
    private var accentGradientOrSolid: some View {
        if !graphic.hardEdge, let endColor = graphic.resolvedGradientEndColor {
            LinearGradient(
                colors: [accentColor.opacity(graphic.backgroundOpacity),
                         (isMatte ? .black : endColor).opacity(graphic.backgroundOpacity)],
                startPoint: .leading, endPoint: .trailing)
        } else {
            accentColor.opacity(graphic.backgroundOpacity)
        }
    }

    @ViewBuilder
    private var titleGradientOrSolid: some View {
        if !graphic.hardEdge, let endColor = graphic.resolvedGradientEndColor {
            LinearGradient(
                colors: [titleBg.opacity(graphic.titleBgOpacity),
                         (isMatte ? .black : endColor).opacity(graphic.titleBgOpacity * 0.6)],
                startPoint: .leading, endPoint: .trailing)
        } else {
            titleBg.opacity(graphic.titleBgOpacity)
        }
    }
}
