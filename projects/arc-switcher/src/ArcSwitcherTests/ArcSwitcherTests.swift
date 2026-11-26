//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcSwitcher

final class ArcSwitcherTests: XCTestCase {

    func testProfileRegistryReturnsKnownProfiles() {
        let keynote = ProfileRegistry.profile(for: "com.apple.iWork.Keynote")
        XCTAssertEqual(keynote.displayName, "Keynote")
        XCTAssertTrue(keynote.supportedCommands.contains(.nextSlide))
    }

    func testProfileRegistryReturnsFallback() {
        let unknown = ProfileRegistry.profile(for: "com.unknown.app")
        XCTAssertTrue(unknown.supportedCommands.isEmpty)
    }

    func testSourceCodable() throws {
        let source = Source(friendlyName: "Test", bundleIdentifier: "com.test.app")
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(Source.self, from: data)
        XCTAssertEqual(decoded.friendlyName, "Test")
        XCTAssertEqual(decoded.bundleIdentifier, "com.test.app")
        XCTAssertFalse(decoded.isAvailable)
    }
}
