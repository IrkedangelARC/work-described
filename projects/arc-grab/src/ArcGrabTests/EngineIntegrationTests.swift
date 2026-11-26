//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcGrabTests

/// Real engine, real network: the 19 s "Me at the zoo" clip (jNQXAC9IVRw).
/// Skipped when yt-dlp/ffmpeg are not installed. Each case runs one job
/// through GrabQueue exactly as the UI would and probes the delivered file.
@MainActor
final class EngineIntegrationTests: XCTestCase {
    static let url = "https://www.youtube.com/watch?v=jNQXAC9IVRw"

    func runJob(_ configure: (inout GrabOptions) -> Void, timeout: TimeInterval = 120) async throws -> (GrabJob, ProbeResult, Toolchain) {
        try await runJob(url: Self.url, configure, timeout: timeout)
    }

    /// One job through GrabQueue exactly as the UI would, for any link; the delivered file is probed.
    func runJob(url: String, _ configure: (inout GrabOptions) -> Void, timeout: TimeInterval = 120, expectDone: Bool = true) async throws -> (GrabJob, ProbeResult, Toolchain) {
        let tc = Toolchain.healthCheck(Toolchain.discover())
        try XCTSkipUnless(tc.isComplete, "engine not installed")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arcgrab-test-\(UUID().uuidString)").path
        var o = GrabOptions()
        o.destination = dir
        configure(&o)
        let q = GrabQueue(startEngine: false)
        q.toolchain = tc
        q.engineChecked = true
        q.add(text: url, options: o)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let j = q.jobs.first, j.status.isFinished { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let job = try XCTUnwrap(q.jobs.first)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        guard expectDone else { return (job, ProbeResult(), tc) }
        XCTAssertEqual(job.status, .done, job.log.suffix(5).joined(separator: "\n"))
        let path = try XCTUnwrap(job.outputPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let probe = ProbeResult.probe(path, toolchain: tc)
        return (job, probe, tc)
    }

    // MARK: Embedded players (PLAN_arc_grab_multisite, step 5)

    /// Vimeo refuses a repeat anonymous fetch of the same video seconds after the last one (HTTP 401, which
    /// the app correctly maps to the COOKIES hint). The suite fetches 1084537 more than once, so one retry
    /// after a pause is the test's allowance, not the app's.
    static func vimeoRefusedRepeat(_ job: GrabJob) -> Bool {
        guard case .failed = job.status, job.sourceURL.contains("vimeo.com") else { return false }
        return job.failureHint == .cookies
    }

    /// The players a client embeds, each through the whole pipeline at 360p: an HLS manifest (Generic,
    /// impersonated), Wistia, Brightcove (DASH video + HLS audio merged), and a Vimeo PLAYER URL. The row's
    /// site label and the single-stream progress are asserted as well as the file.
    func testEmbedMatrix() async throws {
        let cases: [(url: String, site: String, singleStream: Bool?)] = [
            ("https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", "STREAM", true),
            ("https://fast.wistia.net/embed/iframe/29b0fbf547", "WISTIA", false),
            ("https://players.brightcove.net/1752604059001/default_default/index.html?videoId=5819230967001", "BRIGHTCOVENEW", false),
            ("https://player.vimeo.com/video/1084537", "VIMEO", false),
        ]
        for c in cases {
            let mp4: (inout GrabOptions) -> Void = { $0.mode = .video; $0.videoFormat = .mp4; $0.quality = .p720 }
            var (job, _, tc) = try await runJob(url: c.url, mp4, timeout: 180, expectDone: false)
            if Self.vimeoRefusedRepeat(job) {
                try await Task.sleep(for: .seconds(10))
                (job, _, tc) = try await runJob(url: c.url, mp4, timeout: 180, expectDone: false)
            }
            XCTAssertEqual(job.status, .done, "\(c.url)\n" + job.log.suffix(5).joined(separator: "\n"))
            let p = ProbeResult.probe(try XCTUnwrap(job.outputPath, c.url), toolchain: tc)
            XCTAssertEqual(job.info?.siteLabel, c.site, c.url)
            if let expected = c.singleStream { XCTAssertEqual(job.info?.singleStream, expected, c.url) }
            XCTAssertEqual(p.videoCodec, "h264", c.url)
            XCTAssertEqual(p.audioCodec, "aac", c.url)
            XCTAssertEqual(job.fraction, 1, c.url)
        }
    }

    /// A Vimeo PAGE link is rewritten to the player endpoint (the page demands a login, the embed does
    /// not), and a video that is DRM'd for anonymous playback fails with the mapped one-liner, not raw text.
    func testVimeoPageAndProtectedFailure() async throws {
        var result = try await runJob(url: "https://vimeo.com/1084537", { $0.mode = .video; $0.videoFormat = .mp4; $0.quality = .p720 }, timeout: 180, expectDone: false)
        if Self.vimeoRefusedRepeat(result.0) {
            try await Task.sleep(for: .seconds(10))
            result = try await runJob(url: "https://vimeo.com/1084537", { $0.mode = .video; $0.videoFormat = .mp4; $0.quality = .p720 }, timeout: 180, expectDone: false)
        }
        let ok = result.0
        XCTAssertEqual(ok.status, .done, ok.log.suffix(5).joined(separator: "\n"))
        XCTAssertEqual(ok.info?.siteLabel, "VIMEO")
        if let path = ok.outputPath {
            XCTAssertEqual(ProbeResult.probe(path, toolchain: result.2).videoCodec, "h264")
        }
        let (bad, _, _) = try await runJob(url: "https://player.vimeo.com/video/76979871", { $0.mode = .video; $0.videoFormat = .mp4; $0.quality = .p720 }, timeout: 180, expectDone: false)
        guard case .failed(let line) = bad.status else { return XCTFail("expected a mapped failure, got \(bad.status)") }
        XCTAssertTrue(line.contains("·"), line)                       // reason · HINT
        XCTAssertNotNil(bad.failureHint, line)
        XCTAssertFalse(line.contains("--check-formats"), "raw yt-dlp advice leaked into the row: \(line)")
    }

    func testMP4CompatiblePath() async throws {
        let (job, p, _) = try await runJob { $0.mode = .video; $0.videoFormat = .mp4; $0.quality = .p720 }
        XCTAssertTrue(job.outputPath!.hasSuffix(".mp4"))
        XCTAssertEqual(p.videoCodec, "h264")
        XCTAssertEqual(p.audioCodec, "aac")
        XCTAssertEqual(job.fraction, 1)
    }

    func testProRes422Path() async throws {
        let (job, p, _) = try await runJob { $0.mode = .video; $0.videoFormat = .prores422; $0.quality = .best }
        XCTAssertTrue(job.outputPath!.hasSuffix(".mov"))
        XCTAssertEqual(p.videoCodec, "prores")
        XCTAssertEqual(p.audioCodec, "pcm_s24le")
        // source mkv removed (KEEP SOURCE off)
        let mkv = (job.outputPath! as NSString).deletingPathExtension + ".mkv"
        XCTAssertFalse(FileManager.default.fileExists(atPath: mkv))
    }

    func testWAV48Path() async throws {
        let (job, p, _) = try await runJob { $0.mode = .audio; $0.audioFormat = .wav48 }
        XCTAssertTrue(job.outputPath!.hasSuffix(".wav"))
        XCTAssertEqual(p.audioCodec, "pcm_s24le")
        XCTAssertNil(p.videoCodec)
    }

    /// The bundled ffmpeg needs libmp3lame (tools/build_engine.sh); without it every MP3 grab failed.
    func testMP3Path() async throws {
        let (job, p, _) = try await runJob { $0.mode = .audio; $0.audioFormat = .mp3 }
        XCTAssertTrue(job.outputPath!.hasSuffix(".mp3"))
        XCTAssertEqual(p.audioCodec, "mp3")
    }

    /// A trimmed audio grab re-encodes the section at exact cuts from the AAC stream (the Opus one hit exit 88).
    func testAudioSectionTrim() async throws {
        let (job, p, _) = try await runJob { $0.mode = .audio; $0.audioFormat = .mp3; $0.sectionIn = "0:02"; $0.sectionOut = "0:12" }
        XCTAssertTrue(job.outputPath!.hasSuffix(".mp3"))
        XCTAssertEqual(p.duration ?? 0, 10, accuracy: 1.5)
    }

    /// Real whisper pass on the zoo clip: "elephants" must land in the .txt,
    /// the .srt sits beside it. Needs whisper-cli + models on the build
    /// machine (tools/fetch_models.sh); a missing engine is a failure here,
    /// not a skip, so the ship gate cannot pass without the transcript path.
    func testTranscriptPath() async throws {
        let tc = Toolchain.discover()
        XCTAssertNotNil(tc.whisper, "whisper-cli missing on the build machine: run tools/build_engine.sh")
        XCTAssertTrue(ModelFetcher.allPresent(), "models missing: run tools/fetch_models.sh")
        let (job, p, _) = try await runJob({ $0.mode = .video; $0.videoFormat = .mp4; $0.quality = .p720; $0.transcript = true }, timeout: 240)
        XCTAssertEqual(p.videoCodec, "h264")
        let txt = try XCTUnwrap(job.transcriptPath)
        XCTAssertTrue(txt.hasSuffix(".txt"))
        let text = try String(contentsOfFile: txt, encoding: .utf8)
        XCTAssertTrue(text.lowercased().contains("elephants"), text)
        XCTAssertFalse(text.contains("-->"), "txt is prose, not cues")
        let srt = (txt as NSString).deletingPathExtension + ".srt"
        XCTAssertTrue(FileManager.default.fileExists(atPath: srt))
        XCTAssertTrue(job.log.contains { $0.hasPrefix("transcript →") }, job.log.suffix(5).joined(separator: "\n"))
    }

    /// MP4 trims re-encode the section: exact cuts.
    func testSectionTrim() async throws {
        let (job, p, _) = try await runJob { $0.mode = .video; $0.videoFormat = .mp4; $0.quality = .p720; $0.sectionIn = "0:05"; $0.sectionOut = "0:10" }
        XCTAssertTrue(job.outputPath!.hasSuffix(".mp4"))
        XCTAssertEqual(p.duration ?? 0, 5, accuracy: 1, "trimmed to 5 s")
    }

    /// ORIGINAL trims keep the source bitstream and cut on keyframes, so they may run up to one GOP long. A
    /// forced re-encode once delivered mpeg4 + ac3 here (2026-09-26).
    func testOriginalSectionKeepsBitstream() async throws {
        let (job, p, _) = try await runJob { $0.mode = .video; $0.videoFormat = .original; $0.sectionIn = "0:05"; $0.sectionOut = "0:10" }
        XCTAssertTrue(job.outputPath!.hasSuffix(".mkv"))
        XCTAssertNotEqual(p.videoCodec, "mpeg4")
        XCTAssertNotEqual(p.audioCodec, "ac3")
        XCTAssertLessThan(p.duration ?? 99, 16, "a section, not the whole 19 s clip")
    }
}
