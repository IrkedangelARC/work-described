import Foundation
import Synchronization

/// Single-producer, single-consumer ring of float samples.
///
/// The audio tap is a real-time thread: it must not allocate, lock, or touch the disk. So the
/// tap only ever copies into this ring, and a writer queue drains it to the file. Indices are
/// monotonic and atomic, so neither side blocks the other.
final class AudioRingBuffer {

    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacity)
        self.storage.initialize(repeating: 0)
    }

    deinit {
        storage.deallocate()
    }

    /// Samples the producer had to throw away because the consumer fell behind.
    var droppedSamples: Int { dropped.load(ordering: .acquiring) }

    var availableToRead: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring)
    }

    func reset() {
        writeIndex.store(0, ordering: .releasing)
        readIndex.store(0, ordering: .releasing)
        dropped.store(0, ordering: .releasing)
    }

    /// Producer side. Real-time safe: no allocation, no locks.
    /// - Returns: false if the ring was too full and the samples were dropped.
    @discardableResult
    func write(_ source: UnsafePointer<Float>, count: Int) -> Bool {
        guard count > 0 else { return true }

        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        guard capacity - (write - read) >= count else {
            dropped.add(count, ordering: .relaxed)
            return false
        }

        let offset = write % capacity
        let firstChunk = min(count, capacity - offset)
        storage.baseAddress!.advanced(by: offset).update(from: source, count: firstChunk)
        if firstChunk < count {
            storage.baseAddress!.update(from: source.advanced(by: firstChunk), count: count - firstChunk)
        }

        writeIndex.store(write + count, ordering: .releasing)
        return true
    }

    /// Consumer side.
    /// - Returns: how many samples were copied out.
    func read(into destination: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let count = min(write - read, maxCount)
        guard count > 0 else { return 0 }

        let offset = read % capacity
        let firstChunk = min(count, capacity - offset)
        destination.update(from: storage.baseAddress!.advanced(by: offset), count: firstChunk)
        if firstChunk < count {
            destination.advanced(by: firstChunk).update(from: storage.baseAddress!, count: count - firstChunk)
        }

        readIndex.store(read + count, ordering: .releasing)
        return count
    }
}
