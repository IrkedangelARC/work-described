//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

enum TimerColorState {
    case idle
    case nominal
    case warning
    case danger
    case overtime

    var color: Color {
        switch self {
        case .idle: .gray
        case .nominal: ARCTheme.timerGreen
        case .warning: ARCTheme.timerYellow
        case .danger: ARCTheme.timerRed
        case .overtime: ARCTheme.timerRed
        }
    }

    var backgroundColor: Color {
        switch self {
        case .idle: .clear
        case .nominal: ARCTheme.timerGreen.opacity(0.15)
        case .warning: ARCTheme.timerYellow.opacity(0.15)
        case .danger: ARCTheme.timerRed.opacity(0.15)
        case .overtime: ARCTheme.timerRed.opacity(0.25)
        }
    }

    // MARK: - Scheme-Aware Colors

    func color(for scheme: DisplayColorScheme) -> Color {
        switch self {
        case .idle: scheme.idle
        case .nominal: scheme.nominal
        case .warning: scheme.warning
        case .danger: scheme.danger
        case .overtime: scheme.danger
        }
    }

    func backgroundColor(for scheme: DisplayColorScheme) -> Color {
        switch self {
        case .idle: .clear
        case .nominal: scheme.nominal.opacity(scheme.backgroundOpacity)
        case .warning: scheme.warning.opacity(scheme.backgroundOpacity)
        case .danger: scheme.danger.opacity(scheme.backgroundOpacity)
        case .overtime: scheme.danger.opacity(scheme.overtimeBackgroundOpacity)
        }
    }

    static func compute(remaining: Int, warning: Int, danger: Int, isOvertime: Bool) -> TimerColorState {
        if isOvertime { return .overtime }
        if remaining <= danger { return .danger }
        if remaining <= warning { return .warning }
        return .nominal
    }
}
