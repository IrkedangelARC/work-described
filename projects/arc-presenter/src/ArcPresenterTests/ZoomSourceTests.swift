//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcPresenter

/// PLAN_zoom_source build A/B: what the window list tells Presenter about Zoom (drill 2026-09-20).
final class ZoomSourceTests: XCTestCase {
    private func win(_ id: CGWindowID, _ title: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, on: Bool = true) -> ZoomSource.Win {
        ZoomSource.Win(id: id, title: title, frame: CGRect(x: x, y: y, width: w, height: h), onScreen: on)
    }

    func testOneMeetingWindowIsNotDualMonitorsAndHasNoSecond() {
        let s = ZoomSource.classify(zoomWindows: [win(20021, "Zoom Meeting", 0, 30, 1309, 1122), win(20024, "Zoom Workplace", 34, 214, 1440, 851)],
                                    zoomRunning: true, shareFrame: nil)
        XCTAssertTrue(s.inMeeting); XCTAssertFalse(s.dualMonitors); XCTAssertNil(s.secondWindowID)
        XCTAssertEqual(s.mainWindowID, 20021)
    }

    func testSecondWindowIsTheLaterMeetingWindowEvenOffScreen() {
        // 07:55: the main window collapsed off screen on share start, the second stayed (finding 22).
        let s = ZoomSource.classify(zoomWindows: [win(20021, "Zoom Meeting", 0, 30, 1677, 1122, on: false), win(20425, "Zoom Meeting", 174, 164, 1553, 820)],
                                    zoomRunning: true, shareFrame: nil)
        XCTAssertTrue(s.dualMonitors); XCTAssertEqual(s.secondWindowID, 20425); XCTAssertEqual(s.mainWindowID, 20021)
    }

    func testSmallMeetingTitledWindowsDoNotCount() {
        let s = ZoomSource.classify(zoomWindows: [win(20021, "Zoom Meeting", 0, 30, 1309, 1122), win(20099, "Zoom Meeting", 0, 0, 200, 100)],
                                    zoomRunning: true, shareFrame: nil)
        XCTAssertFalse(s.dualMonitors)
    }

    func testSharingOursNeedsTheAnnotationOverlayOnTheShareFrame() {
        let share = CGRect(x: 16, y: 596, width: 960, height: 540)
        let base = [win(20021, "Zoom Meeting", 0, 30, 1309, 1122), win(20113, "zoom share statusbar window", 614, 154, 358, 22)]
        let ours = ZoomSource.classify(zoomWindows: base + [win(20825, "Annotation - Zoom", 16, 596, 960, 540)], zoomRunning: true, shareFrame: share)
        XCTAssertTrue(ours.sharing); XCTAssertTrue(ours.sharingOurs)
        let other = ZoomSource.classify(zoomWindows: base + [win(20110, "Annotation - Zoom", 2048, 291, 1920, 1280)], zoomRunning: true, shareFrame: share)
        XCTAssertTrue(other.sharing); XCTAssertFalse(other.sharingOurs, "the overlay on ALOLG means a display share, not our window")
        let none = ZoomSource.classify(zoomWindows: [win(20021, "Zoom Meeting", 0, 30, 1309, 1122)], zoomRunning: true, shareFrame: share)
        XCTAssertFalse(none.sharing); XCTAssertFalse(none.sharingOurs)
    }

    func testFrozenIsOffScreenAndStaleWhileCapturing() {
        XCTAssertTrue(ZoomSource.isFrozen(windowOnScreen: false, lastFrameAge: 84, captureRunning: true), "finding 6")
        XCTAssertTrue(ZoomSource.isFrozen(windowOnScreen: false, lastFrameAge: nil, captureRunning: true))
        XCTAssertFalse(ZoomSource.isFrozen(windowOnScreen: false, lastFrameAge: 1, captureRunning: true), "just collapsed, give it a moment")
        XCTAssertFalse(ZoomSource.isFrozen(windowOnScreen: true, lastFrameAge: 84, captureRunning: true), "a static picture on a visible window is normal")
        XCTAssertFalse(ZoomSource.isFrozen(windowOnScreen: false, lastFrameAge: 84, captureRunning: false), "nothing is being captured")
    }

    func testShareEndedNeedsMemoryNoShareAndAMeeting() {
        XCTAssertTrue(ZoomSource.shareEnded(wasSharing: true, sharingOurs: false, inMeeting: true), "after a relaunch: say it")
        XCTAssertFalse(ZoomSource.shareEnded(wasSharing: true, sharingOurs: true, inMeeting: true), "sharing again")
        XCTAssertFalse(ZoomSource.shareEnded(wasSharing: true, sharingOurs: false, inMeeting: false), "the meeting ended: stale memory")
        XCTAssertFalse(ZoomSource.shareEnded(wasSharing: false, sharingOurs: false, inMeeting: true), "never shared: nothing ended")
    }
}
