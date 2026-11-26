//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Thread-safe shared state for the pointer lock CGEvent tap callback.
/// CGEvent tap callbacks are C function pointers and cannot capture Swift context,
/// so this singleton provides the bridge.
final class PointerLockState: @unchecked Sendable {
    static let shared = PointerLockState()
    private init() {}

    var isActive: Bool = false
    var outputFrame: CGRect?
    var controlFrame: CGRect?
}

/// Esc pressed three times within a second releases the pointer lock from
/// any focus (2026-09-16: the operator hit PTR and had no way back). Shared
/// by the global tap (Presenter not frontmost) and the local monitor.
final class EscapeBurst: @unchecked Sendable {
    static let shared = EscapeBurst()
    private let lock = NSLock()
    private var stamps: [Date] = []
    static let presses = 3
    static let window: TimeInterval = 1.0

    /// Register one Esc press; true when it completes a burst.
    func register(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        stamps = stamps.filter { now.timeIntervalSince($0) <= Self.window }
        stamps.append(now)
        if stamps.count >= Self.presses { stamps.removeAll(); return true }
        return false
    }
}
