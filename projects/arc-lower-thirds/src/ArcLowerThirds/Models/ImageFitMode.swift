//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import SwiftUI

/// How a background or overlay image fits within the graphic frame.
enum ImageFitMode: String, Codable, CaseIterable, Identifiable {
    case fill      // Fill frame, crop excess (default — no letterboxing)
    case fit       // Fit within frame, letterbox if needed
    case stretch   // Stretch to fill (may distort)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fill:    return "Fill"
        case .fit:     return "Fit"
        case .stretch: return "Stretch"
        }
    }

    var sfSymbol: String {
        switch self {
        case .fill:    return "arrow.up.left.and.arrow.down.right"
        case .fit:     return "arrow.down.right.and.arrow.up.left"
        case .stretch: return "arrow.left.and.right"
        }
    }
}

/// Text alignment for custom template text positioning.
enum TextAlignmentOption: String, Codable, CaseIterable, Identifiable {
    case leading
    case center
    case trailing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leading:  return "Left"
        case .center:   return "Center"
        case .trailing: return "Right"
        }
    }

    var alignment: TextAlignment {
        switch self {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }

    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }
}
