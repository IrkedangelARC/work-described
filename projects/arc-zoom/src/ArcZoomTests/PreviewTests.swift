//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import AVFoundation
@testable import ArcZoom

/// The PREVIEW module (2026-09-24) without a meeting: the I420 the raw share sends, the audio packing, the frame
/// and audio timing, the transport, ffmpeg's locate / plan / progress, and the whole FILE path into a recording
/// sink (decode, NV12 -> I420, the tap, 10 ms chunks). Only the SDK's two senders are left for the live test.
final class PreviewTests: XCTestCase {

    // MARK: I420

    func testNV12BecomesI420WithTheStridePaddingDropped() {
        // 4 x 2 picture, Y stride 6 (2 bytes of padding per row), CbCr stride 6 (one pair of padding).
        let y: [UInt8] = [10, 11, 12, 13, 99, 99,
                          20, 21, 22, 23, 99, 99]
        let uv: [UInt8] = [100, 200, 101, 201, 99, 99]
        var out = [UInt8](repeating: 0, count: I420.byteCount(width: 4, height: 2))
        y.withUnsafeBufferPointer { yp in uv.withUnsafeBufferPointer { up in out.withUnsafeMutableBufferPointer { op in
            I420.fromNV12(y: yp.baseAddress!, yStride: 6, uv: up.baseAddress!, uvStride: 6, width: 4, height: 2, into: op.baseAddress!)
        } } }
        XCTAssertEqual(out, [10, 11, 12, 13, 20, 21, 22, 23, /* U */ 100, 101, /* V */ 200, 201])
    }

    /// BT.709 video range, the reference values for solid colours.
    func testBGRASolidColoursGiveTheBT709VideoRangeValues() {
        func convert(_ b: UInt8, _ g: UInt8, _ r: UInt8) -> (UInt8, UInt8, UInt8) {
            let px: [UInt8] = Array(repeating: [b, g, r, 255], count: 4).flatMap { $0 }   // 2 x 2
            var out = [UInt8](repeating: 0, count: I420.byteCount(width: 2, height: 2))
            px.withUnsafeBufferPointer { s in out.withUnsafeMutableBufferPointer { o in I420.fromBGRA(s.baseAddress!, stride: 8, width: 2, height: 2, into: o.baseAddress!) } }
            XCTAssertEqual(Set(out[0..<4]).count, 1, "a solid colour has one luma")
            return (out[0], out[4], out[5])
        }
        func near(_ got: (UInt8, UInt8, UInt8), _ want: (Int, Int, Int), _ name: String) {
            XCTAssertEqual(Int(got.0), want.0, accuracy: 1, "\(name) Y"); XCTAssertEqual(Int(got.1), want.1, accuracy: 1, "\(name) U"); XCTAssertEqual(Int(got.2), want.2, accuracy: 1, "\(name) V")
        }
        near(convert(255, 255, 255), (235, 128, 128), "white")
        near(convert(0, 0, 0), (16, 128, 128), "black")
        near(convert(0, 0, 255), (63, 102, 240), "red")
        near(convert(0, 255, 0), (173, 42, 26), "green")
        near(convert(255, 0, 0), (32, 240, 118), "blue")
    }

    func testTheShareSizeFitsInside1080pAndIsEven() {
        XCTAssertTrue(I420.shareSize(natural: CGSize(width: 3840, height: 2160)) == (1920, 1080))
        XCTAssertTrue(I420.shareSize(natural: CGSize(width: 1919, height: 1079)) == (1918, 1078))
        XCTAssertTrue(I420.shareSize(natural: CGSize(width: 720, height: 1280)) == (606, 1080), "portrait keeps its aspect")
        XCTAssertTrue(I420.shareSize(natural: CGSize(width: 640, height: 480)) == (640, 480), "never upscaled")
        XCTAssertEqual(I420.byteCount(width: 1920, height: 1080), 3_110_400)
    }

    // MARK: Audio

    func testTheSendRateIsTheFilesWhenZoomTakesItElse48k() {
        XCTAssertEqual(ShareAudio.sendRate(for: 44100), 44100)
        XCTAssertEqual(ShareAudio.sendRate(for: 48000), 48000)
        XCTAssertEqual(ShareAudio.sendRate(for: 32000), 48000)
        XCTAssertEqual(ShareAudio.sendRate(for: 96000), 48000)
        XCTAssertEqual(ShareAudio.sendChannels(for: 1), 1)
        XCTAssertEqual(ShareAudio.sendChannels(for: 6), 2)
        XCTAssertEqual(ShareAudio.chunkFrames(rate: 44100), 441)
        XCTAssertEqual(ShareAudio.chunkFrames(rate: 48000), 480)
    }

    func testFloatPlanesInterleaveToInt16Clipped() {
        XCTAssertEqual(ShareAudio.interleave([[0.5, -1.5], [0, 1]], channels: 2), [16384, 0, -32767, 32767])
        XCTAssertEqual(ShareAudio.interleave([[1, 0]], channels: 2), [32767, 32767, 0, 0], "mono duplicated to stereo")
        XCTAssertEqual(ShareAudio.interleave([[0.25], [0.5], [1]], channels: 2), [8192, 16384], "extra channels dropped")
    }

    func testCaptureAudioConvertsAndRemapsToStereo() {
        XCTAssertEqual(ShareAudio.int16(interleavedFloat: [0.5, -0.5, 1, -1], inChannels: 2, outChannels: 2), [16384, -16384, 32767, -32767])
        XCTAssertEqual(ShareAudio.int16(interleavedFloat: [0.5, 1], inChannels: 1, outChannels: 2), [16384, 16384, 32767, 32767])
        XCTAssertEqual(ShareAudio.remap(int16: [1, 2, 3, 4, 5, 6, 7, 8], inChannels: 4, outChannels: 2), [1, 2, 5, 6])
        XCTAssertEqual(ShareAudio.remap(int16: [7, 9], inChannels: 1, outChannels: 2), [7, 7, 9, 9])
        XCTAssertEqual(ShareAudio.peak(int16: [0, -32767, 100]), 1, accuracy: 0.0001)
    }

    func testTheChunkerSendsExact10msChunksAndCarriesTheRest() {
        var c = AudioChunker(channels: 2, rate: 48000)
        XCTAssertEqual(c.push([Int16](repeating: 1, count: 1000)).map(\.count), [960])
        XCTAssertEqual(c.pending.count, 40)
        XCTAssertEqual(c.push([Int16](repeating: 2, count: 920 + 1920)).map(\.count), [960, 960, 960])
        XCTAssertEqual(c.pending.count, 0)
        _ = c.push([1, 2]); c.reset(); XCTAssertTrue(c.pending.isEmpty, "a seek drops the old position's samples")
    }

    func testTheMeterMapsMinus60To0dB() {
        XCTAssertEqual(ShareAudio.meterLevel(peak: 1), 1, accuracy: 0.001)
        XCTAssertEqual(ShareAudio.meterLevel(peak: 0.001), 0, accuracy: 0.001)
        XCTAssertEqual(ShareAudio.meterLevel(peak: 0.0316), 0.5, accuracy: 0.01)
        XCTAssertEqual(ShareAudio.meterLevel(peak: 0), 0)
    }

    // MARK: Timing

    func testTheVideoFollowsTheAudioLead() {
        var s = AVSyncClock()
        XCTAssertEqual(s.videoTime(playerNow: 10), 10, "no lead before the tap speaks")
        s.observe(audioEnd: 10.1, playerNow: 10.0)
        XCTAssertEqual(s.lead, 0.1, accuracy: 1e-9)
        XCTAssertEqual(s.videoTime(playerNow: 12), 12.1, accuracy: 1e-9)
        s.observe(audioEnd: 11.1, playerNow: 11.05)   // smoothed, not jumped
        XCTAssertEqual(s.lead, 0.095, accuracy: 1e-9)
        s.observe(audioEnd: 40, playerNow: 11)
        XCTAssertLessThanOrEqual(s.lead, AVSyncClock.maxLead)
        s.reset(); XCTAssertEqual(s.lead, 0)
        s.observe(audioEnd: 5, playerNow: 5.2)
        XCTAssertEqual(s.lead, 0, "audio behind the clock (a seek) is no lead")
    }

    /// The file's sound leaves on the player's clock, not when the tap hands it over (~0.4 s early).
    func testAudioIsReleasedWhenThePlayerReachesIt() {
        var q = AudioReleaseQueue()
        for k in 0..<50 { q.push(.init(time: 10 + Double(k) * 0.01, samples: [Int16(k)], rate: 48000, channels: 2)) }   // 10.00 ... 10.49
        XCTAssertTrue(q.due(upTo: 9.99).isEmpty, "nothing before its time")
        XCTAssertEqual(q.due(upTo: 10.045).map { $0.samples[0] }, [0, 1, 2, 3, 4])
        XCTAssertTrue(q.due(upTo: 10.045).isEmpty, "each chunk leaves once")
        XCTAssertEqual(q.chunks.count, 45, "paused: the rest waits")
        XCTAssertEqual(q.due(upTo: 11.2).count, 0, "more than 0.5 s late is dropped, not sent late")
        XCTAssertTrue(q.chunks.isEmpty)
        for k in 0..<(AudioReleaseQueue.cap + 20) { q.push(.init(time: Double(k), samples: [], rate: 48000, channels: 2)) }
        XCTAssertEqual(q.chunks.count, AudioReleaseQueue.cap, "capped")
        q.flush(); XCTAssertTrue(q.chunks.isEmpty, "a seek flushes")
    }

    func testThePacerSends30fpsAndHoldsAPausedPicture() {
        let p = FramePacer()
        XCTAssertEqual(p.decide(now: 0, lastSent: nil, hasNew: true), .send)
        XCTAssertEqual(p.decide(now: 0, lastSent: nil, hasNew: false), .skip)
        XCTAssertEqual(p.decide(now: 0.010, lastSent: 0, hasNew: true), .skip, "a 60 fps file is sent at 30")
        XCTAssertEqual(p.decide(now: 0.033, lastSent: 0, hasNew: true), .send)
        XCTAssertEqual(p.decide(now: 0.100, lastSent: 0, hasNew: false), .skip)
        XCTAssertEqual(p.decide(now: 0.200, lastSent: 0, hasNew: false), .resend, "paused: the frame again every 0.2 s")
        // By VIDEO time (2026-09-24 live: 26.6-27.1 of 29.97 fps sent under the wall-clock cap).
        let ntsc = 1001.0 / 30000
        XCTAssertEqual(p.decide(now: 0.020, lastSent: 0, hasNew: true, itemTime: ntsc, lastItemTime: 0), .send,
                       "a 29.97 fps frame goes out even when the tick sees it 20 ms after the last send")
        XCTAssertEqual(p.decide(now: 0.016, lastSent: 0, hasNew: true, itemTime: 1.0 / 60, lastItemTime: 0), .skip, "60 fps is still halved")
        XCTAssertEqual(p.decide(now: 0.033, lastSent: 0, hasNew: true, itemTime: 2.0 / 60, lastItemTime: 0), .send)
        XCTAssertEqual(p.decide(now: 0.010, lastSent: 0, hasNew: true, itemTime: 0, lastItemTime: 30), .send, "a loop back to the top always sends")
    }

    func testTheAlignerHoldsTheFasterStreamForTheSlowerOne() {
        var a = CaptureAligner()
        a.observe(.video, captured: 1.000, arrived: 1.060)
        a.observe(.audio, captured: 1.000, arrived: 1.015)
        XCTAssertEqual(a.target, 0.060 + CaptureAligner.margin, accuracy: 1e-9)
        XCTAssertEqual(a.audioHold, 0.045, accuracy: 1e-9)
        XCTAssertEqual(a.release(captured: 2.0), 2.070, accuracy: 1e-9, "both streams leave at capture + the slower latency")
        a.observe(.video, captured: 2.0, arrived: 2.100)
        XCTAssertEqual(a.videoLatency!, 0.100, accuracy: 1e-9, "a later frame is believed at once")
        a.observe(.video, captured: 3.0, arrived: 3.020)
        XCTAssertGreaterThan(a.videoLatency!, 0.095, "one quick frame does not drop the hold")
        a.observe(.video, captured: 4.0, arrived: 9.0)
        XCTAssertEqual(a.target, CaptureAligner.maxTarget, "a stalled stream cannot hold the other by seconds")
        var v = CaptureAligner()
        v.observe(.video, captured: 0, arrived: 0.05)
        XCTAssertEqual(v.target, 0.05 + CaptureAligner.margin, accuracy: 1e-9, "video only: it goes out as it comes")
    }

    func testTheClockReads() {
        XCTAssertEqual(PreviewTime.clock(7.9), "0:07")
        XCTAssertEqual(PreviewTime.clock(3723), "1:02:03")
        XCTAssertEqual(PreviewTime.clock(.nan), "0:00")
        XCTAssertEqual(PreviewTime.remaining(position: 7, duration: 30), "\u{2212}0:23")
        XCTAssertEqual(PreviewTime.remaining(position: 40, duration: 30), "\u{2212}0:00")
        XCTAssertEqual(PreviewTime.clampSeek(-5, duration: 30), 0)
        XCTAssertEqual(PreviewTime.clampSeek(100, duration: 30), 29.95, accuracy: 1e-9)
        XCTAssertEqual(PreviewTime.clampSeek(.nan, duration: 30), 0)
        XCTAssertEqual(PreviewTime.clampSeek(3, duration: 0), 0)
    }

    // MARK: The transport

    func testTheTransportStateMachine() {
        var t = PreviewTransport()
        XCTAssertEqual(t.handle(.play), .none, "nothing loaded: play does nothing")
        XCTAssertEqual(t.handle(.load), .pause); XCTAssertEqual(t.phase, .loading)
        t.handle(.converting(1.7)); XCTAssertEqual(t.phase, .converting(1)); XCTAssertEqual(t.word, "CONVERTING 100%")
        XCTAssertEqual(t.handle(.seek(3)), .none, "no seek before the file is loaded")
        XCTAssertEqual(t.handle(.loaded(duration: 30)), .seek(0)); XCTAssertEqual(t.phase, .paused)
        XCTAssertEqual(t.handle(.play), .play); XCTAssertTrue(t.isPlaying)
        XCTAssertEqual(t.handle(.toggle), .pause); XCTAssertEqual(t.phase, .paused)
        XCTAssertEqual(t.handle(.toggle), .play)
        XCTAssertEqual(t.handle(.seek(100)), .seek(29.95), "a scrub past the end lands on the last frame")
        XCTAssertTrue(t.isPlaying, "seeking keeps playing")
        XCTAssertEqual(t.handle(.restart), .seekAndPlay(0))
        XCTAssertEqual(t.handle(.reachedEnd), .pause); XCTAssertEqual(t.phase, .ended)
        XCTAssertEqual(t.handle(.play), .seekAndPlay(0), "PLAY at the end starts again")
        t.loop = true
        XCTAssertEqual(t.handle(.reachedEnd), .seekAndPlay(0)); XCTAssertTrue(t.isPlaying, "a looping file keeps playing")
        t.loop = false
        t.handle(.reachedEnd)
        XCTAssertEqual(t.handle(.seek(5)), .seek(5)); XCTAssertEqual(t.phase, .paused, "a scrub from ENDED is paused there")
        XCTAssertEqual(t.handle(.restart), .seek(0), "restart while paused stays paused")
        t.handle(.failed("nope")); XCTAssertEqual(t.phase, .failed("nope")); XCTAssertFalse(t.isLoaded)
        t.handle(.unload); XCTAssertEqual(t.phase, .empty); XCTAssertEqual(t.duration, 0)
    }

    // MARK: ffmpeg

    func testFFmpegPrefersARCsOwnCopies() {
        let c = FFmpeg.candidates(apps: ["/Applications/Zeta.app", "/Applications/ARC Grab.app", "/Users/you/Desktop/ARC Capture.app"])
        XCTAssertEqual(c.first, "/Applications/ARC Grab.app/Contents/MacOS/ffmpeg")
        XCTAssertTrue(c.firstIndex(of: "/Users/you/Desktop/ARC Capture.app/Contents/Resources/bin/ffmpeg")! < c.firstIndex(of: "/Applications/Zeta.app/Contents/MacOS/ffmpeg")!)
        XCTAssertEqual(c.suffix(2), ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
        let found = FFmpeg.locate(apps: ["/Applications/Zeta.app", "/Users/you/Desktop/ARC Capture.app"]) { $0 == "/Users/you/Desktop/ARC Capture.app/Contents/Resources/bin/ffmpeg" || $0 == "/opt/homebrew/bin/ffmpeg" }
        XCTAssertEqual(found, "/Users/you/Desktop/ARC Capture.app/Contents/Resources/bin/ffmpeg")
        XCTAssertNil(FFmpeg.locate(apps: []) { _ in false })
    }

    func testTheProbeIsRead() {
        let text = """
        Input #0, matroska,webm, from 'talk.mkv':
          Duration: 00:01:02.34, start: 0.000000, bitrate: 2400 kb/s
          Stream #0:0(eng): Video: vp9 (Profile 0), yuv420p(tv, bt709), 1920x1080, SAR 1:1 DAR 16:9, 30 fps
          Stream #0:1(eng): Audio: opus, 48000 Hz, stereo, fltp (default)
          Stream #0:2: Audio: aac (LC), 44100 Hz, stereo
        """
        let p = FFmpeg.parseProbe(text)
        XCTAssertEqual(p.duration!, 62.34, accuracy: 1e-9)
        XCTAssertEqual(p.video, "vp9"); XCTAssertEqual(p.audio, "opus", "the FIRST audio stream")
        XCTAssertNil(FFmpeg.parseStamp("N/A"))
        XCTAssertEqual(FFmpeg.plan(for: p), .full)
        XCTAssertEqual(FFmpeg.plan(for: .init(duration: 1, video: "h264", audio: "aac")), .remux)
        XCTAssertEqual(FFmpeg.plan(for: .init(duration: 1, video: "h264", audio: "opus")), .remux, "Opus plays straight out of an mp4")
        XCTAssertEqual(FFmpeg.plan(for: .init(duration: 1, video: "h264", audio: "vorbis")), .audioOnly)
        XCTAssertEqual(FFmpeg.plan(for: .init(duration: 1, video: "hevc", audio: nil)), .remux, "no sound is not a reason to convert")
    }

    func testTheCommandLines() {
        let remux = FFmpeg.arguments(input: "/in/a.mkv", output: "/tmp/a.mp4", plan: .remux, hevc: true)
        XCTAssertEqual(Array(remux.prefix(5)), ["-hide_banner", "-nostdin", "-y", "-i", "/in/a.mkv"])
        XCTAssertTrue(remux.contains("copy") && remux.contains("hvc1"))
        XCTAssertEqual(Array(remux.suffix(5)), ["+faststart", "-progress", "pipe:1", "-nostats", "/tmp/a.mp4"])
        let audio = FFmpeg.arguments(input: "i", output: "o", plan: .audioOnly)
        XCTAssertTrue(audio.joined(separator: " ").contains("-c:v copy -c:a aac"))
        XCTAssertFalse(audio.contains("hvc1"))
        let full = FFmpeg.arguments(input: "i", output: "o", plan: .full, encoders: " V....D h264_videotoolbox  VideoToolbox H.264 Encoder")
        XCTAssertTrue(full.joined(separator: " ").contains("-c:v h264_videotoolbox"))
        XCTAssertEqual(FFmpeg.videoEncoder("libx264")[1], "libx264")
        XCTAssertEqual(FFmpeg.videoEncoder("")[1], "mpeg4")
        XCTAssertTrue(full.contains("0:a:0?"), "a file with no sound still converts")
        XCTAssertTrue(full.contains("videotoolbox") && full.joined(separator: " ").contains("min(1080,ih)"), "a full re-encode decodes in hardware and never exceeds 1080p")
        XCTAssertFalse(remux.contains("-hwaccel"), "a remux decodes nothing")
    }

    func testProgressAndTheOutputName() {
        XCTAssertEqual(FFmpeg.progress(line: "out_time_us=31170000", duration: 62.34)!, 0.5, accuracy: 0.001)
        XCTAssertEqual(FFmpeg.progress(line: "out_time_ms=62340000", duration: 62.34)!, 1, accuracy: 0.001)
        XCTAssertNil(FFmpeg.progress(line: "frame=100", duration: 62.34))
        XCTAssertNil(FFmpeg.progress(line: "out_time_us=5", duration: nil))
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let a = FFmpeg.outputName(for: "/Movies/my talk (final).mkv", modified: d)
        XCTAssertEqual(a, FFmpeg.outputName(for: "/Movies/my talk (final).mkv", modified: d), "stable: converted once")
        XCTAssertNotEqual(a, FFmpeg.outputName(for: "/Movies/my talk (final).mkv", modified: d.addingTimeInterval(60)), "an edited file converts again")
        XCTAssertTrue(a.hasPrefix("my_talk__final_-") && a.hasSuffix(".mp4"))
        XCTAssertTrue(PreviewFormats.needsConversion(URL(fileURLWithPath: "/a.MKV")))
        XCTAssertFalse(PreviewFormats.needsConversion(URL(fileURLWithPath: "/a.M4V")))
    }

    // MARK: The whole FILE path, into a recording sink (no meeting, no SDK)

    final class RecordingSink: ShareSink, @unchecked Sendable {
        let lock = NSLock()
        var frames = 0, chunks = 0
        var size = (0, 0), firstLuma: UInt8 = 0, firstU: UInt8 = 0
        var rate = 0, channels = 0, chunkLen = 0, peak: Int16 = 0
        func sendFrame(_ bytes: UnsafeMutablePointer<UInt8>, count: Int, width: Int, height: Int, fullRange: Bool) {
            lock.lock(); defer { lock.unlock() }
            XCTAssertEqual(count, I420.byteCount(width: width, height: height))
            frames += 1; size = (width, height); firstLuma = bytes[width * height / 2 + width / 2]; firstU = bytes[width * height + (width / 2) * (height / 4)]
        }
        func sendAudio(_ samples: [Int16], rate: Int, channels: Int) {
            lock.lock(); defer { lock.unlock() }
            chunks += 1; self.rate = rate; self.channels = channels; chunkLen = samples.count
            peak = max(peak, samples.map { $0 == .min ? .max : abs($0) }.max() ?? 0)
        }
    }

    /// An mkv made by the ffmpeg the app would find (white 320 x 240 at 30 fps, a 1 kHz tone at 44.1 kHz stereo):
    /// the module converts it (remux: h264 + aac), plays it muted locally, and the sink receives I420 frames of
    /// the right size and value and exact 10 ms chunks at 44.1 kHz, all while the local monitor is silent.
    @MainActor
    func testAnMKVConvertsPlaysAndFeedsTheSink() async throws {
        guard let ffmpeg = PreviewPlayer.locateFFmpeg() else { throw XCTSkip("no ffmpeg on this Mac") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arczoom-preview-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mkv = dir.appendingPathComponent("clip.mkv")
        let gen = PreviewPlayer.run(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-f", "lavfi", "-i", "color=c=white:s=320x240:r=30:d=4",
                                             "-f", "lavfi", "-i", "sine=f=1000:r=44100:d=4", "-ac", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                                             "-c:a", "aac", "-shortest", mkv.path])
        if gen.status != 0 {   // an ffmpeg without libx264 (ARC Grab's is LGPL): VideoToolbox
            let vt = PreviewPlayer.run(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-f", "lavfi", "-i", "color=c=white:s=320x240:r=30:d=4",
                                                "-f", "lavfi", "-i", "sine=f=1000:r=44100:d=4", "-ac", "2", "-c:v", "h264_videotoolbox", "-pix_fmt", "yuv420p",
                                                "-c:a", "aac", "-shortest", mkv.path])
            guard vt.status == 0 else { throw XCTSkip("this ffmpeg cannot make the test clip: \(vt.stderr.suffix(200))") }
        }
        let p = PreviewPlayer()
        p.monitorMuted = true   // the tap zeroes the local output: the test is silent, the sink is not
        p.loadFile(mkv)
        let deadline = Date().addingTimeInterval(30)
        var sawConverting = false
        while !p.transport.isLoaded, Date() < deadline {
            if case .converting = p.transport.phase { sawConverting = true }
            if case .failed(let why) = p.transport.phase { XCTFail("failed: \(why)"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(p.transport.isLoaded, "never loaded: \(p.transport.word) \(p.note ?? "")")
        XCTAssertTrue(sawConverting || p.note?.contains("converted") == true, "an mkv goes through ffmpeg")
        XCTAssertEqual(p.playURL?.pathExtension, "mp4")
        XCTAssertEqual(p.transport.duration, 4, accuracy: 0.2)
        let sink = RecordingSink()
        p.attach(sink)
        p.play()
        try await Task.sleep(for: .seconds(2))
        p.pause()
        let playedFrames = sink.lock.withLock { sink.frames }
        let playedChunks = sink.lock.withLock { sink.chunks }
        try await Task.sleep(for: .milliseconds(600))
        p.detachShare()
        sink.lock.lock(); defer { sink.lock.unlock() }
        print("PREVIEW PIPELINE frames \(sink.frames) (\(playedFrames) while playing) size \(sink.size) luma \(sink.firstLuma) U \(sink.firstU) audio chunks \(sink.chunks) at \(sink.rate) Hz x\(sink.channels) len \(sink.chunkLen) peak \(sink.peak) lead \(Int(p.audioLead * 1000)) ms level \(p.level)")
        XCTAssertGreaterThanOrEqual(playedFrames, 30, "30 fps once playing")
        XCTAssertGreaterThan(sink.frames, playedFrames, "paused: the last frame is re-sent (keep-alive)")
        XCTAssertTrue(sink.size == (320, 240))
        XCTAssertEqual(Int(sink.firstLuma), 235, accuracy: 3, "white in video range")
        XCTAssertEqual(Int(sink.firstU), 128, accuracy: 3)
        XCTAssertEqual(sink.rate, 44100); XCTAssertEqual(sink.channels, 2)
        XCTAssertEqual(sink.chunkLen, 441 * 2, "exact 10 ms chunks")
        // IN SYNC: the sound sent while playing matches the picture's time, not the tap's (~0.4 s ahead).
        print("PREVIEW SYNC \(playedChunks) chunks and \(playedFrames) frames in 2.0 s of play")
        // Measured 2026-09-24: 139 chunks (1.39 s) against 40 frames (1.33 s); before the release queue the tap's
        // ~0.4 s run-ahead sent 241 chunks against 46 frames. Playback takes ~0.6 s to start after play().
        XCTAssertEqual(Double(playedChunks) / 100, Double(playedFrames) / 30, accuracy: 0.15, "audio sent tracks the frames sent")
        XCTAssertGreaterThanOrEqual(playedChunks, 100)
        XCTAssertLessThanOrEqual(playedChunks, 215, "not the tap's run-ahead")
        XCTAssertGreaterThan(sink.peak, 1000, "the tone reached the call although the local monitor was muted")
    }

    /// 2026-09-24 05:05:52: STOP SHARE freed the raw share source while the SDK still held an unretained
    /// pointer to it, and the next SDK callback crashed the app. A retired source must outlive its owner and
    /// be cut loose from the player.
    @MainActor func testARetiredRawShareSourceStaysAliveAndCutLoose() {
        let p = PreviewPlayer()
        weak var gone: RawShareSource?
        do {
            let src = RawShareSource(player: p, label: "test")
            var fired = false
            src.onStopped = { fired = true }
            gone = src
            RawShareSource.retire(src)
            XCTAssertNil(src.player, "a late callback cannot reach the player")
            src.onStopped?()
            XCTAssertFalse(fired, "or the engine")
        }
        XCTAssertNotNil(gone, "the SDK may still call it: it must not be freed")
        gone?.onStopSend(); gone?.onStopSendAudio()   // what the SDK does after stopShare: must be harmless
    }
}
