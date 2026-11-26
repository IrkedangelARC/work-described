//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import Foundation
import CoreVideo

/// Frames arrive on the SDK's thread at ~25 fps per subscription. Delivering each one as its own
/// main-actor task queued without bound whenever the main thread stalled, and the 3-deep buffer ring was
/// recycled under frames still waiting to be drawn (tearing). Keep the LATEST frame per id and at most one
/// pending drain: the main actor always draws the newest picture and never works through a backlog.
final class FrameCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [UInt32: CVPixelBuffer] = [:]
    private var scheduled = false
    private let deliver: @MainActor (UInt32, CVPixelBuffer) -> Void
    init(deliver: @escaping @MainActor (UInt32, CVPixelBuffer) -> Void) { self.deliver = deliver }
    func push(_ id: UInt32, _ buffer: CVPixelBuffer) {
        lock.lock(); latest[id] = buffer; let go = !scheduled; scheduled = true; lock.unlock()
        guard go else { return }
        Task { @MainActor in
            self.lock.lock(); let batch = self.latest; self.latest = [:]; self.scheduled = false; self.lock.unlock()
            for (id, b) in batch { self.deliver(id, b) }
        }
    }
}
