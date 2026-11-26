//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
#if os(macOS)
import AppKit
#endif

/// The window as drawn, as a PNG, for the control API. The app draws itself into a bitmap (no
/// screen recording consent involved); the Metal waterfall does not take part in that, so it is
/// rendered separately and laid in where it sits.
@MainActor
enum ScreenCapture {
    static func png(scope: ScopeModel, display: WaterfallDisplay, waterfall: Bool = true) -> Data? {
        #if os(macOS)
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let frame = scope.waterfallFrame
        if waterfall, frame.width > 1, frame.height > 1, let renderer = scope.renderer, let context = NSGraphicsContext(bitmapImageRep: rep) {
            let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
            renderer.display = display
            if let image = renderer.image(width: Int(frame.width * scale), height: Int(frame.height * scale)) {
                // SwiftUI measures from the top, the bitmap from the bottom.
                // The root view starts under the title bar (the safe area).
                let inset = view.safeAreaInsets
                context.cgContext.draw(image, in: CGRect(x: inset.left + frame.minX, y: view.bounds.height - inset.top - frame.maxY,
                                                         width: frame.width, height: frame.height))
                context.flushGraphics()
            }
        }
        return rep.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }
}
