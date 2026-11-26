//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Frosted glass panel behind all text with thin accent border.
/// Modern, premium glassmorphism look. Works well over any background —
/// the blur ensures readability without heavy solid fills.
struct GlassPanelTemplate: View {
    let graphic: Graphic
    var scale: CGFloat = 1.0
    var isMatte: Bool = false
    var reportBounds: Bool = false

    private var accentColor: Color { isMatte ? .white : ARCTheme.color(from: graphic.accentColor) }
    private func textColor(_ line: Int) -> Color { isMatte ? .white : graphic.colorForLine(line) }
    private var noShadow: TextShadowModifier { TextShadowModifier(enabled: false, radius: 0, opacity: 0) }
    private var radius: CGFloat { graphic.cornerRadius * scale }

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
        .background(glassBackground)
        .overlay(accentBorder)
    }

    @ViewBuilder
    private var glassBackground: some View {
        if isMatte {
            // Matte mode: solid white for key signal
            RoundedRectangle(cornerRadius: radius)
                .fill(Color.white)
        } else {
            // Glass effect: dark tinted material with blur
            RoundedRectangle(cornerRadius: radius)
                .fill(.ultraThinMaterial)
                .opacity(graphic.backgroundOpacity)
                .environment(\.colorScheme, .dark)
        }
    }

    /// Thin accent-colored border on the left edge of the glass panel
    private var accentBorder: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: radius)
                .fill(accentColor)
                .frame(width: max(graphic.accentBarSize * scale, 3 * scale))
                .reportElementBounds(.accentBar, active: reportBounds)
            Spacer()
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
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
