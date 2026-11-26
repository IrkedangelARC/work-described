//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcGrabTests

final class CommandBuilderTests: XCTestCase {
    func testPlaylistDetection() {
        XCTAssertTrue(CommandBuilder.isPlaylistURL("https://www.youtube.com/playlist?list=PLabc"))
        XCTAssertTrue(CommandBuilder.isPlaylistURL("https://youtube.com/watch?list=PLabc"))
        XCTAssertFalse(CommandBuilder.isPlaylistURL("https://www.youtube.com/watch?v=abc&list=PLabc"))
        XCTAssertFalse(CommandBuilder.isPlaylistURL("https://youtu.be/abc?list=PLabc"))
        XCTAssertFalse(CommandBuilder.isPlaylistURL("https://www.youtube.com/watch?v=abc"))
        // Other sites are yt-dlp's call: no heuristic, no --no-playlist.
        XCTAssertFalse(CommandBuilder.isPlaylistURL("https://vimeo.com/showcase/123?list=x"))
        XCTAssertTrue(CommandBuilder.isYouTubeHost("https://m.youtube.com/watch?v=abc"))
        XCTAssertFalse(CommandBuilder.isYouTubeHost("https://notyoutube.com/watch?v=abc"))
        XCTAssertTrue(CommandBuilder.analyzeArgs(url: "https://www.youtube.com/watch?v=abc", options: GrabOptions()).contains("--no-playlist"))
        XCTAssertFalse(CommandBuilder.analyzeArgs(url: "https://vimeo.com/76979871", options: GrabOptions()).contains("--no-playlist"))
        XCTAssertFalse(CommandBuilder.analyzeArgs(url: "https://drive.google.com/file/d/ID/view", options: GrabOptions()).contains("--no-playlist"))
    }

    func testExpectedStreamsFollowTheSite() {
        var o = GrabOptions(); o.mode = .video
        var yt = MediaInfo(id: "a", title: "t", url: "u"); yt.singleStream = false
        var file = MediaInfo(id: "b", title: "t", url: "u"); file.singleStream = true
        XCTAssertEqual(CommandBuilder.expectedStreams(o, info: yt), 2)
        XCTAssertEqual(CommandBuilder.expectedStreams(o, info: file), 1)
        XCTAssertEqual(CommandBuilder.expectedStreams(o, info: nil), 2)     // unknown: the old two-phase bar
        o.mode = .audio
        XCTAssertEqual(CommandBuilder.expectedStreams(o, info: yt), 1)
    }

    func testFormatSelectors() {
        var o = GrabOptions()
        o.mode = .video; o.videoFormat = .mp4; o.quality = .p1080
        XCTAssertEqual(CommandBuilder.formatSelector(o),
                       "bv*[vcodec^=avc1][height<=1080]+ba[acodec^=mp4a]/bv*[height<=1080]+ba/b[height<=1080]")
        o.videoFormat = .prores422HQ; o.quality = .best
        XCTAssertEqual(CommandBuilder.formatSelector(o), "bv*+ba/b")
        o.videoFormat = .original; o.quality = .p2160
        XCTAssertEqual(CommandBuilder.formatSelector(o), "bv*[height<=2160]+ba/b[height<=2160]")
        o.mode = .audio
        XCTAssertEqual(CommandBuilder.formatSelector(o), "ba/b")
        XCTAssertEqual(CommandBuilder.expectedStreams(o), 1)
        o.sectionIn = "0:02"   // the trim re-encodes at the cuts: AAC, never the Opus stream (ffmpeg exit 88)
        XCTAssertEqual(CommandBuilder.formatSelector(o), "ba[ext=m4a]/ba/b")
    }

    /// Keyframe forcing re-encodes the section: only where the delivery re-encodes anyway.
    func testSectionCutsKeepOriginalBitstream() {
        var o = GrabOptions(); o.sectionIn = "0:03"; o.sectionOut = "0:10"
        let args = { CommandBuilder.downloadArgs(url: "https://youtu.be/x", options: o, ffmpegDir: "/x") }
        o.mode = .video; o.videoFormat = .mp4
        XCTAssertTrue(args().contains("--force-keyframes-at-cuts"))
        o.videoFormat = .prores422
        XCTAssertTrue(args().contains("--force-keyframes-at-cuts"))
        o.videoFormat = .original
        XCTAssertFalse(args().contains("--force-keyframes-at-cuts"))
        XCTAssertTrue(args().contains("--download-sections"))
        o.mode = .audio; o.audioFormat = .mp3
        XCTAssertTrue(args().contains("--force-keyframes-at-cuts"))
    }

    func testSubtitleLanguagesAreNamedNotWildcard() {
        var o = GrabOptions(); o.subtitles = true
        let a = CommandBuilder.downloadArgs(url: "https://youtu.be/x", options: o, ffmpegDir: "/x")
        let langs = a[a.firstIndex(of: "--sub-langs")! + 1]
        XCTAssertFalse(langs.contains("*"), "a wildcard pulls every machine translation and trips HTTP 429")
        XCTAssertTrue(langs.split(separator: ",").contains("en"))
    }

    func testSectionSpec() {
        var o = GrabOptions()
        XCTAssertNil(CommandBuilder.sectionSpec(o))
        o.sectionIn = "1:00"; XCTAssertEqual(CommandBuilder.sectionSpec(o), "*1:00-inf")
        o.sectionOut = "2:30"; XCTAssertEqual(CommandBuilder.sectionSpec(o), "*1:00-2:30")
        o.sectionIn = " "; XCTAssertEqual(CommandBuilder.sectionSpec(o), "*0-2:30")
    }

    func testDownloadArgsVideoMP4() {
        var o = GrabOptions()
        o.destination = "/tmp/x"; o.chapters = true; o.subtitles = true; o.cookies = .chrome
        let a = CommandBuilder.downloadArgs(url: "https://y/v", options: o, ffmpegDir: "/opt/homebrew/bin")
        XCTAssertEqual(a.last, "https://y/v")
        XCTAssertTrue(a.contains("--merge-output-format")); XCTAssertTrue(a.contains("mp4"))
        XCTAssertTrue(a.contains("--embed-chapters"))
        XCTAssertTrue(a.contains("--write-auto-subs"))
        XCTAssertTrue(a.contains("--cookies-from-browser")); XCTAssertTrue(a.contains("chrome"))
        XCTAssertTrue(a.contains("--no-playlist"))
        XCTAssertTrue(a.contains("/tmp/x/%(title).150B [%(id)s].%(ext)s"))
        XCTAssertFalse(a.contains("-x"))
        XCTAssertFalse(a.contains("--download-sections"))
    }

    func testDownloadArgsAudio() {
        var o = GrabOptions()
        o.mode = .audio; o.audioFormat = .m4a
        var a = CommandBuilder.downloadArgs(url: "u", options: o, ffmpegDir: "/f")
        XCTAssertTrue(a.contains("-x")); XCTAssertTrue(a.contains("m4a"))
        XCTAssertFalse(a.contains("--merge-output-format"))
        o.audioFormat = .wav48
        a = CommandBuilder.downloadArgs(url: "u", options: o, ffmpegDir: "/f")
        XCTAssertFalse(a.contains("-x"), "WAV is made by the conform step, not yt-dlp")
    }

    func testConformArgs() {
        var o = GrabOptions(); o.videoFormat = .prores422HQ
        var a = CommandBuilder.conformArgs(input: "in.mkv", output: "out.mov", options: o)
        XCTAssertTrue(a.contains("prores_videotoolbox")); XCTAssertTrue(a.contains("3"))
        XCTAssertTrue(a.contains("pcm_s24le")); XCTAssertEqual(a.last, "out.mov")
        o.videoFormat = .dnxhrHQ
        a = CommandBuilder.conformArgs(input: "in.mkv", output: "out.mov", options: o)
        XCTAssertTrue(a.contains("dnxhr_hq"))
        o.mode = .audio; o.audioFormat = .wav48
        a = CommandBuilder.conformArgs(input: "in.webm", output: "out.wav", options: o)
        XCTAssertTrue(a.contains("-vn")); XCTAssertTrue(a.contains("48000"))
    }

    func testNeedsConform() {
        var o = GrabOptions(); o.videoFormat = .mp4
        XCTAssertFalse(ProbeResult.needsConform(ProbeResult(videoCodec: "h264", audioCodec: "aac"), options: o))
        XCTAssertTrue(ProbeResult.needsConform(ProbeResult(videoCodec: "vp9", audioCodec: "opus"), options: o))
        o.videoFormat = .original
        XCTAssertFalse(ProbeResult.needsConform(ProbeResult(videoCodec: "av1", audioCodec: "opus"), options: o))
        o.videoFormat = .prores422
        XCTAssertTrue(ProbeResult.needsConform(ProbeResult(videoCodec: "h264", audioCodec: "aac"), options: o))
        o.mode = .audio; o.audioFormat = .m4a
        XCTAssertFalse(ProbeResult.needsConform(ProbeResult(audioCodec: "aac"), options: o))
        o.audioFormat = .wav48
        XCTAssertTrue(ProbeResult.needsConform(ProbeResult(audioCodec: "opus"), options: o))
    }
}
