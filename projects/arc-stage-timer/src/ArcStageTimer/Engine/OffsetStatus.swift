//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

enum OffsetStatus {
    case onTime      // within ±30 seconds
    case ahead       // negative offset (ahead of schedule)
    case behind      // positive offset (behind schedule)
    case wayBehind   // more than 5 minutes behind

    var color: Color {
        switch self {
        case .onTime: ARCTheme.timerGreen
        case .ahead: ARCTheme.accent
        case .behind: ARCTheme.timerYellow
        case .wayBehind: ARCTheme.timerRed
        }
    }

    var label: String {
        switch self {
        case .onTime: "ON TIME"
        case .ahead: "AHEAD"
        case .behind: "BEHIND"
        case .wayBehind: "WAY BEHIND"
        }
    }

    static func from(offsetSeconds: Int) -> OffsetStatus {
        if abs(offsetSeconds) <= 30 { return .onTime }
        if offsetSeconds < 0 { return .ahead }
        if offsetSeconds > 300 { return .wayBehind }
        return .behind
    }
}
