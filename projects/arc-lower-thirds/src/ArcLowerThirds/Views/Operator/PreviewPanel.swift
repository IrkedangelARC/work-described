//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// 16:9 preview of the selected graphic — shows what will go on air when FIRE is pressed.
/// Dispatches to type-specific preview renderers for each GraphicType.
struct PreviewPanel: View {
    @Environment(GraphicsEngine.self) private var engine

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "tv")
                    .foregroundStyle(ARCTheme.accent)
                Text("PREVIEW")
                    .font(ARCTheme.caption)
                    .foregroundStyle(ARCTheme.textSecondary)
                Spacer()
                if let graphic = engine.selectedGraphic {
                    Image(systemName: graphic.graphicType.sfSymbol)
                        .foregroundStyle(ARCTheme.textTertiary)
                    Text(graphic.animationPreset.displayName)
                        .font(ARCTheme.caption)
                        .foregroundStyle(ARCTheme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // 16:9 preview frame — fit within available space
            GeometryReader { geo in
                // Fit 16:9 within the available GeometryReader bounds
                let fitScale = min(geo.size.width / 16, geo.size.height / 9)
                let width = fitScale * 16
                let height = fitScale * 9
                let scale = width / 1920

                ZStack(alignment: .topLeading) {
                    graphicPreview(width: width, height: height, scale: scale)
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    // "PVW" label overlay
                    if engine.selectedGraphic != nil {
                        Text("PVW")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(ARCTheme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ARCTheme.surface.opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .offset(x: 8, y: 6)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(ARCTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius))
    }

    // MARK: - Type-Specific Preview

    @ViewBuilder
    private func graphicPreview(width: CGFloat, height: CGFloat, scale: CGFloat) -> some View {
        if let graphic = engine.selectedGraphic {
            switch graphic.graphicType {
            case .lowerThird:
                ZStack(alignment: .bottomLeading) {
                    Color.black
                    TemplateRendererView(graphic: graphic, scale: scale)
                        .padding(.leading, 20)
                        .padding(.bottom, height * 0.07)
                        .frame(maxWidth: width * ARCTheme.ltMaxWidth, alignment: .leading)
                }

            case .ticker:
                ZStack(alignment: .bottom) {
                    Color.black
                    ZStack {
                        Rectangle()
                            .fill(graphic.resolvedTitleBgColor.opacity(graphic.backgroundOpacity))
                        VStack(spacing: 0) {
                            Rectangle()
                                .fill(ARCTheme.color(from: graphic.accentColor))
                                .frame(height: max(graphic.accentBarSize * scale, 1))
                            Spacer()
                        }
                        Text(graphic.line1)
                            .font(.system(size: graphic.line1FontSize * scale, weight: graphic.line1Weight.fontWeight))
                            .foregroundStyle(graphic.colorForLine(1))
                            .lineLimit(1)
                    }
                    .frame(height: max(48 * scale, 20))
                }

            case .logoBug:
                ZStack(alignment: graphic.bugCorner.alignment) {
                    Color.black
                    if let logoData = graphic.logoData, let nsImage = NSImage(data: logoData) {
                        Image(nsImage: nsImage).resizable().scaledToFit()
                            .frame(height: graphic.logoSize * scale)
                            .padding(.horizontal, graphic.bugMarginH * scale)
                            .padding(.vertical, graphic.bugMarginV * scale)
                    } else {
                        Text(graphic.line1)
                            .font(.system(size: graphic.line1FontSize * scale, weight: graphic.line1Weight.fontWeight))
                            .foregroundStyle(ARCTheme.color(from: graphic.accentColor))
                            .padding(.horizontal, 12 * scale)
                            .padding(.vertical, 6 * scale)
                            .background(
                                RoundedRectangle(cornerRadius: graphic.cornerRadius * scale)
                                    .fill(graphic.resolvedTitleBgColor.opacity(graphic.backgroundOpacity))
                            )
                            .padding(.horizontal, graphic.bugMarginH * scale)
                            .padding(.vertical, graphic.bugMarginV * scale)
                    }
                }

            case .fullTitle:
                VStack(spacing: graphic.lineSpacing * scale) {
                    Spacer()
                    Text(graphic.line1)
                        .font(.system(size: graphic.line1FontSize * scale, weight: graphic.line1Weight.fontWeight))
                        .foregroundStyle(graphic.colorForLine(1).opacity(graphic.line1Opacity))
                        .multilineTextAlignment(.center)
                    if let line2 = graphic.line2, !line2.isEmpty {
                        Text(line2)
                            .font(.system(size: graphic.line2FontSize * scale, weight: graphic.line2Weight.fontWeight))
                            .foregroundStyle(graphic.colorForLine(2).opacity(graphic.line2Opacity))
                            .multilineTextAlignment(.center)
                    }
                    if let line3 = graphic.line3, !line3.isEmpty {
                        Text(line3)
                            .font(.system(size: graphic.line3FontSize * scale, weight: graphic.line3Weight.fontWeight))
                            .foregroundStyle(graphic.colorForLine(3).opacity(graphic.line3Opacity))
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(max(graphic.backgroundOpacity * 0.6, 0.3)))

            case .clock:
                ZStack(alignment: graphic.bugCorner.alignment) {
                    Color.black
                    Text(clockPreviewString(graphic: graphic))
                        .font(.system(size: graphic.line1FontSize * scale, weight: graphic.line1Weight.fontWeight))
                        .foregroundStyle(graphic.colorForLine(1).opacity(graphic.line1Opacity))
                        .monospacedDigit()
                        .padding(.horizontal, 16 * scale)
                        .padding(.vertical, 8 * scale)
                        .background(
                            RoundedRectangle(cornerRadius: graphic.cornerRadius * scale)
                                .fill(graphic.resolvedTitleBgColor.opacity(graphic.backgroundOpacity))
                        )
                        .padding(.horizontal, graphic.bugMarginH * scale)
                        .padding(.vertical, graphic.bugMarginV * scale)
                }
            }
        } else {
            ZStack {
                Color.black
                Text("No graphic selected")
                    .font(ARCTheme.caption)
                    .foregroundStyle(ARCTheme.textTertiary)
            }
        }
    }

    private func clockPreviewString(graphic: Graphic) -> String {
        let f = DateFormatter()
        f.dateFormat = graphic.clockShowSeconds
            ? graphic.clockFormat.replacingOccurrences(of: "h:mm", with: "h:mm:ss")
                .replacingOccurrences(of: "H:mm", with: "H:mm:ss")
            : graphic.clockFormat
        return f.string(from: .now)
    }
}
