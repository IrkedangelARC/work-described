//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import ARCShowFormat
@testable import ArcCaptureTests

/// A slide that links to an online video: the analyzer names the link, the review asks when it was not
/// fetched (OnlineVideo.swift, 2026-09-19: "any link to a YouTube video should use ARC Grab").
final class OnlineVideoTests: XCTestCase {
    func testVideoIDsAreReadFromTheUsualLinks() {
        XCTAssertEqual(OnlineVideo.id(of: "https://www.youtube.com/watch?v=abcDEF12345"), "abcDEF12345")
        XCTAssertEqual(OnlineVideo.id(of: "https://www.youtube.com/watch?v=abcDEF12345&t=42s"), "abcDEF12345")
        XCTAssertEqual(OnlineVideo.id(of: "https://youtu.be/abcDEF12345?si=abc"), "abcDEF12345")
        XCTAssertEqual(OnlineVideo.id(of: "https://www.youtube.com/embed/abcDEF12345"), "abcDEF12345")
        XCTAssertEqual(OnlineVideo.id(of: "https://youtube.com/shorts/abc_DEF-123"), "abc_DEF-123")
        XCTAssertEqual(OnlineVideo.id(of: "https://vimeo.com/1084537"), "vimeo-1084537")
        XCTAssertEqual(OnlineVideo.id(of: "https://player.vimeo.com/video/1084537?h=1"), "vimeo-1084537")
        XCTAssertNil(OnlineVideo.id(of: "https://www.example.edu/"))
        XCTAssertNil(OnlineVideo.id(of: "https://www.youtube.com/"))
        XCTAssertEqual(OnlineVideo.stem(for: "https://youtu.be/abcDEF12345"), "abcDEF12345")
        XCTAssertTrue(OnlineVideo.stem(for: "https://example.com/x").hasPrefix("grab-"))
    }

    func testFileSharingLinksAreReadAndTurnedIntoDownloads() throws {
        XCTAssertEqual(FileShare.source(of: "https://drive.google.com/file/d/1AbC_dEf-9/view?usp=sharing"), .googleDrive(id: "1AbC_dEf-9"))
        XCTAssertEqual(FileShare.source(of: "https://drive.google.com/open?id=1AbC_dEf-9"), .googleDrive(id: "1AbC_dEf-9"))
        XCTAssertEqual(FileShare.source(of: "https://drive.google.com/uc?export=download&id=1AbC_dEf-9"), .googleDrive(id: "1AbC_dEf-9"))
        XCTAssertNil(FileShare.source(of: "https://docs.google.com/presentation/d/1AbC/edit"), "a Slides deck is not a file")
        XCTAssertNil(FileShare.source(of: "https://drive.google.com/drive/folders/1AbC"), "a folder is not a file")
        XCTAssertEqual(FileShare.downloadURL(.googleDrive(id: "1AbC_dEf-9")).absoluteString, "https://drive.usercontent.google.com/download?id=1AbC_dEf-9&export=download&confirm=t")
        let dbx = try XCTUnwrap(FileShare.source(of: "https://www.dropbox.com/scl/fi/abc123/Sizzle.mp4?rlkey=xyz&dl=0"))
        XCTAssertEqual(FileShare.downloadURL(dbx).absoluteString, "https://www.dropbox.com/scl/fi/abc123/Sizzle.mp4?rlkey=xyz&dl=1")
        XCTAssertEqual(FileShare.source(of: "https://app.box.com/s/k3y"), .box(key: "k3y"))
        XCTAssertNotNil(FileShare.source(of: "https://1drv.ms/v/s!AbCd"))
        XCTAssertEqual(FileShare.source(of: "https://cdn.example.com/media/Sizzle Reel.MOV"), .direct(URL(string: "https://cdn.example.com/media/Sizzle%20Reel.MOV")!))
        XCTAssertNil(FileShare.source(of: "https://www.example.edu/about"))
        XCTAssertEqual(FileShare.stem(.googleDrive(id: "1AbC_dEf-9"), url: "x"), "gdrive-1AbC_dEf-9")
        XCTAssertTrue(FileShare.stem(dbx, url: "https://www.dropbox.com/scl/fi/abc123/Sizzle.mp4?rlkey=xyz&dl=0").hasPrefix("dropbox-"))
        XCTAssertTrue(OnlineVideo.isVideoLink("https://drive.google.com/file/d/1AbC/view")); XCTAssertFalse(OnlineVideo.isVideoLink("https://www.example.edu/"))
        let rels = """
        <Relationships><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://drive.google.com/file/d/1AbC/view?usp=drive_link" TargetMode="External"/></Relationships>
        """
        XCTAssertEqual(OnlineVideo.links(inRels: rels), ["https://drive.google.com/file/d/1AbC/view?usp=drive_link"])
    }

    /// A real direct link (network): the file comes down, is read by ffprobe and lands under its stem.
    func testADirectFileLinkIsDownloadedAndKept() async throws {
        try XCTSkipIf(PPTXAnalyzer.ffprobeURL == nil, "no ffprobe")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grabs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4"
        var lines: [String] = []
        let r = await FileShare.fetch(url: url, into: dir) { lines.append($0) }
        guard case .success(let file) = r else { return XCTFail("fetch failed: \(r)") }
        XCTAssertTrue(file.lastPathComponent.hasPrefix("file-Big_Buck_Bunny_360_10s_1MB-"), file.path)
        XCTAssertGreaterThan((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0, 500_000)
        let again = await FileShare.fetch(url: url, into: dir) { lines.append($0) }
        guard case .success(let same) = again, same == file else { return XCTFail("second fetch did not reuse the file") }
        XCTAssertTrue(lines.last?.contains("already here") == true)
    }

    /// A real Google Drive link (network), when the run names one: TEST_RUNNER_ARC_TEST_DRIVE_LINK=<share link>.
    func testAGoogleDriveShareLinkIsDownloaded() async throws {
        guard let link = ProcessInfo.processInfo.environment["ARC_TEST_DRIVE_LINK"], !link.isEmpty else { throw XCTSkip("no ARC_TEST_DRIVE_LINK") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grabs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var lines: [String] = []
        let r = await FileShare.fetch(url: link, into: dir) { lines.append($0) }
        guard case .success(let file) = r else { return XCTFail("fetch failed: \(r) \(lines)") }
        XCTAssertTrue(file.lastPathComponent.hasPrefix("gdrive-"), file.path)
        XCTAssertGreaterThan((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0, 1000)
    }

    func testLinksAreReadFromTheSlideRels() {
        // 7.94 slide 10: a picture with an external hyperlink to YouTube, plus the usual internal rels.
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://www.youtube.com/watch?v=abcDEF12345&amp;feature=share" TargetMode="External"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image7.png"/>
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout2.xml"/>
        <Relationship Id="rId4" TargetMode="External" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://www.example.edu/"/>
        </Relationships>
        """
        XCTAssertEqual(OnlineVideo.links(inRels: rels), ["https://www.youtube.com/watch?v=abcDEF12345&feature=share"])
        XCTAssertEqual(OnlineVideo.links(inRels: "<Relationships/>"), [])
    }

    func testAPageWhoseLinkWasNotFetchedIsR13AndAPlacedOneIsNot() {
        var notFetched = DeckManifest.Slide(slide: 10, type: .image)
        notFetched.pptxSlide = 10
        notFetched.media = [DeckManifest.Media(kind: .video, name: "not fetched: ARC Grab is not installed (looked in /Applications)", url: "https://www.youtube.com/watch?v=abcDEF12345")]
        var placed = DeckManifest.Slide(slide: 11, type: .video, file: "media/slide_011.mp4", clicks: [0])
        placed.pptxSlide = 11; placed.sourceMovie = true
        placed.media = [DeckManifest.Media(kind: .video, name: "slide_011.mp4", seconds: 621, url: "https://youtu.be/abcDEF12345")]
        let m = DeckManifest(slides: [notFetched, placed])
        let item = ShowSpec.Item(id: "7.94", title: "t", source: "decks/7.94 t.pptx", kind: .powerpoint, status: .ready, versions: [])
        let rows = ReviewRules.evaluate(item: item, report: nil, verifyDetail: "ok", manifest: m, sidecars: [], deckRel: "arcdecks/x")
        XCTAssertEqual(rows.map(\.rule), ["R13"])
        XCTAssertEqual(rows.first?.slide, 10)
        XCTAssertEqual(rows.first?.evidence["url"], "https://www.youtube.com/watch?v=abcDEF12345")
        XCTAssertTrue(rows.first?.reason.contains("ARC Grab is not installed") == true)
    }
}
