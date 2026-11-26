import AVFoundation
import XCTest
@testable import ARC_Dictate

/// The channel extraction is the reason this app exists, so it gets the most tests.
final class ChannelExtractorTests: XCTestCase {

    /// `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)` returns nil above two
    /// channels because it cannot infer a layout, so a four-in interface has to be described
    /// by hand. That is the case this whole app exists for, so the tests build it properly.
    private func makeFormat(channels: Int, interleaved: Bool) -> AVAudioFormat {
        let bytesPerSample = UInt32(MemoryLayout<Float>.size)
        let bytesPerFrame = interleaved ? bytesPerSample * UInt32(channels) : bytesPerSample
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: bytesPerSample * 8,
            mReserved: 0)

        let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        return AVAudioFormat(streamDescription: &description, channelLayout: layout)!
    }

    private func makeBuffer(channels: Int,
                            frames: Int,
                            interleaved: Bool,
                            fill: (_ channel: Int, _ frame: Int) -> Float) -> AVAudioPCMBuffer {
        let format = makeFormat(channels: channels, interleaved: interleaved)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData!

        if interleaved {
            for frame in 0..<frames {
                for channel in 0..<channels {
                    data[0][frame * channels + channel] = fill(channel, frame)
                }
            }
        } else {
            for channel in 0..<channels {
                for frame in 0..<frames {
                    data[channel][frame] = fill(channel, frame)
                }
            }
        }
        return buffer
    }

    func testExtractsNonInterleavedChannel() {
        let frames = 64
        let buffer = makeBuffer(channels: 4, frames: frames, interleaved: false) { channel, frame in
            Float(channel) + Float(frame) / 1000
        }

        var destination = [Float](repeating: .nan, count: frames)
        let written = destination.withUnsafeMutableBufferPointer {
            ChannelExtractor.extract(from: buffer, channel: 2, into: $0.baseAddress!, capacity: frames)
        }

        XCTAssertEqual(written, frames)
        for frame in 0..<frames {
            XCTAssertEqual(destination[frame], 2 + Float(frame) / 1000, accuracy: 0.0001)
        }
    }

    func testExtractsInterleavedChannel() {
        let frames = 64
        let buffer = makeBuffer(channels: 4, frames: frames, interleaved: true) { channel, frame in
            Float(channel) + Float(frame) / 1000
        }

        var destination = [Float](repeating: .nan, count: frames)
        let written = destination.withUnsafeMutableBufferPointer {
            ChannelExtractor.extract(from: buffer, channel: 3, into: $0.baseAddress!, capacity: frames)
        }

        XCTAssertEqual(written, frames)
        for frame in 0..<frames {
            XCTAssertEqual(destination[frame], 3 + Float(frame) / 1000, accuracy: 0.0001)
        }
    }

    /// A silent channel next to a loud one must come out silent. This is the downmix bug in
    /// miniature: if extraction ever averaged channels, this test would fail.
    func testSilentChannelStaysSilent() {
        let frames = 128
        let buffer = makeBuffer(channels: 4, frames: frames, interleaved: false) { channel, _ in
            channel == 0 ? 0.9 : 0
        }

        var destination = [Float](repeating: .nan, count: frames)
        destination.withUnsafeMutableBufferPointer {
            _ = ChannelExtractor.extract(from: buffer, channel: 1, into: $0.baseAddress!, capacity: frames)
            XCTAssertEqual(ChannelExtractor.peakDecibels($0.baseAddress!, count: frames), -120)
        }

        destination.withUnsafeMutableBufferPointer {
            _ = ChannelExtractor.extract(from: buffer, channel: 0, into: $0.baseAddress!, capacity: frames)
            XCTAssertEqual(ChannelExtractor.peakDecibels($0.baseAddress!, count: frames), -0.915, accuracy: 0.01)
        }
    }

    func testOutOfRangeChannelWritesNothing() {
        let buffer = makeBuffer(channels: 2, frames: 16, interleaved: false) { _, _ in 0.5 }
        var destination = [Float](repeating: 0, count: 16)
        let written = destination.withUnsafeMutableBufferPointer {
            ChannelExtractor.extract(from: buffer, channel: 5, into: $0.baseAddress!, capacity: 16)
        }
        XCTAssertEqual(written, 0)
    }

    func testRespectsDestinationCapacity() {
        let buffer = makeBuffer(channels: 1, frames: 512, interleaved: false) { _, _ in 0.25 }
        var destination = [Float](repeating: 0, count: 100)
        let written = destination.withUnsafeMutableBufferPointer {
            ChannelExtractor.extract(from: buffer, channel: 0, into: $0.baseAddress!, capacity: 100)
        }
        XCTAssertEqual(written, 100)
    }

    func testPeakDecibelsOfFullScale() {
        var samples: [Float] = [0, -1.0, 0.5]
        samples.withUnsafeMutableBufferPointer {
            XCTAssertEqual(ChannelExtractor.peakDecibels($0.baseAddress!, count: 3), 0, accuracy: 0.001)
        }
    }
}
