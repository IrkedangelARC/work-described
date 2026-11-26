//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import Foundation
import AppKit
import CoreVideo
import ZoomSDK

// MARK: - Meeting
// Start as host with the ZAK, join, end for everyone, teardown (the ONE way meeting state dies), reconnect recovery, spotlight, mute, the waiting room.
// State lives in SDKZoomEngine.swift; this file is behaviour only (PLAN_stability_refactor.md step 11).

extension SDKZoomEngine {
    /// After a local recording the raw gate is gone; re-open it and re-subscribe so the outputs come back.
    /// END for everyone (host only). Leaving keeps a personal meeting alive with whoever stays in it,
    /// and a cloud recording running with it, which then blocks the raw feed on the next start.
    func endForAll() async {
        guard let service = ZoomSDK.shared().getMeetingService() else { return }
        if recordingKind == "cloud" || rec?.getCloudRecordingStatus() == ZoomSDKRecordingStatus_Start { _ = rec?.startCloudRecording(false) }
        service.leaveMeeting(with: LeaveMeetingCmd_End)
        ShowLog.log("meeting ENDED for everyone")
    }

    /// Join `meeting` AS ARC TECH, using the account's ZAK, which makes the sidecar the host. That is
    /// why no on-behalf-of consent is needed: the app and the meeting's host are the same account
    /// (PLAN.md gating item 5, which this is the measurement for).
    func join(meeting: String, passcode: String?, displayName: String) async -> Bool {
        joinPasscode = passcode; joinDisplayName = displayName
        guard await prepare() else { return false }
        guard let number = Int64(meeting.filter(\.isNumber)), number > 0 else {
            lastError = "a meeting number is needed, digits only"
            return false
        }

        guard let access = await freshAccessToken() else { return false }
        var tokens = TokenStore.load()

        let zak: String
        do {
            zak = try await TokenFetcher.fetchZAK(accessToken: access)
            tokens.zak = zak
            TokenStore.save(tokens)
        } catch {
            lastError = "could not fetch the ZAK (is the scope user:read:zak on the app?): \(error)"
            ShowLog.error("Zoom SDK: \(lastError!)")
            return false
        }

        guard let service = ZoomSDK.shared().getMeetingService() else {
            lastError = "the SDK gave no meeting service"
            return false
        }
        service.delegate = self
        service.getASController().delegate = self
        service.getMeetingChatController().delegate = self
        service.getCloseCaptionController().delegate = self
        service.getRecordController().delegate = self
        service.getReactionController().delegate = self

        let elements = ZoomSDKJoinMeetingElements()
        elements.meetingNumber = number
        elements.displayName = displayName.isEmpty ? "ARC Tech" : displayName
        elements.password = passcode
        elements.zak = zak                  // the host bit
        elements.userType = ZoomSDKUserType_ZoomUser   // a signed-in Zoom user, which the ZAK is what proves
        elements.isNoVideo = !sendsOwnVideo
        elements.isNoAudio = false
        elements.isDirectShare = false

        meetingNumber = meeting
        set(.joining)
        let err = service.joinMeeting(elements)
        guard err == ZoomSDKError_Success else {
            lastError = "the SDK refused to join (\(Self.name(for: err)))"
            ShowLog.error("Zoom SDK: \(lastError!)")
            set(.failed)
            return false
        }
        ShowLog.log("joining meeting \(meeting) as \(elements.displayName ?? "?") with the ARC Tech ZAK")
        return true
    }

    /// START a meeting as ARC Tech, rather than joining one. The spike's finding (gating item 6): a ZAK
    /// JOIN does not take host from a client that already holds it, so the sidecar had to be promoted by
    /// hand every restart and sat in the waiting room meanwhile. Starting makes it host from the first
    /// instant, which also gives the raw data gate its permission immediately.
    @discardableResult
    func startMeeting(displayName: String = "ARC Zoom") async -> Bool {
        guard await prepare() else { return false }

        guard let access = await freshAccessToken() else { return false }
        var tokens = TokenStore.load()

        let zak: String
        do {
            zak = try await TokenFetcher.fetchZAK(accessToken: access)
            tokens.zak = zak
            TokenStore.save(tokens)
        } catch {
            lastError = "could not fetch the ZAK: \(error)"
            ShowLog.error("Zoom SDK: \(lastError!)")
            return false
        }

        guard let service = ZoomSDK.shared().getMeetingService() else {
            lastError = "the SDK gave no meeting service"
            return false
        }
        service.delegate = self
        service.getASController().delegate = self
        service.getMeetingChatController().delegate = self
        service.getCloseCaptionController().delegate = self
        service.getRecordController().delegate = self
        service.getReactionController().delegate = self

        let elements = ZoomSDKStartMeetingUseZakElements()
        elements.zak = zak
        elements.displayName = displayName
        // A ZAK IS an API-user credential, which is what the start path calls this.
        elements.userType = SDKUserType_APIUser
        // The PMI, not 0: `startMeetingWithZAK` answered WrongUsage for 0 (2026-09-20). Fetched from
        // /v2/users/me at sign-in and kept with the tokens.
        // The PMI is re-read from the profile at EVERY start, not only when unknown: an operator who
        // changes it in the portal (2026-09-21) would otherwise start the old number for as long
        // as the sign-in lasted. One GET, logged when it differs.
        if let info = try? await TokenFetcher.fetchUserInfo(accessToken: access) {
            if let new = info.pmi, new != tokens.pmi { ShowLog.log("PMI is now \(new)\(tokens.pmi.map { " (was \($0))" } ?? "")") }
            tokens.pmi = info.pmi ?? tokens.pmi
            TokenStore.save(tokens)
        }
        guard let pmi = tokens.pmi, pmi > 0 else {
            lastError = "no personal meeting ID on the house account; cannot start a meeting"
            set(.failed)
            return false
        }
        elements.meetingNumber = pmi

        set(.joining)
        meetingNumber = tokens.pmi.map { String($0) }   // the start path never set it; /roster said null
        let err = service.startMeeting(withZAK: elements)
        guard err == ZoomSDKError_Success else {
            lastError = "the SDK refused to start a meeting (\(Self.name(for: err)))"
            ShowLog.error("Zoom SDK: \(lastError!)")
            set(.failed)
            return false
        }
        ShowLog.log("starting a meeting as \(displayName) with the ARC Tech ZAK")
        return true
    }

    /// The numbers a human needs to join what we started.
    var meetingInvite: (number: String?, passcode: String?, url: String?) {
        guard let service = ZoomSDK.shared().getMeetingService(), state == .inMeeting else { return (nil, nil, nil) }
        return (service.getMeetingProperty(MeetingPropertyCmd_MeetingNumber),
                service.getMeetingProperty(MeetingPropertyCmd_MeetingPassword),
                service.getMeetingProperty(MeetingPropertyCmd_JoinMeetingUrl))
    }

    func leave() async {
        stopRawData()
        if let service = ZoomSDK.shared().getMeetingService() { service.leaveMeeting(with: LeaveMeetingCmd_Leave) }
        teardownMeeting()
        onRosterChange?()
        set(.idle)
    }

    /// The ONE way a meeting's state dies, whoever ended it. Renderers are destroyed, the raw gate is
    /// forgotten (it belonged to the meeting that just ended, so `startRawData` must open it again next
    /// time), sampling stops and every per-meeting fact is cleared. Before this, a meeting ended from a
    /// client or a network drop left `rawDataRunning = true` and live renderers behind, and the next
    /// start in the same process answered every subscription with 0 frames (audit P0).
    func teardownMeeting() {
        for (_, sub) in subscriptions { sub.stop() }
        subscriptions = [:]
        rawDataRunning = false
        stopSampling()
        clearMeetingState()
    }

    /// Back in the meeting after a reconnect: the SDK's raw gate and renderers do not survive it.
    /// Re-open the gate and let the sidecar subscribe again (audit P1, unmeasured until a cable is pulled).
    func recoverAfterReconnect() {
        for (_, sub) in subscriptions { sub.stop() }
        subscriptions = [:]
        rawDataRunning = false
        Task { @MainActor in
            let ok = await startRawData()
            ShowLog.log(ok ? "reconnected: raw video re-opened" : "reconnected: raw video did NOT re-open")
            onRosterChange?()
        }
    }

    /// Shut the SDK down BEFORE the process exits. Without this, the SDK's static destructors run from
    /// `exit()` on quit and segfault in zVideoApp through cmmlib's TermModule (measured 2026-09-20: every
    /// quit produced a SIGSEGV crash report). Synchronous on purpose: `applicationWillTerminate` does not
    /// wait for tasks.
    nonisolated func shutdownSynchronously() {
        MainActor.assumeIsolated {
            guard didInit else { return }
            savePrefs()
            if let service = ZoomSDK.shared().getMeetingService(), state == .inMeeting || state == .joining || state == .reconnecting {
                // END when we host (a leave keeps the PMI alive and the cloud recording running: the trap).
                if amHost { _ = rec?.startCloudRecording(false); service.leaveMeeting(with: LeaveMeetingCmd_End); ShowLog.log("meeting ENDED for everyone (quit)") }
                else { service.leaveMeeting(with: LeaveMeetingCmd_Leave) }
            }
            teardownMeeting()
            ZoomSDK.shared().unInitSDK()
            didInit = false
            isAuthenticated = false
            ShowLog.log("Zoom SDK shut down")
        }
    }

    func set(_ s: MeetingState) {
        guard state != s else { return }
        previousState = state
        state = s
        // A meeting that ends under AS VIDEO still gets its camera, mic and preset back (spotlight and own
        // video/audio went with the meeting).
        if s != .inMeeting, videoSendRestore != nil, let p = previewForVideoSend { Task { @MainActor in await self.endPreviewVideo(p) } }
        onStateChange?(s)
    }

    /// Spotlight is MEETING-WIDE: every attendee sees it, not just the room. Host or co-host only
    /// (gating item 3).
    /// `id` nil clears every spotlight. `on: false` un-spotlights THAT ONE (2026-09-21: the chip used to
    /// clear all, so removing one of two dropped both and PROGRAM jumped to whoever the SDK listed first).
    func spotlight(_ id: UInt32?, on: Bool = true) async -> Bool {
        guard let service = ZoomSDK.shared().getMeetingService() else { return false }
        let ctrl = service.getMeetingActionController()
        let err: ZoomSDKError
        if let id { err = on ? ctrl.spotlightVideo(id) : ctrl.unSpotlightVideo(id) } else { err = ctrl.unSpotlightAllVideos() }
        guard err == ZoomSDKError_Success else {
            lastError = "spotlight refused (\(Self.name(for: err))): Zoom spotlights only a participant with video on, and not in a meeting of two"
            ShowLog.error("Zoom SDK: \(lastError!)")
            return false
        }
        // The SDK's list lags the command by about a second; hold what was asked for that long, then
        // the list is the truth again.
        if let id { spotlightPending[id] = (on, Date().addingTimeInterval(2)) }
        else { for p in participants where p.isSpotlighted { spotlightPending[p.id] = (false, Date().addingTimeInterval(2)) } }
        refreshRoster()
        ShowLog.log(id.map { "spotlight \($0) \(on ? "on" : "off")" } ?? "spotlight cleared")
        return true
    }

    /// Who is waiting to be let in.
    func waitingRoom() -> [Participant] {
        guard let service = ZoomSDK.shared().getMeetingService() else { return [] }
        let room = service.getWaitingRoomController()
        let ids = (room.getWaitRoomUserList() as? [NSNumber]) ?? []
        return ids.compactMap { n in
            let uid = n.uint32Value
            guard let info = room.getWaitingRoomUserInfo(uid) else { return nil }
            return Participant(id: uid, name: info.getUserName() ?? "waiting \(uid)")
        }
    }

    /// Admit one, or everyone when `id` is nil. Host only, which the sidecar now is.
    @discardableResult
    func admit(_ id: UInt32?) async -> Bool {
        guard let service = ZoomSDK.shared().getMeetingService() else { return false }
        let room = service.getWaitingRoomController()
        let err = id.map { room.admit(toMeeting: $0) } ?? room.admitAllToMeeting()
        guard err == ZoomSDKError_Success else {
            lastError = "admit refused (\(Self.name(for: err))); the sidecar must be the host"
            ShowLog.error("Zoom SDK: \(lastError!)")
            return false
        }
        ShowLog.log("admitted \(id.map(String.init) ?? "everyone") from the waiting room")
        refreshRoster()
        return true
    }

    /// Mute or unmute one participant's microphone. It IS on `ZoomSDKMeetingActionController`, just not
    /// as a named method: `actionMeetingWithCmd:userID:onScreen:` with `ActionMeetingCmd_MuteAudio` /
    /// `_UnMuteAudio` (ZoomSDKErrors.h). Host or co-host only. The room's audio comes off the console
    /// anyway (PLAN.md decision 2), so this is a convenience for the call, not the room.
    func mute(_ id: UInt32, on: Bool) async -> Bool {
        let ok = action(on ? ActionMeetingCmd_MuteAudio : ActionMeetingCmd_UnMuteAudio, user: id,
                        what: on ? "mute" : "unmute")
        if ok { refreshRoster() }
        return ok
    }

    /// The meeting facts the operator surface needs beyond the roster: who holds host, whether we still
    /// need promoting, lock, topic, who is talking, hands, per-user quality, warnings, waiting room,
    /// and what the unattended handlers did.
    var meetingJSON: String {
        func arr(_ xs: [UInt32]) -> String { "[" + xs.map(String.init).joined(separator: ",") + "]" }
        func str(_ x: String?) -> String { x.map { "\"\(jsonEscape($0))\"" } ?? "null" }
        let quality = userQuality.map { (uid, comps) in
            "\"\(uid)\":{" + comps.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",") + "}"
        }.joined(separator: ",")
        let applied = unattended.applied.map { "\"\(jsonEscape($0))\"" }.joined(separator: ",")
        let refused = unattended.refused.map { "\"\(jsonEscape($0))\"" }.joined(separator: ",")
        let promptList = prompts.map { "\"\(jsonEscape($0))\"" }.joined(separator: ",")
        return "{\"state\":\"\(state.rawValue)\",\"me\":\(myID.map(String.init) ?? "null"),\"host\":\(hostID.map(String.init) ?? "null"),"
            + "\"amHost\":\(amHost),\"amCoHost\":\(amCoHost),\"coHostNeeded\":\(coHostNeeded),"
            + "\"locked\":\(meetingLocked),\"topic\":\(str(meetingTopic)),"
            + "\"activeSpeaker\":\(activeSpeakerID.map(String.init) ?? "null"),\"talking\":\(arr(Array(talking).sorted())),"
            + "\"hands\":\(arr(Array(raisedHands).sorted())),\"quality\":{\(quality)},\"warning\":\(str(lastWarning)),"
            + "\"waiting\":\(arr(waitingRoomIDs)),\"trustVenueCertificates\":\(trustVenueCertificates),"
            + "\"unattended\":{\"applied\":[\(applied)],\"refused\":[\(refused)]},\"prompts\":[\(promptList)]}"
    }

    /// Make or unmake a co-host (needs the portal's co_host ON, flipped 2026-09-21). Read back from the
    /// roster, never assumed.
    func setCoHost(_ id: UInt32, on: Bool) -> Bool { on ? assignCoHost(id) : revokeCoHost(id) }

    func action(_ cmd: ActionMeetingCmd, user: UInt32, what: String) -> Bool {
        guard state == .inMeeting, let service = ZoomSDK.shared().getMeetingService() else {
            lastError = "not in a meeting"
            return false
        }
        let err = service.getMeetingActionController().actionMeeting(with: cmd, userID: user, on: ScreenType_First)
        guard err == ZoomSDKError_Success else {
            lastError = "\(what) for \(user) refused (\(Self.name(for: err)))"
            ShowLog.error("Zoom SDK: \(lastError!)")
            return false
        }
        ShowLog.log("\(what): \(user)")
        return true
    }
}
