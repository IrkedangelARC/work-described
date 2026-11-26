//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Continuously scrolling horizontal text crawl at the bottom of screen.
/// Uses TimelineView for smooth 60fps scrolling driven by tickerSpeed.
/// Text repeats infinitely via concatenation with tickerSeparator.
struct TickerOverlayView: View {
    let graphic: Graphic
    let isOnAir: Bool
    let screenWidth: CGFloat
    var isMatte: Bool = false

    @State private var textWidth: CGFloat = 0
    @State private var startDate: Date = .now

    private var accentColor: Color { isMatte ? .white : ARCTheme.color(from: graphic.accentColor) }
    private var bgColor: Color { isMatte ? .white : graphic.resolvedTitleBgColor }
    private func textColor(_ line: Int) -> Color { isMatte ? .white : graphic.colorForLine(line) }

    /// Single ticker segment: line1 + separator (used as repeating unit)
    private var tickerSegment: String {
        let sep = graphic.tickerSeparator ?? "     ///     "
        return graphic.line1 + sep
    }

    var body: some View {
        VStack {
            Spacer()

            ZStack {
                // Background bar
                Rectangle()
                    .fill(isMatte ? Color.white : bgColor.opacity(graphic.backgroundOpacity))
                    .frame(height: 48)

                // Accent top line
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(accentColor)
                        .frame(height: graphic.accentBarSize)
                    Spacer()
                }
                .frame(height: 48)

                // Scrolling text
                TimelineView(.animation) { context in
                    let elapsed = context.date.timeIntervalSince(startDate)
                    let totalShift = elapsed * graphic.tickerSpeed
                    // Wrap offset so it loops seamlessly
                    let repeatWidth = max(textWidth, 1)
                    let offset = -(totalShift.truncatingRemainder(dividingBy: repeatWidth))

                    tickerTextView
                        .offset(x: offset)
                }
                .frame(height: 48)
                .clipped()
            }
            .frame(height: 48)
            .padding(.bottom, 0)  // Flush to bottom edge
        }
        .opacity(isOnAir ? 1 : 0)
        .animation(.easeInOut(duration: 0.3), value: isOnAir)
        .onChange(of: isOnAir) { _, newValue in
            if newValue { startDate = .now }
        }
    }

    /// Repeats tickerSegment enough times to guarantee it fills screenWidth
    private var tickerTextView: some View {
        let repeats = max(Int(ceil(screenWidth / max(textWidth, 1))) + 1, 3)
        let fullText = String(repeating: tickerSegment, count: repeats)
        return Text(fullText)
            .font(graphic.fontForLine1())
            .foregroundStyle(textColor(1))
            .lineLimit(1)
            .fixedSize()
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        // Measure one segment's width for seamless looping
                        textWidth = geo.size.width / CGFloat(repeats)
                    }
                }
            )
    }
}
