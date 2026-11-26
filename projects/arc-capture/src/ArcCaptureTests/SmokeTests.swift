//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest

final class SmokeTests: XCTestCase {
    func testTargetLinks() {
        XCTAssertEqual(SlideType.video.rawValue, "video")
    }

    /// The suite must not write into the TD's log or move the TD's last show (it did both until 2026-09-17).
    func testTheSuiteLeavesTheRealAppStateAlone() throws {
        XCTAssertTrue(AppEnvironment.isTestHost)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertFalse(DebugLog.core.url.path.hasPrefix(home + "/Library/Logs"), "the log goes to a temp folder under test: \(DebugLog.core.url.path)")
        let before = UserDefaults.standard.string(forKey: ShowFolderStore.lastFolderKey)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        _ = try MainActor.assumeIsolated { try ShowFolderStore.create(name: "Smoke", date: nil, under: parent) }
        XCTAssertEqual(UserDefaults.standard.string(forKey: ShowFolderStore.lastFolderKey), before)
    }
}
