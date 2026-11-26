//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AppKit

@MainActor
@Observable
final class PageCache {
    private(set) var images: [Int: NSImage] = [:]
    private(set) var isLoading: Bool = false
    private(set) var progress: Double = 0

    func imageFor(page: Int) -> NSImage? {
        images[page]
    }

    func loadFrom(images: [Int: NSImage], isLoading: Bool, progress: Double) {
        self.images = images
        self.isLoading = isLoading
        self.progress = progress
    }

    func clear() {
        images.removeAll()
        isLoading = false
        progress = 0
    }
}
