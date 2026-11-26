//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcZoom

/// Who the room sees, and the promise that the meeting's spotlight and the room's program are two
/// different things that happen to agree most of the time.
@MainActor
final class SidecarTests: XCTestCase {
    private func roster(_ spotlit: UInt32? = nil) -> [Participant] {
        [
            Participant(id: 1, name: "ARC Tech", isHost: true, isMe: true),
            Participant(id: 2, name: "Dr. Jane Smith", isSpotlighted: spotlit == 2, spotlightRank: spotlit == 2 ? 0 : nil),
            Participant(id: 3, name: "Prof. Rivera", isSpotlighted: spotlit == 3, spotlightRank: spotlit == 3 ? 0 : nil),
        ]
    }

    /// Two spotlights: PROGRAM follows the EARLIEST one by the SDK's order, whatever the participant
    /// list's order is. Adding a second spotlight must not move the room's screen (2026-09-21, the
    /// jump the operator saw: the old rule took the first spotlit person in list order).
    func testProgramFollowsTheEarliestSpotlightNotTheListOrder() {
        var two = roster()
        two[1].isSpotlighted = true; two[1].spotlightRank = 1   // Jane, spotlit SECOND, listed first
        two[2].isSpotlighted = true; two[2].spotlightRank = 0   // Rivera, spotlit FIRST
        XCTAssertEqual(Sidecar.resolveProgram(roster: two, mode: .spotlight, current: 3), 3)
        XCTAssertEqual(Sidecar.resolveProgram(roster: two, mode: .spotlight, current: nil), 3)
    }

    /// The fake engine keeps the SDK's multi-spotlight semantics, so the console can be rehearsed:
    /// on adds, off removes ONE, nil clears all.
    func testFakeEngineSpotlightsAddRemoveAndClear() async {
        let fake = FakeZoomEngine()
        _ = await fake.join(meeting: "1", passcode: nil, displayName: "t")
        _ = fake.addParticipant(name: "A"); _ = fake.addParticipant(name: "B")
        let ids = fake.participants.filter { !$0.isMe }.map(\.id)
        guard ids.count >= 2 else { return XCTFail("the fake needs two remotes") }
        _ = await fake.spotlight(ids[0]); _ = await fake.spotlight(ids[1])
        XCTAssertEqual(fake.participants.filter(\.isSpotlighted).count, 2)
        XCTAssertEqual(fake.participants.first { $0.id == ids[0] }?.spotlightRank, 0)
        XCTAssertEqual(fake.participants.first { $0.id == ids[1] }?.spotlightRank, 1)
        _ = await fake.spotlight(ids[0], on: false)
        XCTAssertEqual(fake.participants.filter(\.isSpotlighted).map(\.id), [ids[1]], "off removes ONE, the other stays")
        XCTAssertEqual(fake.participants.first { $0.id == ids[1] }?.spotlightRank, 0, "the survivor moves to the front")
        _ = await fake.spotlight(nil)
        XCTAssertTrue(fake.participants.filter(\.isSpotlighted).isEmpty)
    }

    func testSpotlightModeFollowsTheMeetingAndFallsBackToTheFirstRemote() {
        XCTAssertEqual(Sidecar.resolveProgram(roster: roster(3), mode: .spotlight, current: nil), 3)
        XCTAssertEqual(Sidecar.resolveProgram(roster: roster(2), mode: .spotlight, current: 3), 2,
                       "the meeting moved the spotlight, so the room follows")
        XCTAssertEqual(Sidecar.resolveProgram(roster: roster(), mode: .spotlight, current: nil), 2,
                       "nobody spotlit: the first remote")
    }

    func testManualModeHoldsTheOperatorsChoiceAgainstTheMeeting() {
        XCTAssertEqual(Sidecar.resolveProgram(roster: roster(2), mode: .manual, current: 3), 3,
                       "the meeting spotlit someone else; the room does not move")
        XCTAssertEqual(Sidecar.resolveProgram(roster: roster(2), mode: .manual, current: 99), 2,
                       "the chosen participant left: fall back rather than show nothing")
    }

    func testTheRoomIsNeverShownTheOperator() {
        // Only "me" is present, so PROGRAM has nobody. Showing the operator back to the room is worse
        // than black.
        let justMe = [Participant(id: 1, name: "ARC Tech", isHost: true, isMe: true)]
        XCTAssertNil(Sidecar.resolveProgram(roster: justMe, mode: .spotlight, current: nil))
        XCTAssertNil(Sidecar.resolveProgram(roster: justMe, mode: .manual, current: 1),
                     "even asked for by id, the operator does not go on program")
        XCTAssertNil(Sidecar.resolveProgram(roster: [], mode: .spotlight, current: nil))
    }

    func testAnEmptyMeetingResolvesToNobodyRatherThanCrashing() {
        XCTAssertNil(Sidecar.resolveProgram(roster: [], mode: .manual, current: 7))
    }

    // MARK: - The fake engine, which the whole app is drilled on until the SDK lands

    func testFakeEngineJoinsBuildsARosterAndSpotlights() async {
        let fake = FakeZoomEngine()
        XCTAssertEqual(fake.state, .idle)
        let joined = await fake.join(meeting: "123", passcode: nil, displayName: "ARC Tech")
        XCTAssertTrue(joined)
        XCTAssertEqual(fake.state, .inMeeting)
        XCTAssertEqual(fake.participants.count, 1)
        XCTAssertTrue(fake.participants[0].isMe)

        fake.addParticipant(name: "Panelist")
        XCTAssertEqual(fake.remotes.count, 1)
        let id = fake.remotes[0].id

        let spotlit = await fake.spotlight(id)
        XCTAssertTrue(spotlit)
        XCTAssertEqual(fake.spotlighted?.id, id)
        let cleared = await fake.spotlight(nil)
        XCTAssertTrue(cleared)
        XCTAssertNil(fake.spotlighted, "nil clears it")

        let muted = await fake.mute(id, on: true)
        XCTAssertTrue(muted)
        XCTAssertFalse(fake.participant(id)!.audioOn)

        await fake.leave()
        XCTAssertEqual(fake.state, .idle)
        XCTAssertTrue(fake.participants.isEmpty)
    }

    func testFakeEngineRefusesToShareAWindowThatIsNotThere() async {
        let fake = FakeZoomEngine()
        _ = await fake.join(meeting: "1", passcode: nil, displayName: "ARC Tech")
        let shared = await fake.startShare(windowTitle: "No Such Window At All", withSound: true)
        XCTAssertFalse(shared)
        XCTAssertFalse(fake.isSharing)
        XCTAssertNotNil(fake.lastError, "and says why")
    }

    func testFriendlyNameReplacesTheZoomNameInTheRoom() {
        var p = Participant(id: 2, name: "iPhone (2)")
        XCTAssertEqual(p.displayName, "iPhone (2)")
        p.friendlyName = "Dr. Jane Smith"
        XCTAssertEqual(p.displayName, "Dr. Jane Smith", "the room sees the person, not the device")
    }

    func testPixelBufferIsIOSurfaceBackedSoALayerCanTakeItWithoutACopy() {
        guard let buffer = PixelBufferFactory.make(width: 64, height: 36) else {
            return XCTFail("no pixel buffer")
        }
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer), "no IOSurface means a copy per frame")
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
        var drew = false
        PixelBufferFactory.draw(into: buffer) { ctx, size in
            XCTAssertEqual(size, CGSize(width: 64, height: 36))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            drew = true
        }
        XCTAssertTrue(drew, "the draw closure must run; a silent no-op would ship black frames")
    }

    /// The roster order is host, pinned VIPs, JOIN order, operator: nothing about who is talking moves
    /// a row (2026-09-21: the latest talker used to jump to the top, and the chips moved under the
    /// pointer).
    func testRosterOrderIsJoinOrderNotTalkingOrder() {
        let roster = [
            Participant(id: 3, name: "Late joiner"),
            Participant(id: 1, name: "ARC Zoom", isHost: true, isMe: true),
            Participant(id: 2, name: "Early joiner"),
        ]
        XCTAssertEqual(Sidecar.stableOrder(roster, joinOrder: [1, 2, 3], vips: []), [1, 2, 3])
        XCTAssertEqual(Sidecar.stableOrder(roster, joinOrder: [1, 2, 3], vips: [3]), [1, 3, 2], "a pinned VIP rises, once, by the operator's hand")
        let guest = [Participant(id: 9, name: "Guest host", isHost: true), Participant(id: 1, name: "ARC Zoom", isMe: true), Participant(id: 2, name: "B"), Participant(id: 3, name: "A")]
        XCTAssertEqual(Sidecar.stableOrder(guest, joinOrder: [1, 3, 2], vips: []), [9, 3, 2, 1], "someone else's meeting: their host first, we go last")
    }
}
