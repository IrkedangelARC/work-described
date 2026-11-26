//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct CountdownDisplay: View {
    let displayTime: String
    let colorState: TimerColorState
    let isOvertime: Bool
    var isMatte: Bool = false

    @Environment(\.displayColorScheme) private var scheme
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        GeometryReader { geo in
            let fontSize = min(geo.size.width / CGFloat(max(displayTime.count, 5)) * 1.8, geo.size.height * 0.68)
            let stateColor: Color = isMatte ? .white : colorState.color(for: scheme)
            let isOutline = scheme.isOutlineText && !isMatte
            let outlineW = fontSize * scheme.outlineWidthFraction

            Text(displayTime)
                .font(.system(size: fontSize, weight: isMatte ? .light : scheme.countdownWeight, design: isMatte ? .monospaced : scheme.fontDesign))
                .foregroundStyle(isOutline ? scheme.stageBackground : stateColor)
                .textOutline(color: isOutline ? stateColor : .clear, width: isOutline ? outlineW : 0)
                .shadow(color: isOutline ? .clear : (isMatte ? .clear : scheme.textShadowColor), radius: scheme.textShadowRadius, x: scheme.textShadowX, y: scheme.textShadowY)
                .monospacedDigit()
                .minimumScaleFactor(0.3)
                .lineLimit(1)
                .opacity(isMatte ? 1.0 : (isOvertime ? pulseOpacity : 1.0))
                .contentTransition(.numericText())
                .animation(isMatte ? nil : .default, value: displayTime)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if isOvertime && !isMatte { startPulsing() }
        }
        .onChange(of: isOvertime) { _, newValue in
            if isMatte { return }
            if newValue { startPulsing() } else { pulseOpacity = 1.0 }
        }
    }

    private func startPulsing() {
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
            pulseOpacity = 0.55
        }
    }
}

struct CountdownDisplayCompact: View {
    let displayTime: String
    let colorState: TimerColorState
    let isOvertime: Bool
    var isMatte: Bool = false

    @Environment(\.displayColorScheme) private var scheme
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        GeometryReader { geo in
            let fontSize = min(geo.size.width / CGFloat(max(displayTime.count, 5)) * 1.8, geo.size.height * 0.68)
            let stateColor: Color = isMatte ? .white : colorState.color(for: scheme)
            let isOutline = scheme.isOutlineText && !isMatte
            let outlineW = fontSize * scheme.outlineWidthFraction

            Text(displayTime)
                .font(.system(size: fontSize, weight: isMatte ? .light : scheme.countdownWeight, design: isMatte ? .monospaced : scheme.fontDesign))
                .foregroundStyle(isOutline ? scheme.stageBackground : stateColor)
                .textOutline(color: isOutline ? stateColor : .clear, width: isOutline ? outlineW : 0)
                .shadow(color: isOutline ? .clear : (isMatte ? .clear : scheme.textShadowColor), radius: scheme.textShadowRadius, x: scheme.textShadowX, y: scheme.textShadowY)
                .monospacedDigit()
                .minimumScaleFactor(0.3)
                .lineLimit(1)
                .opacity(isMatte ? 1.0 : (isOvertime ? pulseOpacity : 1.0))
                .contentTransition(.numericText())
                .animation(isMatte ? nil : .default, value: displayTime)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if isOvertime && !isMatte { startPulsing() }
        }
        .onChange(of: isOvertime) { _, newValue in
            if isMatte { return }
            if newValue { startPulsing() } else { pulseOpacity = 1.0 }
        }
    }

    private func startPulsing() {
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
            pulseOpacity = 0.55
        }
    }
}
