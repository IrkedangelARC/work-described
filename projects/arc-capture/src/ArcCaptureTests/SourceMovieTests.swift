//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import ARCShowFormat
@testable import ArcCaptureTests

/// The source movie in place of a recording of it (SourceMovie.swift): who qualifies, what ffmpeg is told,
/// and how the analyzer reads a movie's placement, trim and volume out of a slide.
final class SourceMovieTests: XCTestCase {
    private func moviePage(_ tweak: (inout DeckManifest.Slide, inout DeckManifest.Media) -> Void = { _, _ in }) -> DeckManifest.Slide {
        var m = DeckManifest.Media(kind: .video, name: "media1.mp4", seconds: 40, width: 1920, height: 1080, videoCodec: "h264", audioCodec: "aac", hasAudio: true, fillsSlide: true)
        var p = DeckManifest.Slide(slide: 3, type: .video, file: "media/slide_003.mov", clicks: [0.64], entryClick: 0)
        p.mediaStart = .onEntry
        tweak(&p, &m)
        p.media = [m]
        return p
    }

    func testWhoQualifies() {
        XCTAssertNil(BuildSplitter.sourceMovieObstacle(moviePage()))
        XCTAssertEqual(BuildSplitter.sourceMovieObstacle(moviePage { p, _ in p.mediaStart = .whenClickedOn }), "the movie does not play on entry")
        XCTAssertEqual(BuildSplitter.sourceMovieObstacle(moviePage { _, m in m.fillsSlide = false }), "the movie does not fill the slide")
        XCTAssertEqual(BuildSplitter.sourceMovieObstacle(moviePage { p, _ in p.loop = true }), "a looping movie (the loop separator owns it)")
        XCTAssertEqual(BuildSplitter.sourceMovieObstacle(moviePage { p, _ in p.clicks = [0.64, 9.0] }), "the slide has clicks of its own after entry")
        XCTAssertEqual(BuildSplitter.sourceMovieObstacle(moviePage { _, m in m.videoCodec = "vp9" }), "video codec vp9 is not one Presenter plays")
        XCTAssertEqual(BuildSplitter.sourceMovieObstacle(moviePage { _, m in m.name = "media1.avi" }), "container .avi is not one Presenter plays")
        XCTAssertEqual(BuildSplitter.sourceMovieObstacle(moviePage { p, _ in p.role = .opening }), "a logo page")
        XCTAssertEqual(BuildSplitter.sourceMovieObstacle(moviePage { p, _ in p.builds = [.init(file: nil, still: "s.png")] }), "the slide has builds")
        XCTAssertEqual(BuildSplitter.sourceMovieObstacle(moviePage { p, _ in p.entryFile = "media/x_in.mov" }), "already has its way in separate")
    }

    func testFFmpegArgs() {
        let src = URL(fileURLWithPath: "/tmp/m.mp4"), dst = URL(fileURLWithPath: "/tmp/out.mp4")
        let plain = BuildSplitter.sourceMovieArgs(source: src, dest: dst, trimStart: nil, trimEnd: nil, volume: nil, muted: nil)
        XCTAssertTrue(plain.contains("copy") && !plain.contains("-ss") && !plain.contains("-af") && !plain.contains("-an"))
        XCTAssertEqual(plain.filter { $0 == "copy" }.count, 2, "video and audio both copied")
        let trimmed = BuildSplitter.sourceMovieArgs(source: src, dest: dst, trimStart: 4.0328, trimEnd: 35.2088, volume: nil, muted: nil)
        XCTAssertEqual(trimmed[trimmed.firstIndex(of: "-ss")! + 1], "4.033")
        XCTAssertEqual(trimmed[trimmed.firstIndex(of: "-to")! + 1], "31.176", "duration after the start, not the absolute end")
        XCTAssertTrue(trimmed.contains("h264_videotoolbox"), "a trim re-encodes so the cut lands on the frame")
        let quiet = BuildSplitter.sourceMovieArgs(source: src, dest: dst, trimStart: nil, trimEnd: nil, volume: 0.8, muted: nil)
        XCTAssertFalse(quiet.contains("-af"), "PowerPoint's default vol=80000 must not quieten the deck")
        XCTAssertEqual(quiet.filter { $0 == "copy" }.count, 2)
        let muted = BuildSplitter.sourceMovieArgs(source: src, dest: dst, trimStart: nil, trimEnd: nil, volume: nil, muted: true)
        XCTAssertTrue(muted.contains("-an"))
    }

    func testPlacementFromSlideXML() {
        let size = PPTXAnalyzer.slideSize(presentationXML: #"<p:presentation><p:sldSz cx="12192000" cy="6858000" type="screen4x3"/></p:presentation>"#)
        XCTAssertEqual(size?.w, 12192000); XCTAssertEqual(size?.h, 6858000)
        let rels = #"<Relationships><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/video" Target="../media/media1.mp4"/><Relationship Id="rId4" Type="…/image" Target="../media/image1.png"/></Relationships>"#
        let full = #"<p:sld><p:cSld><p:spTree><p:pic><p:nvPicPr><p:cNvPr id="2" name="m"/><p:nvPr><a:videoFile r:link="rId3"/><p:extLst><p:ext><p14:media r:embed="rId2"><p14:trim st="4032.8" end="35208.8"/></p14:media></p:ext></p:extLst></p:nvPr></p:nvPicPr><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="12192000" cy="6858000"/></a:xfrm></p:spPr></p:pic></p:spTree></p:cSld><p:timing><p:video><p:cMediaNode vol="80000" mute="0"><p:cTn id="7"/><p:tgtEl><p:spTgt spid="2"/></p:tgtEl></p:cMediaNode></p:video></p:timing></p:sld>"#
        let pl = PPTXAnalyzer.mediaPlacements(slideXML: full, rels: rels, slideSize: size)["media1.mp4"]
        XCTAssertEqual(pl?.fillsSlide, true)
        XCTAssertEqual(pl!.trimStart!, 4.0328, accuracy: 0.0001); XCTAssertEqual(pl!.trimEnd!, 35.2088, accuracy: 0.0001)
        XCTAssertEqual(pl!.volume!, 0.8, accuracy: 0.001); XCTAssertNil(pl?.muted)
        // A movie in a quarter of the slide, untrimmed, full volume, muted.
        let small = #"<p:sld><p:pic><p:nvPicPr><p:cNvPr id="5" name="m"/><p:nvPr><a:videoFile r:link="rId3"/></p:nvPr></p:nvPicPr><p:spPr><a:xfrm><a:off x="6096000" y="3429000"/><a:ext cx="6096000" cy="3429000"/></a:xfrm></p:spPr></p:pic><p:timing><p:video><p:cMediaNode vol="100000" mute="1"><p:cTn id="7"/><p:tgtEl><p:spTgt spid="5"/></p:tgtEl></p:cMediaNode></p:video></p:timing></p:sld>"#
        let ps = PPTXAnalyzer.mediaPlacements(slideXML: small, rels: rels, slideSize: size)["media1.mp4"]
        XCTAssertEqual(ps?.fillsSlide, false); XCTAssertNil(ps?.trimStart); XCTAssertNil(ps?.volume); XCTAssertEqual(ps?.muted, true)
        // No videoFile: not a movie placement at all.
        XCTAssertTrue(PPTXAnalyzer.mediaPlacements(slideXML: "<p:sld><p:pic><p:spPr/></p:pic></p:sld>", rels: rels, slideSize: size).isEmpty)
    }

    /// The reference deck's own slide, as built: fills the slide, no trim, 80 % volume from PowerPoint's default node.
    func testReferenceDeckPlacement() throws {
        let deck = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tools/avsync/reference/ARC AV Reference.pptx")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: deck.path), "reference deck not in the checkout")
        let a = PPTXAnalyzer.analyze(deck)
        let m = try XCTUnwrap(a.slideMedia[2]?.first)
        XCTAssertEqual(m.fillsSlide, true); XCTAssertNil(m.trimStart); XCTAssertEqual(m.volume!, 0.8, accuracy: 0.001)
        XCTAssertEqual(a.mediaStarts[2], .onEntry)
    }
}
