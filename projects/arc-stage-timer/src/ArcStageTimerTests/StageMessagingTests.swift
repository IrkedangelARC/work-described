//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ARC_Stage_Timer

/// MESSAGE / ALERT / FLASH (2026-09-24: "send messages and text alerts as well as flash color to get
/// attention"): the alert channel, HOLD, the attention flash and CLEAR.
@MainActor
final class StageMessagingTests: XCTestCase {
    func testAlertStaysUntilCleared() async throws {
        let d = StageDirector()
        d.sendAlert("  mic 2 is dead  ")
        XCTAssertEqual(d.alert, "MIC 2 IS DEAD", "trimmed and upper-cased, like the band on the stage")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(d.alert, "MIC 2 IS DEAD", "an alert has no timeout")
        d.clearAlert()
        XCTAssertNil(d.alert)
    }

    func testEmptyAlertIsIgnored() {
        let d = StageDirector()
        d.sendAlert("   ")
        XCTAssertNil(d.alert)
        XCTAssertEqual(d.alertSequence, 0)
    }

    func testAlertAndMessageAreSeparateChannels() {
        let d = StageDirector()
        d.sendAlert("FIRE DRILL")
        d.sendMessage("WRAP UP", duration: 5)
        XCTAssertEqual(d.alert, "FIRE DRILL")
        XCTAssertEqual(d.message, "WRAP UP")
        d.clearMessage()
        XCTAssertEqual(d.alert, "FIRE DRILL", "clearing the message leaves the alert up")
    }

    func testHoldKeepsTheMessageAndTimedOneExpires() async throws {
        let d = StageDirector()
        d.sendMessage("HOLD ME", duration: nil)
        XCTAssertTrue(d.messageHeld)
        d.sendMessage("QUICK", duration: 0.1)
        XCTAssertFalse(d.messageHeld, "a timed message replaces the held one")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertNil(d.message, "a timed message goes away by itself")
        d.sendMessage("HELD", duration: nil)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(d.message, "HELD", "HOLD has no timeout")
        d.clearMessage()
        XCTAssertFalse(d.messageHeld)
    }

    func testAttentionFlashAndStop() {
        let d = StageDirector()
        d.flashForAttention(color: .red, pulses: 4)
        XCTAssertTrue(d.isFlashingForAttention)
        d.stopFlash()
        XCTAssertFalse(d.isFlashingForAttention)
        XCTAssertNil(d.flashColor)
        XCTAssertEqual(d.flashOpacity, 0)
    }

    func testClearAllTakesEverythingOff() {
        let d = StageDirector()
        d.sendAlert("ALERT")
        d.sendMessage("MSG", duration: nil)
        d.flashForAttention(color: .yellow)
        d.clearAll()
        XCTAssertNil(d.alert)
        XCTAssertFalse(d.messageHeld)
        XCTAssertFalse(d.isFlashingForAttention)
    }

    func testTheOutputSeesTheAlert() {
        let d = StageDirector()
        let state = StageDisplayState()
        d.sendAlert("stand by")
        state.syncFromLocal(engine: TimerEngine(), director: d)
        XCTAssertEqual(state.alert, "STAND BY")
        d.clearAlert()
        state.syncFromLocal(engine: TimerEngine(), director: d)
        XCTAssertNil(state.alert)
    }

    func testLayoutsNameWhatTheyGive() {
        XCTAssertEqual(RunLayout.allCases.map(\.label), ["RUN", "DECK", "WIDGET"])
        for l in RunLayout.allCases {
            XCTAssertTrue(l.tip.hasPrefix(l.label + ":"), l.tip)
            XCTAssertTrue(l.tip.contains("ALERT") || l.tip.contains("messages"), "every layout reaches the messages: \(l)")
        }
    }
    // MARK: The web stage display's state (the JSON sent over /api/stream every 250 ms)

    func testWebStateCarriesTheAlertAndTheMessage() {
        let d = StageDirector()
        let state = StageDisplayState()
        let engine = TimerEngine()
        state.syncFromLocal(engine: engine, director: d)
        XCTAssertEqual(state.toJSON()["alert"] as? String, "", "no alert: an empty string, never missing")

        d.sendAlert("mic 2 is dead")
        d.sendMessage("WRAP UP", duration: nil)
        state.syncFromLocal(engine: engine, director: d)
        let up = state.toJSON()
        XCTAssertEqual(up["alert"] as? String, "MIC 2 IS DEAD")
        XCTAssertEqual(up["message"] as? String, "WRAP UP", "the message is sent too; the page keeps it under the alert")

        d.clearAlert()
        state.syncFromLocal(engine: engine, director: d)
        XCTAssertEqual(state.toJSON()["alert"] as? String, "", "cleared: the banner goes")
        // It survives the trip through JSON, as the page and the iPad client read it.
        let data = try! JSONSerialization.data(withJSONObject: up)
        let back = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(back["alert"] as? String, "MIC 2 IS DEAD")
    }

    func testTheIPadClientReadsTheAlert() {
        let client = StageDisplayState()
        client.update(from: ["alert": "STAND BY"])
        XCTAssertEqual(client.alert, "STAND BY")
        client.update(from: ["alert": ""])
        XCTAssertNil(client.alert)
    }
}
