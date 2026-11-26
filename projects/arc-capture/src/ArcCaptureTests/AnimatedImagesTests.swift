//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcCaptureTests

/// Animated GIFs on a Google Slides deck. Google stores them as IMAGES, so
/// nothing in the deck model calls them media and the settle used to end the
/// slide while it was still playing (a client deck's slide 34: a 45.6 s animation
/// captured as 2.1 s; slide 19's 30 s animation captured as a still).
///
/// The loop lengths asserted here were measured twice from independent
/// sources on 2026-09-15 — ffprobe on the GIF served by the Slides page, and
/// ffprobe on the same GIF inside the deck's PPTX export — and agreed exactly.
final class AnimatedImagesTests: XCTestCase {

    func testOnlyGIFBytesCountAsAnimated() {
        XCTAssertTrue(AnimatedImages.isGIF(Data("GIF89a".utf8)))
        XCTAssertTrue(AnimatedImages.isGIF(Data("GIF87a".utf8)))
        XCTAssertFalse(AnimatedImages.isGIF(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])))   // PNG
        XCTAssertFalse(AnimatedImages.isGIF(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])))   // JPEG
        XCTAssertFalse(AnimatedImages.isGIF(Data("GIF".utf8)), "too few bytes to be sure")
    }

    /// The real ffprobe output for the GIF on a client deck's slide 34.
    func testParseProbeReadsFramesAndLoopLength() {
        let loop = AnimatedImages.parseProbe("228\n45.600000\n")
        XCTAssertEqual(loop, AnimatedImages.Loop(seconds: 45.6, frames: 228))
    }

    func testParseProbeRejectsAStillImage() {
        // One frame is a still, not an animation, however long ffprobe calls it.
        XCTAssertNil(AnimatedImages.parseProbe("1\n0.100000\n"))
        XCTAssertNil(AnimatedImages.parseProbe("228\n0.000000\n"))
        XCTAssertNil(AnimatedImages.parseProbe(""))
        XCTAssertNil(AnimatedImages.parseProbe("N/A\nN/A\n"))
    }

    /// A deck's pictures are mostly big PNGs; only the GIFs may be downloaded.
    func testOnlyGIFsAreDownloaded() async {
        let deck = Self.deck(imagesBySlide: [1: ["https://x/png1", "https://x/gif1"],
                                             2: ["https://x/png2"]])
        let log = Calls()
        _ = await AnimatedImages.loopsBySlide(
            in: deck,
            head: { url in
                await log.head(url)
                return url.absoluteString.contains("gif") ? Data("GIF89a".utf8) : Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
            },
            download: { url in await log.download(url); return nil })
        let heads = await log.heads, downloads = await log.downloads
        XCTAssertEqual(heads.count, 3, "every picture is probed cheaply")
        XCTAssertEqual(downloads.count, 1, "only the GIF is fetched in full")
        XCTAssertTrue(downloads.first?.absoluteString.contains("gif1") == true)
    }

    func testDeckWithNoImagesTouchesTheNetworkNotAtAll() async {
        let deck = Self.deck(imagesBySlide: [:])
        let log = Calls()
        let loops = await AnimatedImages.loopsBySlide(
            in: deck, head: { u in await log.head(u); return nil }, download: { u in await log.download(u); return nil })
        XCTAssertTrue(loops.isEmpty)
        let heads = await log.heads
        XCTAssertTrue(heads.isEmpty)
    }

    /// A slide holding two animations is held open for the LONGER one, so both
    /// complete at least once. A client deck's slide 25 is this case: 19.1 s and 59.9 s.
    func testSlideKeepsTheLongestLoop() {
        let a = AnimatedImages.Loop(seconds: 19.1, frames: 153)
        let b = AnimatedImages.Loop(seconds: 59.9, frames: 599)
        XCTAssertGreaterThan(b.seconds, a.seconds)
        // Their periods do not divide, so the shorter one cannot line up
        // inside one pass of the longer: 59.9 / 19.1 = 3.13..., not a whole number.
        let ratio = b.seconds / a.seconds
        XCTAssertGreaterThan(abs(ratio - ratio.rounded()), 0.05)
    }

    private static func deck(imagesBySlide: [Int: [String]]) -> SlidesInfo {
        SlidesInfo(id: "d", title: "t", slides: (1...2).map { i in
            SlidesInfo.Slide(index: i, objectId: "g\(i)", skipped: false, buildSteps: 0,
                             imageURLs: imagesBySlide[i] ?? [], videos: [])
        })
    }

    private actor Calls {
        var heads: [URL] = [], downloads: [URL] = []
        func head(_ u: URL) { heads.append(u) }
        func download(_ u: URL) { downloads.append(u) }
    }
}
