import XCTest
@testable import ARC_Dictate

final class AudioRingBufferTests: XCTestCase {

    func testRoundTrip() {
        let ring = AudioRingBuffer(capacity: 256)
        var source = (0..<100).map { Float($0) }
        source.withUnsafeMutableBufferPointer {
            XCTAssertTrue(ring.write($0.baseAddress!, count: 100))
        }
        XCTAssertEqual(ring.availableToRead, 100)

        var destination = [Float](repeating: -1, count: 100)
        let read = destination.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, maxCount: 100)
        }
        XCTAssertEqual(read, 100)
        XCTAssertEqual(destination, source)
        XCTAssertEqual(ring.availableToRead, 0)
    }

    /// The wrap is where ring buffers go wrong, so drive the indices well past capacity.
    func testWrapAround() {
        let ring = AudioRingBuffer(capacity: 64)
        var value: Float = 0
        var expected: [Float] = []

        for _ in 0..<20 {
            var block = (0..<24).map { _ -> Float in value += 1; return value }
            block.withUnsafeMutableBufferPointer {
                XCTAssertTrue(ring.write($0.baseAddress!, count: 24))
            }
            expected.append(contentsOf: block)

            var out = [Float](repeating: 0, count: 24)
            let read = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: 24) }
            XCTAssertEqual(read, 24)
            XCTAssertEqual(out, Array(expected.suffix(24)))
        }
    }

    func testOverflowIsReportedAndDropped() {
        let ring = AudioRingBuffer(capacity: 32)
        var block = [Float](repeating: 1, count: 32)
        block.withUnsafeMutableBufferPointer {
            XCTAssertTrue(ring.write($0.baseAddress!, count: 32))
            XCTAssertFalse(ring.write($0.baseAddress!, count: 32))
        }
        XCTAssertEqual(ring.droppedSamples, 32)
        XCTAssertEqual(ring.availableToRead, 32)
    }

    func testPartialReadLeavesRemainder() {
        let ring = AudioRingBuffer(capacity: 128)
        var source = (0..<50).map { Float($0) }
        source.withUnsafeMutableBufferPointer { _ = ring.write($0.baseAddress!, count: 50) }

        var out = [Float](repeating: 0, count: 20)
        let read = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: 20) }
        XCTAssertEqual(read, 20)
        XCTAssertEqual(ring.availableToRead, 30)
    }

    func testResetClearsState() {
        let ring = AudioRingBuffer(capacity: 16)
        var block = [Float](repeating: 1, count: 16)
        block.withUnsafeMutableBufferPointer {
            _ = ring.write($0.baseAddress!, count: 16)
            _ = ring.write($0.baseAddress!, count: 16)
        }
        ring.reset()
        XCTAssertEqual(ring.availableToRead, 0)
        XCTAssertEqual(ring.droppedSamples, 0)
    }

    func testProducerAndConsumerOnSeparateThreads() {
        let ring = AudioRingBuffer(capacity: 4096)
        let total = 200_000
        let finished = expectation(description: "consumed")

        DispatchQueue.global().async {
            var produced = 0
            var block = [Float](repeating: 0, count: 256)
            while produced < total {
                for index in 0..<256 { block[index] = Float((produced + index) % 1000) }
                let written = block.withUnsafeMutableBufferPointer {
                    ring.write($0.baseAddress!, count: 256)
                }
                if written { produced += 256 }
            }
        }

        DispatchQueue.global().async {
            var consumed = 0
            var out = [Float](repeating: 0, count: 512)
            while consumed < total {
                let read = out.withUnsafeMutableBufferPointer {
                    ring.read(into: $0.baseAddress!, maxCount: 512)
                }
                for index in 0..<read {
                    XCTAssertEqual(out[index], Float((consumed + index) % 1000))
                }
                consumed += read
            }
            finished.fulfill()
        }

        wait(for: [finished], timeout: 20)
    }
}
