//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Live time display positioned in a corner of the output.
/// Updates every second via TimelineView. Styled with the graphic's accent color and font.
struct ClockOverlayView: View {
    let graphic: Graphic
    let isOnAir: Bool
    var isMatte: Bool = false

    private var textColor: Color { isMatte ? .white : graphic.colorForLine(1) }
    private var bgColor: Color { isMatte ? .white : graphic.resolvedTitleBgColor }

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = graphic.clockShowSeconds
            ? graphic.clockFormat.replacingOccurrences(of: "h:mm", with: "h:mm:ss")
                .replacingOccurrences(of: "H:mm", with: "H:mm:ss")
            : graphic.clockFormat
        return f
    }

    var body: some View {
        let interval: TimeInterval = graphic.clockShowSeconds ? 1.0 : 60.0

        TimelineView(.periodic(from: .now, by: interval)) { context in
            ZStack(alignment: graphic.bugCorner.alignment) {
                Color.clear

                Text(dateFormatter.string(from: context.date))
                    .font(graphic.fontForLine1())
                    .foregroundStyle(textColor.opacity(graphic.line1Opacity))
                    .monospacedDigit()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: graphic.cornerRadius)
                            .fill(bgColor.opacity(graphic.backgroundOpacity))
                    )
                    .padding(.horizontal, graphic.bugMarginH)
                    .padding(.vertical, graphic.bugMarginV)
            }
        }
        .opacity(isOnAir ? 1 : 0)
        .animation(.easeInOut(duration: 0.3), value: isOnAir)
    }
}
