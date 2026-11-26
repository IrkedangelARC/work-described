//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcZoom

/// The browser sign-in wait ends on CANCEL, not only after its 5 minute timeout (2026-09-24: a Chrome tab
/// on the wrong Zoom account left the app waiting with nothing on screen to stop it).
final class OAuthCancelTests: XCTestCase {
    func testCancelEndsTheWait() async throws {
        let server = LocalCallbackServer(port: 18767, expectedState: "s")
        let started = Date()
        let wait = Task { try await server.waitForCode(timeout: 30) }
        try await Task.sleep(for: .milliseconds(300))
        LocalCallbackServer.cancelPending()
        do {
            _ = try await wait.value
            XCTFail("the wait returned a code")
        } catch let e as LocalCallbackServer.CallbackError {
            XCTAssertEqual(e.description, LocalCallbackServer.CallbackError.cancelled.description)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "CANCEL ends it at once, not at the timeout")
    }
}
