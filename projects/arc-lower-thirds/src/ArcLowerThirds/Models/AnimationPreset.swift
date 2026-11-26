//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

enum AnimationPreset: String, Codable, CaseIterable, Identifiable {
    case slideFromLeft
    case slideFromRight
    case fadeUp
    case wipeLeft
    case scaleUp
    case typewriter
    case bounce
    case cut

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .slideFromLeft:  return "Slide Left"
        case .slideFromRight: return "Slide Right"
        case .fadeUp:         return "Fade Up"
        case .wipeLeft:       return "Wipe Left"
        case .scaleUp:        return "Scale Up"
        case .typewriter:     return "Typewriter"
        case .bounce:         return "Bounce"
        case .cut:            return "Cut"
        }
    }

    var sfSymbol: String {
        switch self {
        case .slideFromLeft:  return "arrow.right"
        case .slideFromRight: return "arrow.left"
        case .fadeUp:         return "arrow.up"
        case .wipeLeft:       return "rectangle.lefthalf.inset.filled.arrow.left"
        case .scaleUp:        return "arrow.up.left.and.arrow.down.right"
        case .typewriter:     return "character.cursor.ibeam"
        case .bounce:         return "arrow.up.to.line"
        case .cut:            return "bolt.fill"
        }
    }

    var inDuration: Double {
        switch self {
        case .slideFromLeft, .slideFromRight: return 0.4
        case .fadeUp:                         return 0.5
        case .wipeLeft:                       return 0.35
        case .scaleUp:                        return 0.4
        case .typewriter:                     return 0.6
        case .bounce:                         return 0.5
        case .cut:                            return 0.0
        }
    }

    var outDuration: Double {
        switch self {
        case .slideFromLeft, .slideFromRight: return 0.3
        case .fadeUp:                         return 0.4
        case .wipeLeft:                       return 0.3
        case .scaleUp:                        return 0.25
        case .typewriter:                     return 0.2
        case .bounce:                         return 0.3
        case .cut:                            return 0.0
        }
    }
}
