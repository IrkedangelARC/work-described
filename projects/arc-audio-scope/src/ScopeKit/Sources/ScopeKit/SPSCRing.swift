//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Synchronization

/// Lock-free single-producer single-consumer ring of Float samples.
///
/// The audio callback is the one producer, the DSP task is the one consumer. Neither side
/// locks or allocates. When the consumer falls behind, NEW samples are dropped and counted
/// (the producer may not move the read index), so a stall shows up as a number, never as a
/// torn buffer. Karaoke's `FloatRing` has the right shape and the wrong locking; this is the
/// replacement named in docs/REUSE_karaoke.md.
public final class SPSCRing: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let head = Atomic<Int>(0)   // total samples written, producer owned
    private let tail = Atomic<Int>(0)   // total samples read, consumer owned
    private let droppedCount = Atomic<Int>(0)

    /// `minimumCapacity` is rounded up to a power of two.
    public init(minimumCapacity: Int) {
        var c = 2
        while c < minimumCapacity { c <<= 1 }
        capacity = c
        mask = c - 1
        storage = .allocate(capacity: c)
        storage.initialize(repeating: 0, count: c)
    }

    deinit { storage.deallocate() }

    /// Samples waiting to be read.
    public var available: Int { head.load(ordering: .acquiring) - tail.load(ordering: .acquiring) }

    /// Samples the producer had to drop because the ring was full.
    public var dropped: Int { droppedCount.load(ordering: .relaxed) }

    /// Producer side. Returns the number of samples stored.
    @discardableResult
    public func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let free = capacity - (h - t)
        let n = min(count, free)
        if n < count { droppedCount.add(count - n, ordering: .relaxed) }
        guard n > 0 else { return 0 }
        let start = h & mask
        let first = min(n, capacity - start)
        (storage + start).update(from: source, count: first)
        if first < n { storage.update(from: source + first, count: n - first) }
        head.store(h + n, ordering: .releasing)
        return n
    }

    /// Consumer side. Returns the number of samples copied out.
    @discardableResult
    public func read(into destination: UnsafeMutablePointer<Float>, max: Int) -> Int {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let n = min(max, h - t)
        guard n > 0 else { return 0 }
        let start = t & mask
        let first = min(n, capacity - start)
        destination.update(from: storage + start, count: first)
        if first < n { (destination + first).update(from: storage, count: n - first) }
        tail.store(t + n, ordering: .releasing)
        return n
    }

    /// Consumer side: throw away everything waiting (after a device change).
    public func drain() {
        tail.store(head.load(ordering: .acquiring), ordering: .releasing)
    }
}
