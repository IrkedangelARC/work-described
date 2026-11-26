//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcCaptureTests

/// The dead-link check that turns "ten minutes of dead air, reported ok" into
/// a warning days before show day. Driven off a real client deck fixture, whose
/// slide 9 video (abcDEF12345) was removed by its uploader — measured
/// 2026-09-15: oEmbed 404, playabilityStatus ERROR "Video unavailable".
final class YouTubeAvailabilityTests: XCTestCase {

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testHTTPCodeMapping() {
        XCTAssertEqual(YouTubeAvailability.status(forHTTP: 200), .available)
        XCTAssertTrue(YouTubeAvailability.status(forHTTP: 404).isUnavailable)
        XCTAssertTrue(YouTubeAvailability.status(forHTTP: 401).isUnavailable)
        XCTAssertTrue(YouTubeAvailability.status(forHTTP: 403).isUnavailable)
        // A server hiccup is not evidence that a video is gone.
        if case .unknown = YouTubeAvailability.status(forHTTP: 500) {} else {
            XCTFail("HTTP 500 must be unknown, never a dead link")
        }
    }

    func testOEmbedURLIsProperlyEncoded() throws {
        let url = try XCTUnwrap(YouTubeAvailability.oEmbedURL(for: "abcDEF12345"))
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://www.youtube.com/oembed?"))
        XCTAssertTrue(s.contains("abcDEF12345"))
        XCTAssertTrue(s.contains("format=json"))
        // The nested watch URL has to be a query VALUE, not extra parameters.
        XCTAssertFalse(s.contains("?v="), "the inner watch URL must be percent-encoded")
    }

    /// The real case: the client deck's slide 9 is a YouTube video, slide 10 is Drive. Only
    /// the YouTube one is asked about, and only it can be warned about.
    func testDeadYouTubeLinkIsWarnedAndDriveIsNotChecked() async throws {
        let deck = try SlidesViewerData.parse(fixture("viewerdata_youtube"))
        let asked = Asked()
        let warnings = await YouTubeAvailability.deadLinkWarnings(in: deck) { url in
            await asked.note(url); return 404
        }
        XCTAssertEqual(warnings.count, 1, "one YouTube video in this deck")
        let w = try XCTUnwrap(warnings.first)
        XCTAssertTrue(w.hasPrefix("slide 9:"), "the warning names the slide: \(w)")
        XCTAssertTrue(w.contains("UNAVAILABLE"))
        XCTAssertTrue(w.contains("removed"))

        let urls = await asked.urls
        XCTAssertEqual(urls.count, 1, "the Drive video on slide 10 must not be looked up")
        XCTAssertTrue(try XCTUnwrap(urls.first).absoluteString.contains("abcDEF12345"))
    }

    func testLiveLinkProducesNoWarning() async throws {
        let deck = try SlidesViewerData.parse(fixture("viewerdata_youtube"))
        let warnings = await YouTubeAvailability.deadLinkWarnings(in: deck) { _ in 200 }
        XCTAssertTrue(warnings.isEmpty)
    }

    /// An offline laptop must never make a healthy deck look broken.
    func testNoNetworkNeverCondemnsADeck() async throws {
        let deck = try SlidesViewerData.parse(fixture("viewerdata_youtube"))
        let offline = await YouTubeAvailability.deadLinkWarnings(in: deck) { _ in nil }
        XCTAssertTrue(offline.isEmpty, "no answer means unknown, not dead")
        let flaky = await YouTubeAvailability.deadLinkWarnings(in: deck) { _ in 503 }
        XCTAssertTrue(flaky.isEmpty, "a 5xx means unknown, not dead")
    }

    /// A deck of Drive videos costs no network calls at all.
    func testDeckWithNoYouTubeVideosMakesNoRequests() async throws {
        let deck = try SlidesViewerData.parse(fixture("viewerdata_trim"))   // a client deck: 4 Drive videos
        let asked = Asked()
        let warnings = await YouTubeAvailability.deadLinkWarnings(in: deck) { url in
            await asked.note(url); return 404
        }
        XCTAssertTrue(warnings.isEmpty)
        let urls = await asked.urls
        XCTAssertTrue(urls.isEmpty, "Drive-hosted videos are never asked about")
    }

    func testWarningsComeBackInSlideOrder() async throws {
        let deck = SlidesInfo(id: "d", title: "t", slides: (1...3).map { i in
            SlidesInfo.Slide(index: i, objectId: "g\(i)", skipped: false, buildSteps: 0,
                             videos: [SlidesInfo.Video(source: "YOUTUBE", id: "vid\(i)", name: "v\(i)",
                                                       elementID: "e", muted: false, start: 0, end: 0,
                                                       autoPlay: false, seconds: nil)])
        })
        let warnings = await YouTubeAvailability.deadLinkWarnings(in: deck) { _ in 404 }
        XCTAssertEqual(warnings.count, 3)
        XCTAssertTrue(warnings[0].hasPrefix("slide 1:"))
        XCTAssertTrue(warnings[1].hasPrefix("slide 2:"))
        XCTAssertTrue(warnings[2].hasPrefix("slide 3:"))
    }

    /// Collects the URLs the checker actually requested.
    private actor Asked {
        var urls: [URL] = []
        func note(_ u: URL) { urls.append(u) }
    }
}
