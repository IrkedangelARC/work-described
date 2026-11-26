//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Selectable sub-elements within a graphic on the editor canvas.
/// Each maps to an inspector section for scroll-to-section on click.
enum CanvasElement: String, CaseIterable, Identifiable, Equatable {
    case wholeGraphic
    case accentBar
    case nameBlock
    case titleBlock
    case logo
    case backgroundImage
    case overlayImage

    var id: String { rawValue }

    /// The inspector section title to scroll to when this element is selected.
    var inspectorSectionID: String {
        switch self {
        case .wholeGraphic:   return "LAYOUT"
        case .accentBar:      return "ELEMENT SIZE"
        case .nameBlock:      return "TEXT"
        case .titleBlock:     return "TEXT"
        case .logo:           return "LOGO"
        case .backgroundImage: return "BACKGROUND IMAGE"
        case .overlayImage:   return "OVERLAY IMAGE"
        }
    }

    var displayName: String {
        switch self {
        case .wholeGraphic:   return "Graphic"
        case .accentBar:      return "Accent Bar"
        case .nameBlock:      return "Name Block"
        case .titleBlock:     return "Title Block"
        case .logo:           return "Logo"
        case .backgroundImage: return "Background"
        case .overlayImage:   return "Overlay"
        }
    }
}
