//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Reported bounds of a single canvas sub-element.
struct ElementBounds: Equatable {
    let element: CanvasElement
    let rect: CGRect
}

/// Aggregates sub-element bounds reported by templates during the layout pass.
/// Used by CanvasPreview to position tap targets and resize handles.
struct ElementBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: [ElementBounds] = []

    static func reduce(value: inout [ElementBounds], nextValue: () -> [ElementBounds]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Reports this view's bounds as a canvas element when `active` is true.
    /// When false, returns the view unmodified (no overhead in stage output).
    @ViewBuilder
    func reportElementBounds(_ element: CanvasElement, in space: String = "canvas", active: Bool = true) -> some View {
        if active {
            self.background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ElementBoundsPreferenceKey.self,
                        value: [ElementBounds(element: element, rect: geo.frame(in: .named(space)))]
                    )
                }
            )
        } else {
            self
        }
    }
}
