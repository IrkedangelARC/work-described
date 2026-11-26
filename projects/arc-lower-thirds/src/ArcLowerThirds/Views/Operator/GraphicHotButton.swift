//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Single row in the graphic sidebar — tappable hot button for quick selection.
struct GraphicHotButton: View {
    let graphic: Graphic
    let index: Int
    let isSelected: Bool
    let isLive: Bool
    let action: () -> Void

    private var accentColor: Color {
        ARCTheme.color(from: graphic.accentColor)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Index badge
                Text("\(index + 1)")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(isLive ? .black : ARCTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(isLive ? ARCTheme.liveRed : ARCTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                // Accent bar
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 3)

                // Text
                VStack(alignment: .leading, spacing: 2) {
                    Text(graphic.line1)
                        .font(ARCTheme.hotButtonTitle)
                        .foregroundStyle(ARCTheme.textPrimary)
                        .lineLimit(1)

                    if let line2 = graphic.line2, !line2.isEmpty {
                        Text(line2)
                            .font(ARCTheme.hotButtonSubtitle)
                            .foregroundStyle(ARCTheme.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Live indicator
                if isLive {
                    Text("LIVE")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ARCTheme.liveRed)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? ARCTheme.surfaceLight : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
