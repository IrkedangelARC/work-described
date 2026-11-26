import XCTest
@testable import ARC_Show_Mode

final class QuitPolicyTests: XCTestCase {

    func testClosesOnlyListedApps() {
        let running = ["com.google.chrome", "com.google.drivefs", "com.apple.MobileSMS", "us.zoom.xos"]
        XCTAssertEqual(QuitPolicy.toClose(running: running, extra: [], keep: []),
                       ["com.google.drivefs", "com.apple.MobileSMS"])
    }

    func testShowAppsAreNeverTargets() {
        let targets = QuitPolicy.targets(extra: [], keep: [])
        for show in ["com.google.Chrome", "com.apple.Safari", "us.zoom.xos", "com.microsoft.Powerpoint",
                     "com.apple.iWork.Keynote", "com.example.arc.ArcPresenter"] {
            XCTAssertFalse(targets.contains(show), show)
        }
    }

    func testSyncClientsComeFirstAndAreForced() {
        let order = QuitPolicy.toClose(running: ["com.apple.mail", "com.getdropbox.dropbox"], extra: [], keep: [])
        XCTAssertEqual(order, ["com.getdropbox.dropbox", "com.apple.mail"])
        XCTAssertTrue(QuitPolicy.isForce("com.google.drivefs"))
        XCTAssertFalse(QuitPolicy.isForce("com.apple.mail"))
    }

    func testExtraAndKeep() {
        let running = ["com.apple.mail", "com.example.Chat"]
        XCTAssertEqual(QuitPolicy.toClose(running: running, extra: ["com.example.Chat"], keep: ["com.apple.mail"]),
                       ["com.example.Chat"])
    }

    func testExtraDuplicatingBuiltInIsListedOnce() {
        XCTAssertEqual(QuitPolicy.toClose(running: ["com.apple.mail"], extra: ["com.apple.mail"], keep: []),
                       ["com.apple.mail"])
    }

    func testSessionRoundTrips() {
        let defaults = UserDefaults(suiteName: "ArcShowModeTests")!
        defer { defaults.removePersistentDomain(forName: "ArcShowModeTests") }
        let s = ShowSession(startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                            closedBundleIDs: ["com.google.drivefs"], priorAlertVolume: 75)
        s.save(defaults)
        XCTAssertEqual(ShowSession.load(defaults), s)
        ShowSession.clear(defaults)
        XCTAssertNil(ShowSession.load(defaults))
    }
}

final class StaleSessionTests: XCTestCase {
    func testEighteenHoursIsTheLine() {
        XCTAssertEqual(ShowMode.staleAfter, 18 * 3600)
        let old = ShowSession(startedAt: Date().addingTimeInterval(-ShowMode.staleAfter - 60), closedBundleIDs: [], priorAlertVolume: nil)
        XCTAssertGreaterThan(Date().timeIntervalSince(old.startedAt), ShowMode.staleAfter)
    }
}
