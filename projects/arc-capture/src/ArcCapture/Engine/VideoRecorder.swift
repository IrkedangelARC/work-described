//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AVFoundation
import CoreMedia
import CoreVideo

/// Records CVPixelBuffer frames into an H.264 MOV file using AVAssetWriter.
/// Designed for slide animation capture: start recording when motion is detected,
/// stop when the frame settles, producing one clip per animated slide.
final class VideoRecorder {

    enum RecorderError: LocalizedError {
        case alreadyRecording
        case notRecording
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "Already recording"
            case .notRecording: return "Not currently recording"
            case .writerFailed(let msg): return "Video writer failed: \(msg)"
            }
        }
    }

    // MARK: - State

    private(set) var isRecording = false
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    /// AAC track fed from ScreenCaptureKit's app-audio samples (the deck
    /// had no sound at all before 2026-09-11 23:20).
    private var audioInput: AVAssetWriterInput?
    private(set) var audioSamples: Int = 0
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var frameCount: Int = 0
    private var startTime: CMTime?
    /// Seconds into the clip right now (host clock minus the first frame's
    /// timestamp). nil before the first frame. Valid after stop until the
    /// next start, so a click can be placed on the clip's own timeline.
    func clipTime() -> Double? {
        guard let s = startTime else { return nil }
        let t = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), s).seconds
        return t.isFinite ? max(0, t) : nil
    }
    /// Frames the encoder was not ready for even after a short wait. The old
    /// code dropped these silently; a clip that reads short is this number.
    private(set) var droppedFrames: Int = 0

    /// Frames per second for the output video. Matches capture rate.
    var frameRate: Int = 30

    /// How far behind the SOUND the captured PICTURE runs on this machine, in seconds. ScreenCaptureKit
    /// taps an app's audio as it is played but delivers the window's picture later, so a clip recorded from
    /// PowerPoint has its sound running ahead of its picture by a constant amount: MEASURED 2026-09-17 with
    /// the flash+click reference deck, 590 ms on the Mac Studio and 350 ms on laptop-06, spread 12-20 ms
    /// across seven events, no drift. PowerPoint's own output was in sync in the room, so this is the
    /// recording, not the show. The audio track is written this much later, which lines the two up.
    /// Zero disables it. Set per machine with `--audio-offset MS`; `AVSyncCalibration` remembers it.
    var audioOffsetSeconds: Double = 0

    // MARK: - Start

    /// Begin recording to a new MOV file at the given URL.
    /// Width/height should match the pixel dimensions of incoming buffers.
    func startRecording(to url: URL, width: Int, height: Int) throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        // This machine's measured picture-behind-sound offset, unless a caller set one explicitly.
        if audioOffsetSeconds == 0 { audioOffsetSeconds = AVSyncCalibration.clampedSeconds }

        // Remove existing file if present
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(url: url, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 4,  // ~4 bpp, high quality
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceAttributes
        )

        writer.add(input)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
        ]
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true
        if writer.canAdd(audio) { writer.add(audio); self.audioInput = audio }
        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "Unknown")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.videoInput = input
        self.adaptor = adaptor
        self.audioSamples = 0
        self.outputURL = url
        self.frameCount = 0
        self.startTime = nil
        self.droppedFrames = 0
        self.isRecording = true
    }

    // MARK: - Append Frame

    /// Append a pixel buffer as the next frame. Thread-safe via input.isReadyForMoreMediaData.
    func appendFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard isRecording, let input = videoInput, let adaptor else { return }
        // Give the encoder up to ~25 ms (under one frame at 30 fps) to take
        // the frame before counting it as dropped.
        var waited = 0
        while !input.isReadyForMoreMediaData && waited < 25 {
            usleep(1000); waited += 1
        }
        guard input.isReadyForMoreMediaData else { droppedFrames += 1; return }

        // Real capture timestamps, rebased to the first frame: the frame
        // count as a clock compressed time whenever ScreenCaptureKit sent
        // nothing (static stretches), and audio must share the same clock.
        let presentationTime: CMTime
        if startTime == nil {
            startTime = timestamp
            presentationTime = .zero
        } else {
            presentationTime = CMTimeSubtract(timestamp, startTime!)
            guard presentationTime.seconds >= 0 else { return }
        }

        adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        frameCount += 1
        drainAudio()
    }

    /// Audio buffers waiting for the writer. A buffer is NEVER thrown away: the old guard discarded any
    /// buffer that arrived while the input was momentarily busy, and AVAssetWriter packs AAC contiguously,
    /// so each discarded buffer silently shortened the audio timeline by 21 ms and the sound drifted early
    /// against the picture, worse the longer the movie. MEASURED 2026-09-17 with a flash+click clapper
    /// through this recorder: ScreenCaptureKit delivered 1319 gapless buffers, the guard dropped 3 here and
    /// 2 per 5 s on a loaded run; a 280 s embedded movie captured on laptop-06 came out 0.7 s short of
    /// its picture ("audio misaligned", the operator). Frames already waited for the encoder; audio now queues.
    private var pendingAudio: [CMSampleBuffer] = []
    private let audioLock = NSLock()
    /// Buffers the writer refused outright (a writer error, not readiness). Reported with the clip.
    private(set) var audioRejected: Int = 0

    /// Append an audio sample buffer (from SCStream's .audio output),
    /// rebased to the clip's clock. Samples before the first video frame
    /// are dropped; the track starts with the picture.
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording, audioInput != nil, let start = startTime else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var rebased = CMTimeSubtract(pts, start)
        if audioOffsetSeconds != 0 {
            rebased = CMTimeAdd(rebased, CMTime(seconds: audioOffsetSeconds, preferredTimescale: 48000))
        }
        guard rebased.seconds >= 0 else { return }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer), presentationTimeStamp: rebased, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr, let copy else { return }
        audioLock.lock(); pendingAudio.append(copy); audioLock.unlock()
        drainAudio()
    }

    /// Hand the writer every queued buffer it will take, in order. Called on each audio callback and each
    /// frame (30 times a second), so a buffer that found the input busy waits milliseconds, not forever.
    private func drainAudio() {
        guard let input = audioInput else { return }
        audioLock.lock(); defer { audioLock.unlock() }
        while let next = pendingAudio.first, input.isReadyForMoreMediaData {
            pendingAudio.removeFirst()
            if input.append(next) { audioSamples += 1 } else { audioRejected += 1 }
        }
    }

    /// How many buffers are still waiting (for the stop path and for tests).
    var pendingAudioCount: Int { audioLock.lock(); defer { audioLock.unlock() }; return pendingAudio.count }

    // MARK: - Stop

    /// Finish recording and return the URL of the completed MOV file.
    func stopRecording() async throws -> URL {
        guard isRecording, let writer, let input = videoInput else {
            throw RecorderError.notRecording
        }

        isRecording = false
        // The last audio buffers may still be queued: give the input up to half a second to take them
        // before the track is closed, so a clip never ends short of its sound.
        var waited = 0
        while pendingAudioCount > 0 && waited < 500 { drainAudio(); usleep(1000); waited += 1 }
        if pendingAudioCount > 0 { audioLock.lock(); audioRejected += pendingAudio.count; pendingAudio.removeAll(); audioLock.unlock() }
        input.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "Unknown")
        }

        guard let url = outputURL else {
            throw RecorderError.writerFailed("No output URL")
        }

        // Clean up
        self.writer = nil
        self.videoInput = nil
        self.adaptor = nil

        NSLog("[VideoRecorder] Wrote %d frames, %d audio buffers (%d rejected, audio offset %+.0f ms) to %@", frameCount, audioSamples, audioRejected, audioOffsetSeconds * 1000, url.path)
        return url
    }

    // MARK: - Cancel

    /// Cancel recording and delete the partial file.
    func cancel() {
        isRecording = false
        videoInput?.markAsFinished()
        if let writer {
            writer.cancelWriting()
        }
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        self.writer = nil
        self.videoInput = nil
        self.adaptor = nil
    }
}
