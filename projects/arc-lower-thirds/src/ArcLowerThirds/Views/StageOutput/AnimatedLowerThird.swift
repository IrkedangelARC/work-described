//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit

/// ViewModifier that applies the selected animation preset to a lower third overlay.
/// Handles both in (appear) and out (disappear) animations based on `isVisible`.
/// Supports per-graphic duration overrides via inDuration/outDuration parameters.
struct AnimatedLowerThird: ViewModifier {
    let preset: AnimationPreset
    let isVisible: Bool
    let inDuration: Double
    let outDuration: Double

    func body(content: Content) -> some View {
        content
            .modifier(PresetModifier(
                preset: preset,
                isVisible: isVisible,
                inDuration: inDuration,
                outDuration: outDuration
            ))
    }
}

private struct PresetModifier: ViewModifier {
    let preset: AnimationPreset
    let isVisible: Bool
    let inDuration: Double
    let outDuration: Double

    func body(content: Content) -> some View {
        switch preset {
        case .slideFromLeft:
            content
                .offset(x: isVisible ? 0 : -ScreenHelper.screenWidth)
                .opacity(isVisible ? 1 : 0)
                .animation(
                    isVisible
                        ? .easeOut(duration: inDuration)
                        : .easeIn(duration: outDuration),
                    value: isVisible
                )

        case .slideFromRight:
            content
                .offset(x: isVisible ? 0 : ScreenHelper.screenWidth)
                .opacity(isVisible ? 1 : 0)
                .animation(
                    isVisible
                        ? .easeOut(duration: inDuration)
                        : .easeIn(duration: outDuration),
                    value: isVisible
                )

        case .fadeUp:
            content
                .offset(y: isVisible ? 0 : 40)
                .opacity(isVisible ? 1 : 0)
                .animation(
                    isVisible
                        ? .easeOut(duration: inDuration)
                        : .easeIn(duration: outDuration),
                    value: isVisible
                )

        case .wipeLeft:
            content
                .mask(
                    GeometryReader { geo in
                        Rectangle()
                            .frame(width: isVisible ? geo.size.width : 0)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                )
                .animation(
                    isVisible
                        ? .easeInOut(duration: inDuration)
                        : .easeInOut(duration: outDuration),
                    value: isVisible
                )

        case .scaleUp:
            content
                .scaleEffect(isVisible ? 1 : 0.5)
                .opacity(isVisible ? 1 : 0)
                .animation(
                    isVisible
                        ? .spring(duration: inDuration, bounce: 0.2)
                        : .easeIn(duration: outDuration),
                    value: isVisible
                )

        case .typewriter:
            content
                .opacity(isVisible ? 1 : 0)
                .mask(
                    GeometryReader { geo in
                        Rectangle()
                            .frame(width: isVisible ? geo.size.width : 0)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                )
                .animation(
                    isVisible
                        ? .easeOut(duration: inDuration)
                        : .easeIn(duration: outDuration * 0.5),
                    value: isVisible
                )

        case .bounce:
            content
                .offset(y: isVisible ? 0 : 100)
                .opacity(isVisible ? 1 : 0)
                .animation(
                    isVisible
                        ? .spring(duration: inDuration, bounce: 0.35)
                        : .easeIn(duration: outDuration),
                    value: isVisible
                )

        case .cut:
            content
                .opacity(isVisible ? 1 : 0)
        }
    }
}

private enum ScreenHelper {
    static var screenWidth: CGFloat {
        NSScreen.main?.frame.width ?? 1920
    }
}

extension View {
    func animatedLowerThird(
        preset: AnimationPreset,
        isVisible: Bool,
        inDuration: Double? = nil,
        outDuration: Double? = nil
    ) -> some View {
        modifier(AnimatedLowerThird(
            preset: preset,
            isVisible: isVisible,
            inDuration: inDuration ?? preset.inDuration,
            outDuration: outDuration ?? preset.outDuration
        ))
    }
}
