//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcGrabTests

final class ToolchainTests: XCTestCase {
    func testSeedCopiesWhenMissingAndUpgradesOnlyForward() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("arcgrab-seed-\(UUID().uuidString)")
        let managed = tmp.appendingPathComponent("engine")
        func makeSeed(_ name: String, _ version: String, body: String) throws -> URL {
            let d = tmp.appendingPathComponent(name)
            try fm.createDirectory(at: d.appendingPathComponent("_internal"), withIntermediateDirectories: true)
            let exe = d.appendingPathComponent(Toolchain.ytdlpExe)
            try "#!/bin/sh\necho \(body)\n".write(to: exe, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            try version.write(to: d.appendingPathComponent(Toolchain.versionFile), atomically: true, encoding: .utf8)
            return d
        }
        defer { try? fm.removeItem(at: tmp) }
        let seedA = try makeSeed("seedA", "2026.08.19", body: "A")
        let seedB = try makeSeed("seedB", "2026.09.30", body: "B")
        let seedOld = try makeSeed("seedOld", "2026.01.01", body: "OLD")
        let exe = managed.appendingPathComponent("yt-dlp/\(Toolchain.ytdlpExe)")
        let ver = managed.appendingPathComponent("yt-dlp/VERSION")

        XCTAssertNotNil(Toolchain.seedManagedYtdlp(bundledDir: seedA, managedRoot: managed))
        XCTAssertEqual(try String(contentsOf: exe, encoding: .utf8), "#!/bin/sh\necho A\n")
        XCTAssertTrue(fm.isExecutableFile(atPath: exe.path))
        // updater took the managed copy past the bundle: same-version relaunch keeps it
        try "#!/bin/sh\necho SELF\n".write(to: exe, atomically: true, encoding: .utf8)
        try "2026.09.01".write(to: ver, atomically: true, encoding: .utf8)
        _ = Toolchain.seedManagedYtdlp(bundledDir: seedA, managedRoot: managed)
        XCTAssertEqual(try String(contentsOf: exe, encoding: .utf8), "#!/bin/sh\necho SELF\n")
        // newer app release reseeds
        _ = Toolchain.seedManagedYtdlp(bundledDir: seedB, managedRoot: managed)
        XCTAssertEqual(try String(contentsOf: exe, encoding: .utf8), "#!/bin/sh\necho B\n")
        XCTAssertEqual(Toolchain.dirVersion(managed.appendingPathComponent("yt-dlp")), "2026.09.30")
        // older app never clobbers
        _ = Toolchain.seedManagedYtdlp(bundledDir: seedOld, managedRoot: managed)
        XCTAssertEqual(try String(contentsOf: exe, encoding: .utf8), "#!/bin/sh\necho B\n")
    }

    func testUpdaterTagCompare() {
        XCTAssertTrue(EngineUpdater.isNewer("2026.09.30", than: "2026.08.19"))
        XCTAssertFalse(EngineUpdater.isNewer("2026.08.19", than: "2026.08.19"))
        XCTAssertFalse(EngineUpdater.isNewer("2025.12.08", than: "2026.08.19"))
        XCTAssertEqual(EngineUpdater.zipURL("2026.08.19").absoluteString,
                       "https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_macos.zip")
    }

    func testSystemCandidateOrder() {
        let c = Toolchain.systemCandidates("yt-dlp")
        XCTAssertTrue(c.contains("/opt/homebrew/bin/yt-dlp"))
        XCTAssertTrue(c.contains("/usr/local/bin/yt-dlp"))
        if let py = c.firstIndex(where: { $0.contains("/Library/Python/") }),
           let brew = c.firstIndex(of: "/opt/homebrew/bin/yt-dlp") {
            XCTAssertLessThan(py, brew, "pip --user installs win over brew (newer)")
        }
    }

    func testSystemUpdateCommand() {
        var t = Toolchain(ytdlp: "/x/engine/yt-dlp/yt-dlp_macos", ffmpeg: nil, ffprobe: nil, ytdlpSource: .managed)
        XCTAssertNil(t.systemUpdateCommand(), "managed copies go through EngineUpdater")
        t = Toolchain(ytdlp: "/opt/homebrew/bin/yt-dlp", ffmpeg: nil, ffprobe: nil, ytdlpSource: .system)
        XCTAssertEqual(t.systemUpdateCommand()?.exe, "/opt/homebrew/bin/brew")
        XCTAssertNil(Toolchain().systemUpdateCommand())
    }

    func testDiscoverFindsAnEngineOnTheBuildMachine() {
        let t = Toolchain.healthCheck(Toolchain.discover())
        XCTAssertTrue(t.isComplete, "build machine must have an engine for the integration tests")
        XCTAssertNotEqual(t.ytdlpVersion, "?")
        XCTAssertNotNil(t.whisper, "whisper-cli must be findable (bundled or Homebrew) for the transcript tests")
    }
}
