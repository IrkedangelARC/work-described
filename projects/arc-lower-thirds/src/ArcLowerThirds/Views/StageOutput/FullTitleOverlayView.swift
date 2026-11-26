//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Full-screen centered title for speaker intros, segment headers, bumps.
/// Uses line1/line2/line3 with large centered text. Supports existing animation presets.
struct FullTitleOverlayView: View {
    let graphic: Graphic
    let isOnAir: Bool
    var isMatte: Bool = false

    private func textColor(_ line: Int) -> Color { isMatte ? .white : graphic.colorForLine(line) }
    private var noShadow: TextShadowModifier { TextShadowModifier(enabled: false, radius: 0, opacity: 0) }

    var body: some View {
        VStack(spacing: graphic.lineSpacing) {
            Spacer()

            // Line 1 — primary (speaker name, segment title)
            Text(graphic.line1)
                .font(graphic.fontForLine1())
                .foregroundStyle(textColor(1).opacity(graphic.line1Opacity))
                .modifier(isMatte ? noShadow : graphic.textShadow())
                .multilineTextAlignment(.center)

            // Line 2 — secondary (title, affiliation)
            if let line2 = graphic.line2, !line2.isEmpty {
                Text(line2)
                    .font(graphic.fontForLine2())
                    .foregroundStyle(textColor(2).opacity(graphic.line2Opacity))
                    .modifier(isMatte ? noShadow : graphic.textShadow())
                    .multilineTextAlignment(.center)
            }

            // Line 3 — tertiary (department, organization)
            if let line3 = graphic.line3, !line3.isEmpty {
                Text(line3)
                    .font(graphic.fontForLine3())
                    .foregroundStyle(textColor(3).opacity(graphic.line3Opacity))
                    .modifier(isMatte ? noShadow : graphic.textShadow())
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            isMatte
                ? AnyShapeStyle(Color.white.opacity(graphic.backgroundOpacity > 0 ? 1 : 0))
                : AnyShapeStyle(Color.black.opacity(graphic.backgroundOpacity * 0.6))
        )
        .animatedLowerThird(
            preset: graphic.animationPreset,
            isVisible: isOnAir,
            inDuration: graphic.effectiveInDuration,
            outDuration: graphic.effectiveOutDuration
        )
    }
}
