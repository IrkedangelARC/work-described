//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcPresenter

/// PLAN_zoom_source step 1: the share window shows the PLAIN program picture.
final class ShareOutputTests: XCTestCase {
    func testShareShowsPowerPointAndForeignWindowsNeverZoom() {
        XCTAssertFalse(ShareOutput.showsExternal(.deck, windowBundleID: nil))
        XCTAssertTrue(ShareOutput.showsExternal(.powerpoint, windowBundleID: nil))
        XCTAssertTrue(ShareOutput.showsExternal(.window, windowBundleID: "com.apple.iWork.Keynote"))
        XCTAssertTrue(ShareOutput.showsExternal(.window, windowBundleID: nil), "an unknown app is not Zoom")
        XCTAssertFalse(ShareOutput.showsExternal(.window, windowBundleID: "us.zoom.xos"), "the remote keeps the slides while Zoom is on program")
    }
}
