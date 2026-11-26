//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import AVFoundation

// A file closed cleanly carries the encoder delay (2112 samples) and decoders drop it. After a kill the
// fragments do not, so every sample decodes 2112 late: 132 ms at 16 kHz, measured. The importer trims it
// when the stream start is 0 (ffprobe start_time 0.132 on a clean file, 0 on a killed one).

/// Sync-grade sound: AAC mono at 16 kHz, 24 kb/s, in an MPEG-4 audio file written with a fragment every 2 s,
/// so a crash or a kill leaves a file that plays to the last fragment (about 11 MB an hour). The track is a plain sample count
/// from its first sample: append in order, silence included.
final class AacTrackWriter {
    let url: URL
    let sampleRate: Double
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: AVAudioFormat
    private(set) var framesWritten: Int64 = 0
    private(set) var dropped = 0

    init(url: URL, sampleRate: Double = 16_000, bitRate: Int = 24_000) throws {
        self.url = url; self.sampleRate = sampleRate
        format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(url: url, fileType: .m4a)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: bitRate]
        guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
            throw NSError(domain: "ArcSlideLog", code: 20, userInfo: [NSLocalizedDescriptionKey: "AAC \(Int(sampleRate)) Hz mono \(bitRate / 1000) kb/s is not available"])
        }
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "ArcSlideLog", code: 21, userInfo: [NSLocalizedDescriptionKey: "the sound file could not be started"]) }
        writer.startSession(atSourceTime: .zero)
    }

    /// Mono 16-bit samples at the writer's rate.
    func append(_ samples: UnsafePointer<Int16>, count: Int) throws {
        guard count > 0 else { return }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        buf.frameLength = AVAudioFrameCount(count)
        buf.int16ChannelData![0].update(from: samples, count: count)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: CMTime(value: framesWritten, timescale: CMTimeScale(sampleRate)),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        var st = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                      formatDescription: format.formatDescription, sampleCount: CMItemCount(count), sampleTimingEntryCount: 1,
                                      sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        guard st == noErr, let sb else { throw NSError(domain: "ArcSlideLog", code: 22, userInfo: [NSLocalizedDescriptionKey: "sample buffer \(st)"]) }
        st = CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buf.audioBufferList)
        guard st == noErr else { throw NSError(domain: "ArcSlideLog", code: 23, userInfo: [NSLocalizedDescriptionKey: "sample data \(st)"]) }
        // The timeline is the sample count, so a buffer is never dropped: wait (briefly) for the encoder instead.
        var waited = 0
        while !input.isReadyForMoreMediaData && waited < 200 { usleep(1000); waited += 1 }
        if !input.append(sb) { dropped += 1 }
        framesWritten += Int64(count)
    }

    func appendSilence(frames: Int) throws {
        let zero = [Int16](repeating: 0, count: 1600)
        var left = frames
        while left > 0 { let n = min(left, zero.count); try zero.withUnsafeBufferPointer { try append($0.baseAddress!, count: n) }; left -= n }
    }

    /// Finish the file; bounded wait.
    func close(timeout: TimeInterval = 3) {
        guard writer.status == .writing else { return }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }
}
