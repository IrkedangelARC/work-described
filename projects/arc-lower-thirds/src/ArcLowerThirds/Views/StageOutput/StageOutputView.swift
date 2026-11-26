//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Full-frame HDMI output view. Black background with graphics composited by layer.
/// This is what the video switcher sees — DSK or PIP over program feed.
/// Layers render bottom-to-top: ticker, lower third, logo bug, full title, clock.
///
/// While DeckLink Fill+Key output is active this window is captured with
/// alpha, so the backdrop goes CLEAR instead of black (analogous to the
/// `isMatte` flag on the key window) — window transparency becomes the
/// ATEM key signal. Graphics themselves stay fully opaque.
struct StageOutputView: View {
    @Environment(GraphicsEngine.self) private var engine
    @Environment(DeckLinkOutputManager.self) private var deckLink

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Full black frame — clear while DeckLink capture is active
                (deckLink.isActive ? Color.clear : Color.black)
                    .ignoresSafeArea()

                // Render all active layers in z-order
                ForEach(GraphicLayer.allCases.sorted()) { layer in
                    if let state = engine.layers[layer], state.graphic != nil {
                        layerView(state: state, layer: layer, in: geo)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func layerView(state: GraphicsEngine.LayerState, layer: GraphicLayer, in geo: GeometryProxy) -> some View {
        if let graphic = state.graphic {
            switch graphic.graphicType {
            case .lowerThird:
                graphicOverlay(graphic: graphic, isOnAir: state.isOnAir, in: geo)

            case .ticker:
                TickerOverlayView(graphic: graphic, isOnAir: state.isOnAir, screenWidth: geo.size.width)

            case .logoBug:
                LogoBugOverlayView(graphic: graphic, isOnAir: state.isOnAir)

            case .fullTitle:
                FullTitleOverlayView(graphic: graphic, isOnAir: state.isOnAir)

            case .clock:
                ClockOverlayView(graphic: graphic, isOnAir: state.isOnAir)
            }
        }
    }

    @ViewBuilder
    private func graphicOverlay(graphic: Graphic, isOnAir: Bool, in geo: GeometryProxy) -> some View {
        let maxWidth = geo.size.width * graphic.maxWidthFraction
        let margin = graphic.horizontalMargin
        let bottomPad = graphic.bottomOffset

        switch graphic.positionPreset {
        case .bottomLeft:
            VStack {
                Spacer()
                HStack {
                    TemplateRendererView(graphic: graphic)
                        .frame(maxWidth: graphic.template == .fullWidth ? .infinity : maxWidth, alignment: .leading)
                    if graphic.template != .fullWidth { Spacer() }
                }
                .padding(.leading, graphic.template == .fullWidth ? 0 : margin)
                .padding(.bottom, bottomPad)
            }
            .animatedLowerThird(
                preset: graphic.animationPreset,
                isVisible: isOnAir,
                inDuration: graphic.effectiveInDuration,
                outDuration: graphic.effectiveOutDuration
            )

        case .bottomCenter:
            VStack {
                Spacer()
                TemplateRendererView(graphic: graphic)
                    .frame(maxWidth: graphic.template == .fullWidth ? .infinity : maxWidth)
                    .padding(.bottom, bottomPad)
            }
            .animatedLowerThird(
                preset: graphic.animationPreset,
                isVisible: isOnAir,
                inDuration: graphic.effectiveInDuration,
                outDuration: graphic.effectiveOutDuration
            )

        case .bottomRight:
            VStack {
                Spacer()
                HStack {
                    if graphic.template != .fullWidth { Spacer() }
                    TemplateRendererView(graphic: graphic)
                        .frame(maxWidth: graphic.template == .fullWidth ? .infinity : maxWidth, alignment: .trailing)
                }
                .padding(.trailing, graphic.template == .fullWidth ? 0 : margin)
                .padding(.bottom, bottomPad)
            }
            .animatedLowerThird(
                preset: graphic.animationPreset,
                isVisible: isOnAir,
                inDuration: graphic.effectiveInDuration,
                outDuration: graphic.effectiveOutDuration
            )

        case .topLeft:
            VStack {
                HStack {
                    TemplateRendererView(graphic: graphic)
                        .frame(maxWidth: graphic.template == .fullWidth ? .infinity : maxWidth, alignment: .leading)
                    if graphic.template != .fullWidth { Spacer() }
                }
                .padding(.leading, graphic.template == .fullWidth ? 0 : margin)
                .padding(.top, bottomPad)
                Spacer()
            }
            .animatedLowerThird(
                preset: graphic.animationPreset,
                isVisible: isOnAir,
                inDuration: graphic.effectiveInDuration,
                outDuration: graphic.effectiveOutDuration
            )

        case .topCenter:
            VStack {
                TemplateRendererView(graphic: graphic)
                    .frame(maxWidth: graphic.template == .fullWidth ? .infinity : maxWidth)
                    .padding(.top, bottomPad)
                Spacer()
            }
            .animatedLowerThird(
                preset: graphic.animationPreset,
                isVisible: isOnAir,
                inDuration: graphic.effectiveInDuration,
                outDuration: graphic.effectiveOutDuration
            )

        case .topRight:
            VStack {
                HStack {
                    if graphic.template != .fullWidth { Spacer() }
                    TemplateRendererView(graphic: graphic)
                        .frame(maxWidth: graphic.template == .fullWidth ? .infinity : maxWidth, alignment: .trailing)
                }
                .padding(.trailing, graphic.template == .fullWidth ? 0 : margin)
                .padding(.top, bottomPad)
                Spacer()
            }
            .animatedLowerThird(
                preset: graphic.animationPreset,
                isVisible: isOnAir,
                inDuration: graphic.effectiveInDuration,
                outDuration: graphic.effectiveOutDuration
            )

        case .center:
            TemplateRendererView(graphic: graphic)
                .frame(maxWidth: graphic.template == .fullWidth ? .infinity : maxWidth)
                .animatedLowerThird(
                    preset: graphic.animationPreset,
                    isVisible: isOnAir,
                    inDuration: graphic.effectiveInDuration,
                    outDuration: graphic.effectiveOutDuration
                )
        }
    }
}
