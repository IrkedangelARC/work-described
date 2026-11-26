//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcCaptureTests

/// A short movie that has played out and holds its last frame is not a stall (ARC TEST, 2026-09-30).
final class ShortMovieStallTests: XCTestCase {
    func testShortMovieThatHasPlayedOutIsNotAStall() {
        XCTAssertTrue(CaptureSession.movieHasRunItsLength(6, elapsed: 9.5))
    }
    func testLongMovieStillOnItsPosterIsAStall() {
        XCTAssertFalse(CaptureSession.movieHasRunItsLength(60, elapsed: 9.5))
    }
    func testUnknownLengthIsAStall() {
        XCTAssertFalse(CaptureSession.movieHasRunItsLength(nil, elapsed: 9.5))
        XCTAssertFalse(CaptureSession.movieHasRunItsLength(0, elapsed: 9.5))
    }
}
