//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import SwiftUI

/// Fixed compositing layers for stage output. Ordered bottom-to-top so
/// tickers never cover lower thirds, lower thirds never cover logo bugs, etc.
enum GraphicLayer: String, Codable, CaseIterable, Identifiable, Comparable {
    case ticker       // z-index 0 (bottom of stack)
    case lowerThird   // z-index 1
    case logoBug      // z-index 2
    case fullTitle    // z-index 3
    case clock        // z-index 4 (top of stack)

    var id: String { rawValue }

    var zIndex: Int {
        switch self {
        case .ticker:     return 0
        case .lowerThird: return 1
        case .logoBug:    return 2
        case .fullTitle:  return 3
        case .clock:      return 4
        }
    }

    var displayName: String {
        switch self {
        case .ticker:     return "Ticker"
        case .lowerThird: return "Lower Third"
        case .logoBug:    return "Logo Bug"
        case .fullTitle:  return "Full Title"
        case .clock:      return "Clock"
        }
    }

    var sfSymbol: String {
        switch self {
        case .ticker:     return "arrow.right.circle"
        case .lowerThird: return "text.below.photo"
        case .logoBug:    return "photo.circle"
        case .fullTitle:  return "textformat.size"
        case .clock:      return "clock"
        }
    }

    static func < (lhs: GraphicLayer, rhs: GraphicLayer) -> Bool {
        lhs.zIndex < rhs.zIndex
    }
}

// MARK: - Bug Corner

enum BugCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topLeft:     return "Top Left"
        case .topRight:    return "Top Right"
        case .bottomLeft:  return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    var alignment: Alignment {
        switch self {
        case .topLeft:     return .topLeading
        case .topRight:    return .topTrailing
        case .bottomLeft:  return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}
