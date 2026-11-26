//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcGrabTests

/// CANCEL must stop everything a job started and leave nothing that looks like a delivery.
final class CancelCleanupTests: XCTestCase {
    /// yt-dlp runs ffmpeg as its child; cancelling yt-dlp alone could leave ffmpeg writing.
    func testCancelKillsGrandchildren() async throws {
        let runner = ProcessRunner("/bin/sh", ["-c", "sleep 30 & sleep 30 & wait"], env: ProcessInfo.processInfo.environment)
        let done = Task { try await runner.run { _ in } }
        var kids: [pid_t] = []
        for _ in 0..<50 where kids.count < 2 {
            try await Task.sleep(nanoseconds: 50_000_000)
            kids = runner.pid > 0 ? ProcessRunner.descendants(of: runner.pid) : []
        }
        XCTAssertEqual(kids.count, 2, "the shell's two sleeps")
        runner.cancel()
        _ = try await done.value
        try await Task.sleep(nanoseconds: 200_000_000)
        for k in kids { XCTAssertNotEqual(kill(k, 0), 0, "grandchild \(k) still alive") }
    }

    /// A section download writes the final name directly: a cancelled one must not leave that stub, and must
    /// not touch an older file with the same id or another job's delivery.
    @MainActor
    func testCleanupRemovesStubsOnlyFromThisJob() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("arcgrab-cleanup-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func touch(_ n: String) -> String { let p = dir.appendingPathComponent(n).path; fm.createFile(atPath: p, contents: Data("x".utf8)); return p }

        let older = touch("Clip [abc].mov")                     // an earlier grab of the same video
        Thread.sleep(forTimeInterval: 1.2)
        let queue = GrabQueue(startEngine: false)
        var o = GrabOptions(); o.destination = dir.path
        let info = MediaInfo(id: "abc", title: "Clip", url: "https://youtu.be/abc")
        let job = GrabJob(sourceURL: info.url, options: o, info: info)
        let other = GrabJob(sourceURL: info.url, options: o, info: info)
        queue.jobs = [job, other]
        job.startedAt = Date()
        Thread.sleep(forTimeInterval: 1.2)
        let stub = touch("Clip [abc].mp4")                      // this job's truncated section download
        let part = touch("Clip [abc].f137.mp4.part")
        let theirs = touch("Clip [abc].wav"); other.outputPath = theirs
        let unrelated = touch("Other [xyz].mp4")

        queue.cleanupPartials(job)
        XCTAssertFalse(fm.fileExists(atPath: stub))
        XCTAssertFalse(fm.fileExists(atPath: part))
        XCTAssertTrue(fm.fileExists(atPath: older))
        XCTAssertTrue(fm.fileExists(atPath: theirs))
        XCTAssertTrue(fm.fileExists(atPath: unrelated))
    }
}
