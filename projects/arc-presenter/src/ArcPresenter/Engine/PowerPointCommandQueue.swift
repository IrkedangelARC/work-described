//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import OSAKit
import os

/// Clicker commands to PowerPoint, off the main thread (stability plan 2.1).
///
/// `NSAppleScript.executeAndReturnError` on the main actor blocked the whole
/// console for up to 2 s per click when PowerPoint was slow, and queued clicks
/// stacked behind it (audit R3). This runs the scripts on one serial queue
/// with its own OSAKit language instance (OSA is safe per instance per
/// thread), compiles each verb once, and DROPS a click that has waited more
/// than 300 ms when a newer click is already behind it: a burst during a
/// wedge collapses to the last press instead of replaying every one after
/// PowerPoint wakes up. A single delayed click still goes through.
final class PowerPointCommandQueue: @unchecked Sendable {
    struct Stats: Equatable {
        var pending = 0
        var sent = 0
        var dropped = 0
        var failed = 0
        var lastLatencyMs = 0
        var maxLatencyMs = 0
    }

    static let staleAfter: TimeInterval = 0.3

    private let queue = DispatchQueue(label: "arc.presenter.powerpoint.commands", qos: .userInteractive)
    private let stats = OSAllocatedUnfairLock(initialState: Stats())
    // Queue-only state.
    private var language: OSALanguageInstance?
    private var scripts: [String: OSAScript] = [:]

    var statsSnapshot: Stats { stats.withLock { $0 } }

    /// Pure rule, tested: drop when older than `staleAfter` AND something newer waits.
    nonisolated static func isStale(issued: Date, now: Date, queuedBehind: Int) -> Bool {
        queuedBehind > 0 && now.timeIntervalSince(issued) > staleAfter
    }

    /// Run `source` (compiled once under `key`). `completion` gets the error
    /// text, "dropped" for a stale click, or nil; it is called on the queue.
    func send(_ source: String, key: String, completion: @escaping @Sendable (String?) -> Void) {
        let issued = Date()
        stats.withLock { $0.pending += 1 }
        queue.async { [self] in
            let behind = stats.withLock { $0.pending - 1 }
            if Self.isStale(issued: issued, now: Date(), queuedBehind: behind) {
                stats.withLock { $0.pending -= 1; $0.dropped += 1 }
                completion("dropped: \(Int(Date().timeIntervalSince(issued) * 1000)) ms old with \(behind) newer waiting")
                return
            }
            let script: OSAScript
            if let cached = scripts[key] {
                script = cached
            } else {
                if language == nil, let lang = OSALanguage(forName: "AppleScript") {
                    language = OSALanguageInstance(language: lang)
                }
                let s = OSAScript(source: source, from: nil, languageInstance: language, using: [])
                var compileError: NSDictionary?
                if !s.compileAndReturnError(&compileError) {
                    stats.withLock { $0.pending -= 1; $0.failed += 1 }
                    completion("compile: \(compileError?[OSAScriptErrorMessageKey] ?? "unknown")")
                    return
                }
                scripts[key] = s
                script = s
            }
            let t = Date()
            var runError: NSDictionary?
            script.executeAndReturnError(&runError)
            let ms = Int(Date().timeIntervalSince(t) * 1000)
            stats.withLock {
                $0.pending -= 1; $0.sent += 1; $0.lastLatencyMs = ms; $0.maxLatencyMs = max($0.maxLatencyMs, ms)
                if runError != nil { $0.failed += 1 }
            }
            completion(runError.map { "\($0[OSAScriptErrorMessageKey] ?? $0)" })
        }
    }
}
