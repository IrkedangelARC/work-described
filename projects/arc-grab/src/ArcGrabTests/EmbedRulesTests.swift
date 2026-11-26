//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcGrabTests

final class EmbedRulesTests: XCTestCase {
    func testVimeoPageBecomesPlayer() {
        XCTAssertEqual(EmbedRules.normalize("https://vimeo.com/76979871"), "https://player.vimeo.com/video/76979871")
        XCTAssertEqual(EmbedRules.normalize("https://vimeo.com/76979871/abc123"), "https://player.vimeo.com/video/76979871?h=abc123")
        XCTAssertEqual(EmbedRules.normalize("https://vimeo.com/76979871?h=abc123&share=copy"), "https://player.vimeo.com/video/76979871?h=abc123")
        // Not a video page: left alone.
        XCTAssertEqual(EmbedRules.normalize("https://vimeo.com/showcase/123"), "https://vimeo.com/showcase/123")
        XCTAssertEqual(EmbedRules.normalize("https://player.vimeo.com/video/1?h=x"), "https://player.vimeo.com/video/1?h=x")
        XCTAssertEqual(EmbedRules.normalize("https://www.youtube.com/watch?v=a"), "https://www.youtube.com/watch?v=a")
        XCTAssertEqual(EmbedRules.normalize("not a url"), "not a url")
    }

    func testManifestAndKnownHosts() {
        XCTAssertTrue(EmbedRules.isManifest("https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"))
        XCTAssertTrue(EmbedRules.isManifest("https://cdn.example.com/live/index.mpd?token=1"))
        XCTAssertFalse(EmbedRules.isManifest("https://player.vimeo.com/video/1"))
        XCTAssertTrue(EmbedRules.isKnownPlayerHost("https://fast.wistia.net/embed/iframe/29b0fbf547"))
        XCTAssertTrue(EmbedRules.isKnownPlayerHost("https://players.brightcove.net/1/default_default/index.html?videoId=2"))
        XCTAssertFalse(EmbedRules.isKnownPlayerHost("https://events.client.com/session/12"))
    }

    func testExtraArgs() {
        XCTAssertEqual(EmbedRules.extraArgs(url: "https://player.vimeo.com/video/1", referer: "", password: ""), [])
        XCTAssertEqual(EmbedRules.extraArgs(url: "https://player.vimeo.com/video/1", referer: " https://client.com/talk ", password: "sesame"),
                       ["--referer", "https://client.com/talk", "--video-password", "sesame"])
        XCTAssertEqual(EmbedRules.extraArgs(url: "https://events.client.com/session/12", referer: "", password: ""),
                       ["--extractor-args", "generic:impersonate"])
        XCTAssertEqual(EmbedRules.extraArgs(url: "https://test-streams.mux.dev/x.m3u8", referer: "", password: ""),
                       ["--extractor-args", "generic:impersonate"])
    }

    func testArgsCarryTheEmbedNeeds() {
        var o = GrabOptions(); o.referer = "https://client.com/talk"; o.videoPassword = "pw"
        let analyze = CommandBuilder.analyzeArgs(url: "https://vimeo.com/76979871/h4sh", options: o)
        XCTAssertEqual(analyze.last, "https://player.vimeo.com/video/76979871?h=h4sh")
        XCTAssertTrue(analyze.contains("--referer") && analyze.contains("--video-password"))
        XCTAssertFalse(analyze.contains("--no-playlist"))
        let download = CommandBuilder.downloadArgs(url: "https://vimeo.com/76979871", options: o, ffmpegDir: "/f")
        XCTAssertEqual(download.last, "https://player.vimeo.com/video/76979871")
        XCTAssertEqual(download.filter { $0 == "--referer" }.count, 1)
    }

    func testManifestIsAStream() throws {
        let json = """
        {"_type":"video","id":"x36xhzz","title":"x36xhzz","extractor_key":"Generic",
         "formats":[{"protocol":"m3u8_native","height":360,"vcodec":"avc1","acodec":"mp4a"},{"protocol":"m3u8_native","height":1080,"vcodec":"avc1","acodec":"mp4a"}]}
        """
        guard case .single(let m) = try MediaInfo.parse(Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(m.siteLabel, "STREAM"); XCTAssertEqual(m.singleStream, true); XCTAssertEqual(m.maxHeight, 1080)
    }
}
