//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcPresenter

final class ARCCreditTests: XCTestCase {
    func testTheAboutBoxNamesTheCompanyAndTheMark() {
        XCTAssertTrue(ARCCredit.creditLines.contains("ARC Event Productions"))
        XCTAssertTrue(ARCCredit.creditLines.contains("We don't sell failure\u{2122}"))
        XCTAssertTrue(ARCCredit.creditLines.contains("San Jose, California"))
        XCTAssertTrue(ARCCredit.signature.hasPrefix("ARC Presenter"))
        XCTAssertTrue(ARCCredit.signature.hasSuffix("by ARC Event Productions"))
        XCTAssertTrue(ARCCredit.licenseLines.contains("Apache License 2.0"))
    }
}
