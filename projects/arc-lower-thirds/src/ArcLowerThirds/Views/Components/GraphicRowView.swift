//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Row view for a graphic in show editor lists.
struct GraphicRowView: View {
    let graphic: Graphic
    let index: Int

    private var accentColor: Color {
        ARCTheme.color(from: graphic.accentColor)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Index
            Text("\(index + 1)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(ARCTheme.textSecondary)
                .frame(width: 24)

            // Accent dot
            Circle()
                .fill(accentColor)
                .frame(width: 10, height: 10)

            // Text lines
            VStack(alignment: .leading, spacing: 2) {
                Text(graphic.line1)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ARCTheme.textPrimary)

                if let line2 = graphic.line2, !line2.isEmpty {
                    Text(line2)
                        .font(.system(size: 14))
                        .foregroundStyle(ARCTheme.textSecondary)
                }

                if let line3 = graphic.line3, !line3.isEmpty {
                    Text(line3)
                        .font(.system(size: 13))
                        .foregroundStyle(ARCTheme.textTertiary)
                }
            }

            Spacer()

            // Animation icon
            Image(systemName: graphic.animationPreset.sfSymbol)
                .font(.caption)
                .foregroundStyle(ARCTheme.textTertiary)
        }
        .padding(.vertical, 4)
    }
}
