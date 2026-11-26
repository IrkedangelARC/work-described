//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Text framed by L-shaped corner brackets — no filled background.
/// Technical, scholarly, documentary aesthetic. Video shows through fully
/// while brackets provide clear structural framing.
struct CornerBracketTemplate: View {
    let graphic: Graphic
    var scale: CGFloat = 1.0
    var isMatte: Bool = false
    var reportBounds: Bool = false

    private var accentColor: Color { isMatte ? .white : ARCTheme.color(from: graphic.accentColor) }
    private func textColor(_ line: Int) -> Color { isMatte ? .white : graphic.colorForLine(line) }
    private var noShadow: TextShadowModifier { TextShadowModifier(enabled: false, radius: 0, opacity: 0) }
    private var bracketThickness: CGFloat { max(graphic.accentBarSize * scale, 2 * scale) }
    private var bracketLength: CGFloat { 24 * scale }

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
            .padding(.horizontal, graphic.namePaddingH * scale)
            .padding(.vertical, graphic.namePaddingV * scale)
            .overlay(bracketOverlay)

            logoView(position: .right)
        }
    }

    /// Two L-shaped corner brackets: top-left and bottom-right
    private var bracketOverlay: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let t = bracketThickness
            let len = min(bracketLength, min(w, h) * 0.4)

            // Top-left bracket
            Path { p in
                p.move(to: CGPoint(x: 0, y: len))
                p.addLine(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: len, y: 0))
            }
            .stroke(accentColor, lineWidth: t)

            // Bottom-right bracket
            Path { p in
                p.move(to: CGPoint(x: w, y: h - len))
                p.addLine(to: CGPoint(x: w, y: h))
                p.addLine(to: CGPoint(x: w - len, y: h))
            }
            .stroke(accentColor, lineWidth: t)
        }
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
