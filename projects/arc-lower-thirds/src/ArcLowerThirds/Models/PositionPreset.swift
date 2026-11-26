//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

enum PositionPreset: String, Codable, CaseIterable, Identifiable {
    case topLeft
    case topCenter
    case topRight
    case center
    case bottomLeft
    case bottomCenter
    case bottomRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topLeft:      return "Top Left"
        case .topCenter:    return "Top Center"
        case .topRight:     return "Top Right"
        case .center:       return "Center"
        case .bottomLeft:   return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomRight:  return "Bottom Right"
        }
    }

    var sfSymbol: String {
        switch self {
        case .topLeft:      return "rectangle.tophalf.inset.filled"
        case .topCenter:    return "rectangle.tophalf.inset.filled"
        case .topRight:     return "rectangle.tophalf.inset.filled"
        case .center:       return "rectangle.center.inset.filled"
        case .bottomLeft:   return "rectangle.bottomhalf.inset.filled"
        case .bottomCenter: return "rectangle.center.inset.filled"
        case .bottomRight:  return "rectangle.bottomhalf.inset.filled"
        }
    }

    var isTop: Bool {
        switch self {
        case .topLeft, .topCenter, .topRight: return true
        default: return false
        }
    }
}
