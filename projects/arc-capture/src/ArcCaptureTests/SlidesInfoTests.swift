//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcCaptureTests

/// The fixtures are REAL `window.viewerData` payloads captured from Google
/// Slides present mode on 2026-09-15, one per case, with only the two bulky
/// image fields emptied. Every expectation below was cross-checked against
/// the Slides/Drive API for the same deck at capture time, so these tests
/// pin the parser to measured ground truth rather than to a guess about
/// Google's page model.
final class SlidesViewerDataTests: XCTestCase {

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
                               "fixture \(name).json missing from the test bundle")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(obj as? [String: Any])
    }

    /// "1.6 Sample Presenter - Short Talk": API said 4 slides with 3 and 4
    /// skipped. This is the case that proves row[12] is the skipped flag.
    func testSkippedSlidesAreReadFromTheRowFlag() throws {
        let info = try SlidesViewerData.parse(fixture("viewerdata_skipped"))
        XCTAssertEqual(info.title, "1.6 Sample Presenter - Short Talk")
        XCTAssertEqual(info.slides.count, 4)
        XCTAssertEqual(info.hidden, [3, 4])
        XCTAssertTrue(info.videoSlides.isEmpty)
        // Indices are 1-based and in deck order.
        XCTAssertEqual(info.slides.map(\.index), [1, 2, 3, 4])
        XCTAssertFalse(info.slides[0].objectId.isEmpty)
    }

    /// "Sample Deck Base Slides": API said 35
    /// slides, none skipped, video on slide 16.
    func testVideoSlideIsReadFromTheRowVideoRecord() throws {
        let info = try SlidesViewerData.parse(fixture("viewerdata_video"))
        XCTAssertEqual(info.slides.count, 35)
        XCTAssertTrue(info.hidden.isEmpty, "this deck skips nothing")
        XCTAssertEqual(info.videoSlides, [16])
        let video = try XCTUnwrap(info.slides[15].videos.first)
        XCTAssertEqual(video.source, "DRIVE")
        XCTAssertEqual(video.id, "DRIVE_FILE_ID_PLACEHOLDER")
        XCTAssertEqual(video.name, "Sample Clip.MOV")
        // Lengths are NOT in the page model; they are read live off the slide.
        XCTAssertNil(video.seconds)
        XCTAssertTrue(info.slideDurations.isEmpty)
    }

    /// "Sample Speaker Deck (Breakout rooms only)": 5 slides, nothing skipped,
    /// no video — the plain case.
    func testPlainDeck() throws {
        let info = try SlidesViewerData.parse(fixture("viewerdata_plain"))
        XCTAssertEqual(info.slides.count, 5)
        XCTAssertEqual(info.title, "Sample Speaker Deck (Breakout rooms only)")
        XCTAssertTrue(info.hidden.isEmpty)
        XCTAssertTrue(info.videoSlides.isEmpty)
        XCTAssertEqual(info.presentURL,
                       "https://docs.google.com/presentation/d/\(info.id)/present")
    }

    /// An unknown value in the skipped field must never silently drop a slide.
    func testUnknownPresentableFlagCountsAsPresentable() throws {
        var fx = try fixture("viewerdata_plain")
        var rows = try XCTUnwrap(fx["slides"] as? [[Any]])
        rows[0][12] = "unexpected"
        fx["slides"] = rows
        let info = try SlidesViewerData.parse(fx)
        XCTAssertEqual(info.slides.count, 5)
        XCTAssertTrue(info.hidden.isEmpty, "an unreadable flag must not hide a slide")
    }

    /// "Sample_Client_Deck": 4 video slides, all Drive. Slide 18 is
    /// the trim case — the API reports `videoProperties.end = 30000` on a
    /// 34.625 s video, and the embed URL advertises the FULL length with no
    /// start/end parameters, so the trim has to come from the page model.
    func testEndTrimIsReadFromTheVideoRecord() throws {
        let info = try SlidesViewerData.parse(fixture("viewerdata_trim"))
        XCTAssertEqual(info.slides.count, 36)
        XCTAssertEqual(info.videoSlides, [18, 23, 30, 36])
        let trimmed = try XCTUnwrap(info.slides[17].videos.first)
        XCTAssertEqual(trimmed.end, 30, "slide 18 is cut at 30 s")
        XCTAssertEqual(trimmed.start, 0)
        XCTAssertEqual(trimmed.source, "DRIVE")
        // The embed reports the untrimmed length; the trim turns it into 30 s.
        XCTAssertEqual(SlidesInfo.trimmed(full: 34.625, start: trimmed.start, end: trimmed.end), 30)
        // The other three carry no trim.
        for i in [22, 29, 35] {
            let v = try XCTUnwrap(info.slides[i].videos.first)
            XCTAssertEqual(v.start, 0); XCTAssertEqual(v.end, 0)
        }
        // Slide 36 is the muted one (API: videoProperties.mute = true).
        XCTAssertTrue(try XCTUnwrap(info.slides[35].videos.first).muted)
        XCTAssertFalse(try XCTUnwrap(info.slides[17].videos.first).muted)
    }

    /// "Sample Speaker Deck": slide 9 is a real YouTube video with a 15 s start
    /// trim, slide 10 a Drive video with none. YouTube is the unmeasurable
    /// case — its embed is www.youtube.com/embed/<id> and carries no length.
    func testYouTubeAndDriveVideosAreDistinguished() throws {
        let info = try SlidesViewerData.parse(fixture("viewerdata_youtube"))
        XCTAssertEqual(info.slides.count, 16)
        XCTAssertEqual(info.videoSlides, [9, 10])

        let yt = try XCTUnwrap(info.slides[8].videos.first)
        XCTAssertEqual(yt.source, "YOUTUBE")
        XCTAssertEqual(yt.id, "abcDEF12345")
        XCTAssertEqual(yt.start, 15, "starts 15 s in")
        XCTAssertFalse(yt.isMeasurable, "a YouTube embed carries no length")

        let drive = try XCTUnwrap(info.slides[9].videos.first)
        XCTAssertEqual(drive.source, "DRIVE")
        XCTAssertTrue(drive.isMeasurable)
        XCTAssertEqual(drive.start, 0); XCTAssertEqual(drive.end, 0)
    }

    func testShortRowIsRejectedRatherThanMisread() throws {
        var fx = try fixture("viewerdata_plain")
        fx["slides"] = [["onlyOneField"]]
        XCTAssertThrowsError(try SlidesViewerData.parse(fx))
    }
}

final class SlidesInfoTests: XCTestCase {
    func testDeckIDFromURLOrBareID() throws {
        XCTAssertEqual(try SlidesInfo.deckID("https://docs.google.com/presentation/d/1AbCdEfGhIjK_xyz-9/edit#slide=id.p"),
                       "1AbCdEfGhIjK_xyz-9")
        XCTAssertEqual(try SlidesInfo.deckID("https://docs.google.com/presentation/d/1abcDEF_ghi-jkl/present?slide=id.g1"),
                       "1abcDEF_ghi-jkl")
        XCTAssertEqual(try SlidesInfo.deckID("1AbCdEfGh_e1234567890abcdef"), "1AbCdEfGh_e1234567890abcdef")
        XCTAssertThrowsError(try SlidesInfo.deckID("nonsense"))
        // `name:<title>` lookup went with the Drive API; it must fail clearly
        // rather than look like a deck id.
        XCTAssertThrowsError(try SlidesInfo.deckID("name:Sample Speaker Deck"))
    }

    /// The real embed src captured from present mode on 2026-09-15 for
    /// "Sample Clip.MOV". Drive's own videoMediaMetadata
    /// for the same file said durationMillis 5769, so 5.769 here is the
    /// measured agreement between the two sources, not a guess.
    func testDurationComesOffTheRealEmbedURL() {
        let src = "https://youtube.googleapis.com/embed/?rel=0&status=ok&ps=docs&partnerid=30&el=embedded"
            + "&hl=en&playsinline=1&disablekb=1&enablejsapi=1&authuser=0&widgetid=1&vf=6&aoriginsup=1"
            + "&length_seconds=5.769&title=Sample%20Clip.MOV"
            + "&origin=https%3A%2F%2Fdocs.google.com"
        XCTAssertEqual(GoogleSlidesDriver.fullLengthFromEmbedURL(src), 5.769)
    }

    /// A real YouTube video's embed is a different host with no length at all
    /// (measured on Sample Speaker Deck slide 9). It must read as unmeasurable
    /// rather than as zero.
    func testRealYouTubeEmbedHasNoLength() {
        XCTAssertNil(GoogleSlidesDriver.fullLengthFromEmbedURL(
            "https://www.youtube.com/embed/abcDEF12345?rel=0&rct=TOKEN"))
        XCTAssertNil(GoogleSlidesDriver.fullLengthFromEmbedURL("https://docs.google.com/nothing?a=b"))
        XCTAssertNil(GoogleSlidesDriver.fullLengthFromEmbedURL("https://youtube.googleapis.com/embed/?length_seconds=0"))
    }

    func testTrimmedAppliesTheElementTrimPoints() {
        XCTAssertEqual(SlidesInfo.trimmed(full: 60, start: 2, end: 12), 10)
        XCTAssertEqual(SlidesInfo.trimmed(full: 60, start: 5, end: 0), 55)
        XCTAssertEqual(SlidesInfo.trimmed(full: 60, start: 0, end: 0), 60)
        // The measured Drive case: embed said 5.769 s, Drive said 5769 ms.
        XCTAssertEqual(SlidesInfo.trimmed(full: 5.769, start: 0, end: 0), 5.769)
    }
}
