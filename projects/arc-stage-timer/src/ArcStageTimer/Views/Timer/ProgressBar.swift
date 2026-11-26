//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct ProgressBar: View {
    let progress: Double
    let colorState: TimerColorState
    let warningThreshold: Double  // 0-1 fraction where warning starts
    let dangerThreshold: Double   // 0-1 fraction where danger starts
    var height: CGFloat = 20
    var isMatte: Bool = false

    @Environment(\.displayColorScheme) private var scheme

    init(progress: Double, colorState: TimerColorState,
         warningThreshold: Double = 0.0, dangerThreshold: Double = 0.0,
         height: CGFloat = 20, isMatte: Bool = false) {
        self.progress = progress
        self.colorState = colorState
        self.warningThreshold = warningThreshold
        self.dangerThreshold = dangerThreshold
        self.height = height
        self.isMatte = isMatte
    }

    var body: some View {
        if scheme.progressStyle == .hidden && !isMatte {
            EmptyView()
        } else {
            GeometryReader { geo in
                let w = geo.size.width
                let cr = scheme.progressCornerRadius

                ZStack(alignment: .leading) {
                    if isMatte {
                        matteContent(width: w)
                    } else {
                        switch scheme.progressStyle {
                        case .segmented:
                            segmentedContent(width: w, cornerRadius: cr)
                        case .solid:
                            solidContent(width: w, cornerRadius: cr)
                        case .thinLine:
                            thinLineContent(width: w)
                        case .hidden:
                            EmptyView()
                        }
                    }
                }
            }
            .frame(height: height)
        }
    }

    // MARK: - Matte (key signal — always white)

    @ViewBuilder
    private func matteContent(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(0.3))
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.white)
            .frame(width: width * progress)
    }

    // MARK: - Segmented (ARC Default — zone backgrounds + boundary markers)

    @ViewBuilder
    private func segmentedContent(width: CGFloat, cornerRadius: CGFloat) -> some View {
        // Track background with zone segments
        HStack(spacing: 0) {
            let warningStart = max(0, 1.0 - warningThreshold)
            let dangerStart = max(0, 1.0 - dangerThreshold)

            Rectangle()
                .fill(scheme.nominal.opacity(0.2))
                .frame(width: width * warningStart)

            Rectangle()
                .fill(scheme.warning.opacity(0.25))
                .frame(width: width * (dangerStart - warningStart))

            Rectangle()
                .fill(scheme.danger.opacity(0.25))
                .frame(width: width * dangerThreshold)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

        // Fill overlay
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(colorState.color(for: scheme))
            .frame(width: width * progress)
            .shadow(color: scheme.elementShadowColor, radius: scheme.elementShadowRadius, x: scheme.elementShadowX, y: scheme.elementShadowY)
            .animation(.linear(duration: 0.25), value: progress)

        // Zone boundary ticks: 1 pt, the way a console hairline is drawn.
        if warningThreshold > 0 {
            let warningX = width * (1.0 - warningThreshold)
            Rectangle()
                .fill(scheme.warning.opacity(0.8))
                .frame(width: 1)
                .offset(x: warningX)
        }
        if dangerThreshold > 0 {
            let dangerX = width * (1.0 - dangerThreshold)
            Rectangle()
                .fill(scheme.danger.opacity(0.8))
                .frame(width: 1)
                .offset(x: dangerX)
        }

        // The hairline round the track (ARC Style): the bar is a drawn instrument, not a glow.
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(scheme.progressHairline, lineWidth: 1)
    }

    // MARK: - Solid (single thick fill, no zones)

    @ViewBuilder
    private func solidContent(width: CGFloat, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(scheme.progressTrackColor)

        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(colorState.color(for: scheme))
            .frame(width: width * progress)
            .shadow(color: scheme.elementShadowColor, radius: scheme.elementShadowRadius, x: scheme.elementShadowX, y: scheme.elementShadowY)
            .animation(.linear(duration: 0.25), value: progress)
    }

    // MARK: - Thin Line (minimal sleek indicator)

    @ViewBuilder
    private func thinLineContent(width: CGFloat) -> some View {
        Rectangle()
            .fill(scheme.progressTrackColor)

        Rectangle()
            .fill(colorState.color(for: scheme))
            .frame(width: width * progress)
            .shadow(color: scheme.elementShadowColor, radius: scheme.elementShadowRadius * 0.7, x: scheme.elementShadowX * 0.7, y: scheme.elementShadowY * 0.7)
            .animation(.linear(duration: 0.25), value: progress)
    }
}
