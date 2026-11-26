//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ARCDeckLink

final class ARCDeckLinkTests: XCTestCase {

    func testDriverProbeDoesNotCrash() {
        // Whether or not Desktop Video is installed, the probe must be safe.
        _ = DeckLinkFillKeyOutput.isDriverInstalled
    }

    func testDeviceEnumerationDoesNotCrash() {
        let devices = DeckLinkFillKeyOutput.devices()
        // With no hardware attached this is empty; with hardware, every
        // returned device must be playback-capable by contract.
        for device in devices {
            XCTAssertTrue(device.supportsPlayback)
            XCTAssertFalse(device.name.isEmpty)
        }
    }

    func testStartWithBogusDeviceFailsGracefully() {
        let output = DeckLinkFillKeyOutput()
        XCTAssertThrowsError(try output.start(devicePersistentID: -999,
                                              width: 1920,
                                              height: 1080,
                                              fps: 60,
                                              keyer: .externalKey))
        XCTAssertFalse(output.isRunning)
    }

    func testSendWithoutStartIsNoOp() {
        let output = DeckLinkFillKeyOutput()
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080,
                            kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        output.send(fill: pixelBuffer!)
        XCTAssertEqual(output.sentFrames, 0)
    }
}
