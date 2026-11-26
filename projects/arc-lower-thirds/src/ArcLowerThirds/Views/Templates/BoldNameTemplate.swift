//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Large bold name with accent underline, no background box.
/// Minimal/modern look — text floats directly over video.
struct BoldNameTemplate: View {
    let graphic: Graphic
    var scale: CGFloat = 1.0
    var isMatte: Bool = false
    var reportBounds: Bool = false

    private var accentColor: Color { isMatte ? .white : ARCTheme.color(from: graphic.accentColor) }
    private func textColor(_ line: Int) -> Color { isMatte ? .white : graphic.colorForLine(line) }

    var body: some View {
        HStack(spacing: 12 * scale) {
            logoView(position: .left)

            VStack(alignment: .leading, spacing: graphic.lineSpacing * scale) {
                Text(graphic.line1)
                    .font(graphic.fontForLine1(scale: scale))
                    .foregroundStyle(textColor(1).opacity(graphic.line1Opacity))
                    .shadow(
                        color: isMatte ? .clear : .black.opacity(graphic.shadowEnabled ? graphic.shadowOpacity : 0.8),
                        radius: (graphic.shadowEnabled ? graphic.shadowRadius : 4) * scale,
                        x: 0, y: 2 * scale)
                    .lineLimit(1)
                    .reportElementBounds(.nameBlock, active: reportBounds)

                // Accent underline
                Rectangle()
                    .fill(accentColor)
                    .frame(height: graphic.accentBarSize * scale)
                    .reportElementBounds(.accentBar, active: reportBounds)

                VStack(alignment: .leading, spacing: graphic.lineSpacing * scale) {
                    if let line2 = graphic.line2, !line2.isEmpty {
                        Text(line2)
                            .font(graphic.fontForLine2(scale: scale))
                            .foregroundStyle(textColor(2).opacity(graphic.line2Opacity))
                            .shadow(
                                color: isMatte ? .clear : .black.opacity(graphic.shadowEnabled ? graphic.shadowOpacity * 0.88 : 0.7),
                                radius: (graphic.shadowEnabled ? graphic.shadowRadius * 0.75 : 3) * scale,
                                x: 0, y: 1 * scale)
                            .lineLimit(1)
                    }

                    if let line3 = graphic.line3, !line3.isEmpty {
                        Text(line3)
                            .font(graphic.fontForLine3(scale: scale))
                            .foregroundStyle(textColor(3).opacity(graphic.line3Opacity))
                            .shadow(
                                color: isMatte ? .clear : .black.opacity(graphic.shadowEnabled ? graphic.shadowOpacity * 0.75 : 0.6),
                                radius: (graphic.shadowEnabled ? graphic.shadowRadius * 0.5 : 2) * scale,
                                x: 0, y: 1 * scale)
                            .lineLimit(1)
                    }
                }
                .reportElementBounds(.titleBlock, active: reportBounds)
            }

            logoView(position: .right)
        }
        .padding(.horizontal, graphic.namePaddingH * scale)
        .padding(.vertical, graphic.namePaddingV * scale)
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
