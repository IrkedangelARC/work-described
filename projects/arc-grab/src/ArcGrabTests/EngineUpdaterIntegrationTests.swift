//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcGrabTests

/// Real network: pulls the current yt-dlp_macos.zip from GitHub into a temp
/// managed root, exactly what UPDATE ENGINE does on a fleet laptop.
final class EngineUpdaterIntegrationTests: XCTestCase {
    func testLatestTagLooksLikeADate() async throws {
        let tag = try await EngineUpdater.latestTag()
        XCTAssertNotNil(tag.range(of: #"^\d{4}\.\d{2}\.\d{2}"#, options: .regularExpression), tag)
    }

    func testInstallIntoManagedRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arcgrab-upd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tag = try await EngineUpdater.latestTag()
        var msgs: [String] = []
        let box = LineBox()
        let v = try await EngineUpdater.install(tag: tag, managedRoot: root, env: Toolchain().environment()) { box.append($0) }
        msgs = [box.lastLine]
        XCTAssertEqual(v, tag, msgs.joined())
        let dir = root.appendingPathComponent("yt-dlp")
        XCTAssertTrue(Toolchain.isYtdlpDir(dir))
        XCTAssertEqual(Toolchain.dirVersion(dir), tag)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("yt-dlp.update").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("yt-dlp.old").path))
    }
}
