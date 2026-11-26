//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

enum GraphicType: String, Codable, CaseIterable, Identifiable {
    case lowerThird    // Name/title bar at bottom of screen
    case ticker        // Scrolling text crawl
    case logoBug       // Persistent corner image/text overlay
    case fullTitle     // Full-screen centered text
    case clock         // Live time display

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lowerThird: return "Lower Third"
        case .ticker:     return "Ticker"
        case .logoBug:    return "Logo Bug"
        case .fullTitle:  return "Full Title"
        case .clock:      return "Clock"
        }
    }

    var sfSymbol: String {
        switch self {
        case .lowerThird: return "text.below.photo"
        case .ticker:     return "arrow.right.circle"
        case .logoBug:    return "photo.circle"
        case .fullTitle:  return "textformat.size"
        case .clock:      return "clock"
        }
    }

    var defaultLayer: GraphicLayer {
        switch self {
        case .lowerThird: return .lowerThird
        case .ticker:     return .ticker
        case .logoBug:    return .logoBug
        case .fullTitle:  return .fullTitle
        case .clock:      return .clock
        }
    }
}
