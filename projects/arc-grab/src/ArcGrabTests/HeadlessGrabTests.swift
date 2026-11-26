//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcGrabTests

final class HeadlessGrabTests: XCTestCase {
    /// The 1.5.0 call ARC Capture makes must parse to the same MP4 1080, no-chapters grab.
    func testCaptureContractDefaults() throws {
        let r = try HeadlessGrab.parse(["--grab", "https://youtu.be/x", "--into", "/tmp/g", "--name", "clip", "--quality", "1080"])
        XCTAssertEqual(r.verb, .grab)
        XCTAssertEqual(r.urls, ["https://youtu.be/x"])
        XCTAssertEqual(r.name, "clip")
        XCTAssertEqual(r.options.mode, .video)
        XCTAssertEqual(r.options.videoFormat, .mp4)
        XCTAssertEqual(r.options.quality, .p1080)
        XCTAssertFalse(r.options.chapters)
        XCTAssertFalse(r.options.transcript)
        XCTAssertEqual(r.options.destination, "/tmp/g")
    }

    func testEveryControl() throws {
        let r = try HeadlessGrab.parse([
            "--grab", "https://vimeo.com/1", "https://vimeo.com/2", "--into", "~/g",
            "--format", "proreshq", "--quality", "best", "--transcript", "--subtitles", "--thumbnail",
            "--chapters", "--keep-source", "--in", "1:00", "--out", "2:30", "--cookies", "safari",
            "--referer", "https://example.com/page", "--password", "--dashy", "--parallel", "3",
        ])
        XCTAssertEqual(r.urls.count, 2)
        XCTAssertEqual(r.options.videoFormat, .prores422HQ)
        XCTAssertEqual(r.options.quality, .best)
        XCTAssertTrue(r.options.transcript && r.options.subtitles && r.options.thumbnail && r.options.chapters && r.options.keepSource)
        XCTAssertEqual(r.options.sectionIn, "1:00")
        XCTAssertEqual(r.options.sectionOut, "2:30")
        XCTAssertEqual(r.options.cookies, .safari)
        XCTAssertEqual(r.options.referer, "https://example.com/page")
        XCTAssertEqual(r.options.videoPassword, "--dashy")
        XCTAssertEqual(r.parallel, 3)
        XCTAssertFalse(r.options.destination.hasPrefix("~"))
    }

    func testAudioMode() throws {
        let r = try HeadlessGrab.parse(["--grab", "https://youtu.be/x", "--into", "/tmp", "--audio", "mp3"])
        XCTAssertEqual(r.options.mode, .audio)
        XCTAssertEqual(r.options.audioFormat, .mp3)
    }

    func testEngineVerbsNeedNoURL() throws {
        XCTAssertEqual(try HeadlessGrab.parse(["--status"]).verb, .status)
        XCTAssertEqual(try HeadlessGrab.parse(["--update-engine"]).verb, .updateEngine)
        XCTAssertEqual(try HeadlessGrab.parse(["--repair-engine"]).verb, .repairEngine)
        XCTAssertEqual(try HeadlessGrab.parse(["--fetch-models"]).verb, .fetchModels)
    }

    func testUsageErrors() {
        XCTAssertThrowsError(try HeadlessGrab.parse(["--grab", "https://youtu.be/x"]))                       // no --into
        XCTAssertThrowsError(try HeadlessGrab.parse(["--grab", "https://a/1", "--grab", "https://a/2", "--into", "/t", "--name", "n"]))
        XCTAssertThrowsError(try HeadlessGrab.parse(["--grab", "https://a", "--into", "/t", "--quality", "480"]))
        XCTAssertThrowsError(try HeadlessGrab.parse(["--grab", "https://a", "--into", "/t", "--bogus"]))
        XCTAssertThrowsError(try HeadlessGrab.parse(["--grab", "--into", "/t"]))
    }
}
