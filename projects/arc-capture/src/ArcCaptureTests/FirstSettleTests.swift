//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import AVFoundation
@testable import ArcCaptureTests

/// The first slide's settle gate, which had no ceiling at all until
/// 2026-09-20: a movie that plays on entry and never stills gave it no quiet
/// stream to wait for, and the whole show run stopped (ARC Test Show 02,
/// items 2.07 and 3.07, 14 to 20 minutes on four
/// machines before a hand kill).
///
/// Both tests below HANG for ever against the code as it was; that is the
/// point of them. The ceilings are shortened so they run in about a second.
@MainActor
final class FirstSettleTests: XCTestCase {

    private func makeSession(_ driver: FakeDriver, _ frames: FakeFrameSource) throws -> CaptureSession {
        let s = CaptureSession(driver: driver, frameSource: frames, recorder: VideoRecorder())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("first-settle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        s.sourceFile = dir.appendingPathComponent("Fake.pptx")
        FileManager.default.createFile(atPath: s.sourceFile!.path, contents: Data())
        s.outputDirectory = dir
        s.dwellTime = 0.05
        s.firstSettleMovieGrace = 0.5
        s.firstSettleCeiling = 1.0
        return s
    }

    /// Entering slide `n` produces motion that never stills: the music video.
    /// Long enough to outlast any ceiling these tests set.
    private func neverStills(_ frames: FakeFrameSource, slide n: Int) async {
        for _ in 0..<120 {
            if Task.isCancelled { return }
            await frames.showSlide(n, motionFrames: 1, then: false)
        }
    }

    /// The reported bug: slide 1 carries a movie the XML says starts on
    /// entry, and the picture never stills. The gate must give up on the
    /// settle and hand the slide to the movie path, which records instead of
    /// waiting for stillness.
    func testOpeningAutoplayMovieThatNeverStillsIsRecordedNotWaitedFor() async throws {
        let driver = FakeDriver(slides: 2, movies: [1: 0.4]), frames = FakeFrameSource()
        driver.analysis.autoPlaySlides.insert(1)
        let s = try makeSession(driver, frames)

        driver.onAdvance = { pos in Task { @MainActor in
            if pos == 1 { await self.neverStills(frames, slide: 1) }
            else {
                try? await Task.sleep(for: .milliseconds(80))
                await frames.showSlide(pos, motionFrames: 20, then: true)
            }
        } }

        // The movie's own end: once the movie path has the recorder rolling,
        // the picture stops and the clip is finalised, exactly as a real
        // movie's last frame does.
        let endOfMovie = Task { @MainActor in
            while !Task.isCancelled, !s.recorder.isRecording { try? await Task.sleep(for: .milliseconds(20)) }
            try? await Task.sleep(for: .milliseconds(300))
            await frames.showSlide(1, motionFrames: 6, then: true)
        }
        defer { endOfMovie.cancel() }

        let rep = try await s.run()
        XCTAssertTrue(rep.ok, rep.error ?? "")
        XCTAssertEqual(s.slides.count, 2, "the run finished instead of stopping on slide 1")
        XCTAssertEqual(s.slides[0].slideType, .video, "the opening movie was recorded, not kept as a still")
        XCTAssertTrue(rep.warnings.contains { $0.contains("still playing after") },
                      "the report says the movie outlasted the settle: \(rep.warnings)")
    }

    /// Nothing explains the stall: no movie on the slide at all. A deck with
    /// one suspect page beats a run that never ends, so the live frame is
    /// kept, flagged, and the walk goes on.
    func testFirstSlideThatNeverSettlesKeepsTheLiveFrameAndWalksOn() async throws {
        let driver = FakeDriver(slides: 2), frames = FakeFrameSource()
        let s = try makeSession(driver, frames)

        driver.onAdvance = { pos in Task { @MainActor in
            if pos == 1 { await self.neverStills(frames, slide: 1) }
            else {
                try? await Task.sleep(for: .milliseconds(80))
                await frames.showSlide(pos, motionFrames: 20, then: true)
            }
        } }

        let rep = try await s.run()
        XCTAssertTrue(rep.ok, rep.error ?? "")
        XCTAssertEqual(s.slides.count, 2, "the run finished instead of stopping on slide 1")
        XCTAssertEqual(s.slides[0].endedBy, "first-settle timeout", "page 1 says how it was ended")
        XCTAssertTrue(rep.warnings.contains { $0.contains("never settled within") },
                      "the report says the first slide never settled: \(rep.warnings)")
    }

    /// The gate costs a deck that behaves nothing: a normal first slide
    /// settles, the watchdog is cancelled, and no warning is raised.
    func testNormalFirstSlideRaisesNoTimeoutWarning() async throws {
        let driver = FakeDriver(slides: 2), frames = FakeFrameSource()
        let s = try makeSession(driver, frames)
        driver.onAdvance = { pos in Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            await frames.showSlide(pos, motionFrames: pos == 1 ? 0 : 20, then: true)
        } }
        let rep = try await s.run()
        XCTAssertTrue(rep.ok, rep.error ?? "")
        XCTAssertEqual(s.slides.count, 2)
        XCTAssertNil(s.firstSettleWatchdog, "the first settle cancelled and cleared the watchdog")
        XCTAssertFalse(rep.warnings.contains { $0.contains("never settled within") || $0.contains("still playing after") },
                       "a deck that behaves gets no timeout warning: \(rep.warnings)")
    }
}
