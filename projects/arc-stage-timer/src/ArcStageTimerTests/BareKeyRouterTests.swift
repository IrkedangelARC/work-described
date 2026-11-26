//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ARC_Stage_Timer

/// Bare-key shortcuts never act while a text field is being edited (the ARC Presenter failure: a Left arrow
/// typed in a field moved the live slide). Measured in the running app 2026-09-24: the Left arrow IS caught by
/// the menu while editing; the router gives it to the field.
final class BareKeyRouterTests: XCTestCase {
    func testNotEditingEveryKeyRunsTheShow() {
        for key in [BareKey.space, .left, .right, .escape, .digit("1"), .digit("4")] {
            XCTAssertEqual(BareKeyRouter.route(key, editingText: false), .perform, "\(key)")
        }
    }

    func testEditingTheKeysGoToTheField() {
        XCTAssertEqual(BareKeyRouter.route(.space, editingText: true), .insert(" "))
        XCTAssertEqual(BareKeyRouter.route(.left, editingText: true), .moveLeft)
        XCTAssertEqual(BareKeyRouter.route(.right, editingText: true), .moveRight)
        for d in "1234" { XCTAssertEqual(BareKeyRouter.route(.digit(d), editingText: true), .insert(String(d))) }
    }

    func testEscapeWhileEditingLeavesTheFieldAndNeverStopsTheShow() {
        XCTAssertEqual(BareKeyRouter.route(.escape, editingText: true), .endEditing)
        XCTAssertNotEqual(BareKeyRouter.route(.escape, editingText: true), .perform)
    }

    func testNothingRunsTheShowWhileEditing() {
        for key in [BareKey.space, .left, .right, .escape, .digit("1"), .digit("2"), .digit("3"), .digit("4")] {
            XCTAssertNotEqual(BareKeyRouter.route(key, editingText: true), .perform, "\(key)")
        }
    }
}
