//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import AVFoundation
@testable import ArcSlideLog

/// The scratch WAV must read correctly even if the process dies mid-session.
final class WavWriterTests: XCTestCase {
    func testHeaderIsTrueAfterEveryFlushNotOnlyAtClose() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(UUID().uuidString).wav")
        let w = try WavWriter(url: url, sampleRate: 16_000, channels: 1, headerInterval: 0)
        let second = Data(repeating: 0x10, count: 32_000)   // one second of 16-bit mono at 16 kHz
        try w.append(second); try w.append(second); try w.append(second)
        // No close: as a crash would leave it.
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, 48_000, "three seconds readable without a close")
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes.count, 44 + 96_000)
        XCTAssertEqual(Array(bytes[0..<4]), Array("RIFF".utf8))
        w.close()
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 48_000)
        try? FileManager.default.removeItem(at: url)
    }

    func testHeaderBytes() {
        let h = WavWriter.header(dataBytes: 1000, sampleRate: 16_000, channels: 1)
        XCTAssertEqual(h.count, 44)
        XCTAssertEqual(h[40], 0xE8); XCTAssertEqual(h[41], 0x03, "data size 1000 little-endian")
        XCTAssertEqual(h[22], 1, "mono"); XCTAssertEqual(h[34], 16, "16-bit")
    }
}
