//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcDisplayKit

/// Policy regressions — mirrors the suite that shipped inside ARC
/// Assimilator v2.0.0, so the kit enforces the same guarantees standalone.
final class DisplayPolicyTests: XCTestCase {

    private func disp(_ id: UInt32, name: String, main: Bool = false,
                      role: DisplayRole = .auto, occupied: String? = nil) -> DisplaySnapshot {
        DisplaySnapshot(id: id, uuid: "uuid-\(id)", name: name,
                        bounds: CGRect(x: main ? 0 : 1920 * Int(id), y: 0,
                                       width: 1920, height: 1080),
                        isMain: main, role: role, occupiedBy: occupied)
    }

    func testUnverifiedMapBlocksWindowedCapture() {
        let choice = DisplayPolicy.chooseCaptureDisplay([
            disp(1, name: "Main", main: true),
            disp(2, name: "Bench"),
        ], mapVerified: false)
        XCTAssertNil(choice.display)
        XCTAssertTrue(choice.warnings.contains { $0.contains("UNVERIFIED") })
    }

    func testLiveOutIsNeverChosen() {
        let choice = DisplayPolicy.chooseCaptureDisplay([
            disp(1, name: "Main", main: true),
            disp(2, name: "Projector", role: .liveOut),
        ], mapVerified: true)
        XCTAssertNil(choice.display, "a LIVE OUT must never become a capture surface")
    }

    func testSoleFreeAutoExternalIsChosen() {
        let choice = DisplayPolicy.chooseCaptureDisplay([
            disp(1, name: "Main", main: true),
            disp(2, name: "Bench"),
        ], mapVerified: true)
        XCTAssertEqual(choice.display?.name, "Bench")
    }

    func testExplicitCaptureBeatsAuto() {
        let choice = DisplayPolicy.chooseCaptureDisplay([
            disp(1, name: "Main", main: true),
            disp(2, name: "Bench"),
            disp(3, name: "Rig", role: .capture),
        ], mapVerified: true)
        XCTAssertEqual(choice.display?.name, "Rig")
    }

    func testOccupiedCaptureDisplayAbortsWithWarning() {
        let choice = DisplayPolicy.chooseCaptureDisplay([
            disp(1, name: "Main", main: true),
            disp(2, name: "Rig", role: .capture, occupied: "ARC Presenter"),
        ], mapVerified: true)
        XCTAssertNil(choice.display)
        XCTAssertTrue(choice.warnings.contains { $0.contains("occupied") })
    }

    func testMultipleAutoExternalsRequireExplicitChoice() {
        let choice = DisplayPolicy.chooseCaptureDisplay([
            disp(1, name: "Main", main: true),
            disp(2, name: "A"), disp(3, name: "B"),
        ], mapVerified: true)
        XCTAssertNil(choice.display)
        XCTAssertTrue(choice.warnings.contains { $0.contains("mark one as Capture") })
    }

    // MARK: - Occupancy: content layers only (2026-09-04 Magnet false positive)

    private func win(_ owner: String, layer: Int, x: CGFloat, w: CGFloat = 1920, h: CGFloat = 1080) -> [String: Any] {
        [kCGWindowOwnerName as String: owner,
         kCGWindowLayer as String: layer,
         kCGWindowBounds as String: ["X": x, "Y": CGFloat(0), "Width": w, "Height": h]]
    }

    func testWindowManagerOverlayIsNotAnOccupant() {
        let display = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        // Magnet: layer 25, exactly display-sized, on every display.
        XCTAssertNil(DisplayPolicy.fullscreenOwner(on: display, windows: [win("Magnet", layer: 25, x: 1920)]))
        // Other utility chrome in the 1…999 band is ignored too.
        XCTAssertNil(DisplayPolicy.fullscreenOwner(on: display, windows: [win("Bartender", layer: 101, x: 1920)]))
    }

    func testLiveOutputAndFullscreenAppStillOccupy() {
        let display = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        // ARC Presenter's program output runs at screensaver/shielding level.
        XCTAssertEqual(DisplayPolicy.fullscreenOwner(on: display, windows: [win("ARC Presenter", layer: 1000, x: 1920)]),
                       "ARC Presenter")
        // A normal app window that happens to be fullscreen (video player).
        XCTAssertEqual(DisplayPolicy.fullscreenOwner(on: display, windows: [win("QuickTime Player", layer: 0, x: 1920)]),
                       "QuickTime Player")
        // Same window on the OTHER display does not occupy this one.
        XCTAssertNil(DisplayPolicy.fullscreenOwner(on: display, windows: [win("QuickTime Player", layer: 0, x: 0)]))
    }

    func testTopologyFingerprintChangesWithLayout() {
        let a = [disp(1, name: "Main", main: true), disp(2, name: "Ext")]
        var moved = a
        moved[1].bounds.origin.x += 100
        XCTAssertNotEqual(MonitorInventory.fingerprint(a),
                          MonitorInventory.fingerprint(moved),
                          "any topology change must invalidate verification")
    }
}
