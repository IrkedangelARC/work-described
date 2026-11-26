//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import os

/// The waterfall's memory: the last `capacity` slices at every banding, in dBFS, unweighted.
///
/// Written by the DSP queue, read by the renderer on the main thread. Each banding is one flat
/// block laid out exactly like the renderer's texture (row = slice number modulo `capacity`),
/// so a whole-history upload is a single copy. The raw slices are never altered by weighting,
/// calibration or ring detection: those are applied when drawing.
final class SliceHistory: @unchecked Sendable {
    static let capacity = 8192
    static let bandCounts = [31, 62, 124, 248]

    private let lock = OSAllocatedUnfairLock()
    private var rows: [[Float]] = SliceHistory.bandCounts.map { [Float](repeating: -200, count: $0 * SliceHistory.capacity) }
    private var total = 0
    private var generation = 0
    private var sliceSeconds = 0.02

    /// Forget everything (a new engine, a new sample rate). Readers see the generation change.
    func reset(sliceInterval: Double) {
        lock.withLock {
            total = 0
            generation += 1
            sliceSeconds = sliceInterval
        }
    }

    /// One slice: the levels at each banding, in `bandCounts` order.
    func append(_ levels: [[Float]]) {
        lock.withLock {
            let row = total % Self.capacity
            for f in 0..<Self.bandCounts.count {
                let n = Self.bandCounts[f]
                levels[f].withUnsafeBufferPointer { src in
                    rows[f].withUnsafeMutableBufferPointer { dst in
                        (dst.baseAddress! + row * n).update(from: src.baseAddress!, count: n)
                    }
                }
            }
            total += 1
        }
    }

    struct State { var total: Int; var generation: Int; var sliceSeconds: Double }
    var state: State { lock.withLock { State(total: total, generation: generation, sliceSeconds: sliceSeconds) } }

    /// Hands `body` the whole block of one banding (`capacity` rows of `bandCounts[index]` levels)
    /// with the lock held, plus the state it belongs to.
    func withRows<T>(_ index: Int, _ body: (UnsafePointer<Float>, State) -> T) -> T {
        lock.withLock {
            rows[index].withUnsafeBufferPointer {
                body($0.baseAddress!, State(total: total, generation: generation, sliceSeconds: sliceSeconds))
            }
        }
    }

    /// A copy of the slice `age` slices back (0 = newest). Nil when it is no longer held.
    func slice(_ index: Int, age: Int) -> [Float]? {
        lock.withLock {
            guard age >= 0, age < min(total, Self.capacity) else { return nil }
            let n = Self.bandCounts[index]
            let row = (total - 1 - age) % Self.capacity
            return Array(rows[index][(row * n)..<(row * n + n)])
        }
    }
}
