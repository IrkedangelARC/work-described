//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ARC_Stage_Timer

/// The CONFIDENCE MONITOR layout travels to remote displays, is remembered, and defaults to ARC.
final class StageLayoutTests: XCTestCase {

    private var savedLayout: Any?
    private var savedTheme: Any?

    override func setUp() {
        super.setUp()
        savedLayout = UserDefaults.standard.object(forKey: StageLayout.defaultsKey)
        savedTheme = UserDefaults.standard.object(forKey: "stageColorScheme")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedLayout, forKey: StageLayout.defaultsKey)
        UserDefaults.standard.set(savedTheme, forKey: "stageColorScheme")
        super.tearDown()
    }

    func testDefaultIsArc() {
        UserDefaults.standard.removeObject(forKey: StageLayout.defaultsKey)
        XCTAssertEqual(StageLayout.saved, .arc)
        XCTAssertEqual(StageDisplayState().stageLayout, .arc)
    }

    func testLayoutAndThemeAreRemembered() {
        let a = StageDisplayState()
        a.stageLayout = .split
        a.colorScheme = .paper
        let b = StageDisplayState()
        XCTAssertEqual(b.stageLayout, .split)
        XCTAssertEqual(b.colorScheme, .paper)
    }

    func testLayoutTravelsInTheStream() {
        let controller = StageDisplayState()
        controller.stageLayout = .clockAndTimer
        let json = controller.toJSON()
        XCTAssertEqual(json["stageLayout"] as? String, "clockAndTimer")

        let remote = StageDisplayState()
        remote.stageLayout = .classic
        remote.update(from: json)
        XCTAssertEqual(remote.stageLayout, .clockAndTimer)
    }

    func testUnknownLayoutIsIgnored() {
        let remote = StageDisplayState()
        remote.stageLayout = .bigNumber
        remote.update(from: ["stageLayout": "hologram"])
        XCTAssertEqual(remote.stageLayout, .bigNumber)
    }

    func testEveryLayoutHasAName() {
        for layout in StageLayout.allCases {
            XCTAssertFalse(layout.displayName.isEmpty)
            XCTAssertFalse(layout.description.isEmpty)
        }
    }
}
