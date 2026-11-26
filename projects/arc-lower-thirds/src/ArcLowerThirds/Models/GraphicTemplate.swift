//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

enum GraphicTemplate: String, Codable, CaseIterable, Identifiable {
    case fullWidth       // Full-width strip: accent name block + dark title block
    case roundedBar      // Like fullWidth but with rounded pill sections + gap
    case stackedBar      // Two stacked bars: name on top, title below, offset
    case boldName        // Floating text with accent underline, no background
    case underlineFade   // Like boldName but with subtle dark gradient backing
    case sideStripe      // Vertical accent bar + stacked text (conference/keynote)
    case cornerBracket   // L-shaped corner frames, no fill (documentary/academic)
    case glassPanel      // Frosted glass blur panel (modern premium)
    case custom          // Pre-rendered background image with positioned text overlay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullWidth:       return "Full Width"
        case .roundedBar:      return "Rounded Bar"
        case .stackedBar:      return "Stacked"
        case .boldName:        return "Bold Name"
        case .underlineFade:   return "Underline Fade"
        case .sideStripe:      return "Side Stripe"
        case .cornerBracket:   return "Corner Bracket"
        case .glassPanel:      return "Glass Panel"
        case .custom:          return "Custom Skin"
        }
    }

    var description: String {
        switch self {
        case .fullWidth:       return "Full-width strip with accent name block"
        case .roundedBar:      return "Rounded pill sections with gap"
        case .stackedBar:      return "Stacked offset name and title bars"
        case .boldName:        return "Large name, no background"
        case .underlineFade:   return "Bold name with soft dark backing"
        case .sideStripe:      return "Vertical bar with stacked text"
        case .cornerBracket:   return "L-shaped bracket frames"
        case .glassPanel:      return "Frosted glass panel"
        case .custom:          return "Background image with positioned text"
        }
    }

    var sfSymbol: String {
        switch self {
        case .fullWidth:       return "rectangle.fill"
        case .roundedBar:      return "capsule.fill"
        case .stackedBar:      return "rectangle.stack.fill"
        case .boldName:        return "textformat.size.larger"
        case .underlineFade:   return "text.below.photo"
        case .sideStripe:      return "line.3.horizontal"
        case .cornerBracket:   return "viewfinder"
        case .glassPanel:      return "rectangle.on.rectangle"
        case .custom:          return "photo.on.rectangle"
        }
    }
}
