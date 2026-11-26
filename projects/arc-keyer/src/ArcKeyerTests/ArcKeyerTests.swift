//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcKeyer

final class ArcKeyerTests: XCTestCase {
	func testKeyParamsDefaults() {
		let params = KeyParams()
		XCTAssertEqual(params.threshold, 0.05, accuracy: 0.001)
		XCTAssertEqual(params.softness, 0.02, accuracy: 0.001)
		XCTAssertEqual(params.invert, 0.0, accuracy: 0.001)
	}
}
