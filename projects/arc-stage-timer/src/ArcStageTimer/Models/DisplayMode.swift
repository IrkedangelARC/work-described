//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

enum DisplayMode {
    case standalone       // Current behavior — no external display features
    case extended         // Control panel on iPad + external HDMI output
    case confidenceOverlay // Extended + confidence overlay (ATEM DSK fill+key)
    case confidencePIP     // Extended + confidence PIP (ATEM DVE fill+key)

    var isExtended: Bool {
        switch self {
        case .standalone: false
        case .extended, .confidenceOverlay, .confidencePIP: true
        }
    }

    var confidenceMode: ConfidenceMode? {
        switch self {
        case .confidenceOverlay: .overlay
        case .confidencePIP: .pip
        default: nil
        }
    }
}
