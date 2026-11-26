//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ZoomSDK

// The SDK's event delegates. The action-controller protocol declares 51 methods and no @optional, so
// every one must exist; the ones the sidecar acts on have bodies, the rest are deliberate no-ops and
// say so. The SDK calls on its own threads; everything that touches engine state hops to the main actor.

extension SDKZoomEngine {
    nonisolated fileprivate func main(_ body: @escaping @MainActor () -> Void) { Task { @MainActor in body() } }
    nonisolated fileprivate func ids(_ any: [Any]?) -> [UInt32] { (any as? [NSNumber])?.map { $0.uint32Value } ?? [] }
}

// MARK: - Roster, host, layout, hands, quality

extension SDKZoomEngine: ZoomSDKMeetingActionControllerDelegate {
    nonisolated func onUserJoin(_ p0: [Any]) { main { self.refreshRoster(); ShowLog.log("joined: \(self.ids(p0))") } }
    nonisolated func onUserLeft(_ p0: [Any]) {
        let gone = ids(p0)
        main {
            for id in gone { self.raisedHands.remove(id); self.talking.remove(id); self.userQuality[id] = nil }
            self.refreshRoster(); ShowLog.log("left: \(gone)")
        }
    }
    nonisolated func onUserAudioStatusChange(_ p0: [Any]) { main { self.refreshRoster() } }
    nonisolated func onVideoStatusChange(_ p0: ZoomSDKVideoStatus, userID: UInt32) { main { self.refreshRoster() } }
    nonisolated func onUserNamesChanged(_ p0: [NSNumber]) { main { self.refreshRoster() } }
    nonisolated func on(inMeetingUserAvatarPathUpdated: UInt32) {}
    nonisolated func onUserInfoUpdate(_ p0: UInt32) {}   // deprecated by Zoom; the specific events above cover it

    nonisolated func onHostChange(_ p0: UInt32) {
        main {
            self.refreshRoster()
            ShowLog.log(self.amHost ? "ARC Zoom is the HOST" : "host is now \(p0)" + (self.coHostNeeded ? "; ARC Zoom needs co-host" : ""))
        }
    }
    nonisolated func onMeetingCoHostChanged(_ p0: UInt32, isCoHost: Bool) {
        main {
            self.refreshRoster()
            if p0 == self.myID { ShowLog.log(isCoHost ? "ARC Zoom is CO-HOST" : "ARC Zoom lost co-host") }
        }
    }
    nonisolated func onInvalidReclaimHostKey() { main { self.note("host key rejected") } }
    nonisolated func onGrantCoOwnerPrivilegeChanged(_ p0: Bool) {}

    nonisolated func onActiveSpeakerVideoUserChanged(_ p0: UInt32) { main { self.activeSpeakerID = p0 == 0 ? nil : p0 } }
    nonisolated func onActiveVideoUserChanged(_ p0: UInt32) {}
    nonisolated func onUserActiveAudioChange(_ p0: [Any]) { let t = ids(p0); main { self.talking = Set(t); let now = Date(); for id in t { self.lastSpoke[id] = now } } }
    /// The payload is the new list; re-reading getSpotlightedUserList here caught it mid-change and
    /// published a blank. The payload is accepted as authoritative, then the roster is refreshed.
    nonisolated func onSpotlightVideoUserChange(_ p0: [Any]?) {
        let list = ids(p0 ?? [])
        main {
            self.spotlightAccepted = list
            self.spotlightRemovalSeen = []
            for id in list { self.spotlightPending[id] = nil }
            ShowLog.log("spotlight list from the SDK: \(list)")
            self.refreshRoster()
        }
    }
    nonisolated func onHostVideoOrderUpdated(_ p0: [Any]) { let o = ids(p0); main { ShowLog.log("host video order: \(o)") } }
    nonisolated func onLocalVideoOrderUpdated(_ p0: [Any]) {}
    nonisolated func onFollowHostVideoOrderChanged(_ p0: Bool) { main { ShowLog.log("follow host video order: \(p0)") } }
    nonisolated func onFocusModeStateChanged(_ p0: Bool) { main { ShowLog.log("focus mode: \(p0 ? "ON" : "OFF")") } }
    nonisolated func onFocusModeShareTypeChanged(_ p0: ZoomSDKFocusModeShareType) {}

    nonisolated func onLowOrRaiseHandStatusChange(_ p0: Bool, userID: UInt32) {
        main {
            if p0 { self.raisedHands.insert(userID); if self.handRaisedAt[userID] == nil { self.handRaisedAt[userID] = Date() } }
            else { self.raisedHands.remove(userID); self.handRaisedAt[userID] = nil }
        }
    }
    nonisolated func onAllHandsLowered() { main { self.raisedHands = [] } }

    nonisolated func onUserVideoQualityChanged(_ p0: ZoomSDKVideoQuality, userID: UInt32) {
        let word: String
        switch p0 {
        case ZoomSDKVideoQuality_Bad: word = "Bad"
        case ZoomSDKVideoQuality_Normal: word = "Normal"
        case ZoomSDKVideoQuality_Good: word = "Good"
        default: word = "Unknown"
        }
        main { self.userQuality[userID, default: [:]]["video.quality"] = word }
    }

    nonisolated func onMeetingLockStatus(_ p0: Bool) { main { self.meetingLocked = p0; ShowLog.log("meeting \(p0 ? "LOCKED" : "unlocked")") } }
    nonisolated func onMeetingTopicChanged(_ p0: String) { main { self.meetingTopic = p0 } }
    nonisolated func onMute(onEntryStatusChange: Bool) { main { ShowLog.log("mute on entry: \(onEntryStatusChange)") } }
    nonisolated func onSuspendParticipantsActivities() { main { self.note("participant activities SUSPENDED by a host") } }

    // The host asking US to do something: report it, never act on it silently.
    nonisolated func onHostAskUnmute() { main { self.note("the host asks ARC Zoom to unmute") } }
    nonisolated func onHostAskStartVideo() { main { self.note("the host asks ARC Zoom to start video") } }

    // Policy notifications: the SETTINGS module reads the live values, so these only log.
    nonisolated func onAllowParticipantsRenameNotification(_ p0: Bool) {}
    nonisolated func onAllowParticipantsUnmuteSelfNotification(_ p0: Bool) {}
    nonisolated func onAllowParticipantsStartVideoNotification(_ p0: Bool) {}
    nonisolated func onAllowParticipantsShareWhiteBoardNotification(_ p0: Bool) {}
    nonisolated func onAllowParticipantsRequestCloudRecording(_ p0: Bool) {}
    nonisolated func onRequestLocalRecordingPrivilegeChanged(_ p0: ZoomSDKLocalRecordingRequestPrivilegeStatus) {}
    nonisolated func onParticipantProfilePictureStatusChange(_ p0: Bool) {}

    // Join follow-ups: answer with what join() was given, never with a dialog.
    nonisolated func onJoinMeetingResponse(_ p0: ZoomSDKJoinMeetingHelper?) {
        guard let h = p0 else { return }
        let kind = h.getReqInfoType()
        Task { @MainActor in
            switch kind {
            case JoinMeetingReqInfoType_Password:
                if let pw = self.joinPasscode { _ = h.inputPassword(pw); self.note("meeting asked for the passcode: sent") }
                else { _ = h.cancel(); self.lastError = "the meeting wants a passcode and none was given"; self.note("passcode wanted, none held: cancelled") }
            case JoinMeetingReqInfoType_Password_Wrong:
                _ = h.cancel(); self.lastError = "wrong passcode"; self.note("passcode rejected: cancelled")
            case JoinMeetingReqInfoType_ScreenName:
                _ = h.inputMeetingScreenName(self.joinDisplayName); self.note("meeting asked for a screen name: sent \(self.joinDisplayName)")
            default:
                self.note("join asked for info type \(kind.rawValue); not handled")
            }
        }
    }
    nonisolated func onMulti(toSingleShareNeedConfirm: ZoomSDKMultiToSingleShareConfirmHandler?) {
        _ = toSingleShareNeedConfirm?.confirmSwitch()
        main { self.note("multi-share to single share: confirmed") }
    }

    // Chat, camera control, companions, name tags, AI: not in Phase A.
    nonisolated func onChatStatusChangedNotification(_ p0: ZoomSDKChatStatus) {}
    nonisolated func onChatMsgDeleteNotification(_ p0: String, messageDeleteType: ZoomSDKChatMessageDeleteType) {}
    nonisolated func onShareMeetingChatStatusChanged(_ p0: Bool) {}
    nonisolated func onMeetingQAStatusChanged(_ p0: Bool) {}
    nonisolated func onCameraControlRequestReceived(_ p0: UInt32, requestType: ZoomSDKCameraControlRequestType, actionApprove: (() -> ZoomSDKError)?, actionDecline: (() -> ZoomSDKError)?) {
        // Nobody drives the room's camera from the far end without the operator: decline, and say so.
        _ = actionDecline?()
        main { self.note("participant \(p0) asked to control our camera: declined") }
    }
    nonisolated func onCameraControlRequestResult(_ p0: UInt32, resultType: ZoomSDKCameraControlRequestResult) {}
    nonisolated func onCreateCompanionRelation(_ p0: UInt32, childUserID: UInt32) {}
    nonisolated func onRemoveCompanionRelation(_ p0: UInt32) {}
    nonisolated func onBotAuthorizerRelationChanged(_ p0: UInt32) {}
    nonisolated func onVirtualNameTagStatusChanged(_ p0: Bool, userID: UInt32) {}
    nonisolated func onVirtualNameTagRosterInfoUpdated(_ p0: UInt32) {}
    nonisolated func onVideoAlphaChannelStatusChanged(_ p0: Bool) {}
    nonisolated func onAICompanionActiveChangeNotice(_ p0: Bool) { main { ShowLog.log("AI Companion \(p0 ? "ACTIVE" : "off")") } }
    nonisolated func notify(toJoin3rdPartyTelephonyAudio: String) {}
}

// MARK: - Reminders: the blocking disclaimers that hold audio and video until someone clicks

extension SDKZoomEngine: ZoomSDKReminderControllerDelegate {
    nonisolated func onReminderNotify(_ handle: ZoomSDKReminderHandler, reminderContent content: ZoomSDKReminderContent) {
        let title = content.title ?? "(untitled)", blocking = content.isBlocking, type = content.type.rawValue
        let e = handle.accept()
        main { self.note("reminder \(type) \"\(title)\"\(blocking ? " BLOCKING" : ""): accepted (\(Self.name(for: e)))") }
    }
    nonisolated func onEnableReminderNotify(_ handle: ZoomSDKMeetingEnableReminderHandler, reminderContent content: ZoomSDKReminderContent) {
        // "Would you like to enable X": no. Features get enabled by the operator, not by a prompt.
        let title = content.title ?? "(untitled)"
        let e = handle.ignore()
        main { self.note("enable-feature reminder \"\(title)\": ignored (\(Self.name(for: e)))") }
    }
}

// MARK: - Network: proxy and certificate prompts

extension SDKZoomEngine: ZoomSDKNetworkServiceDelegate {
    nonisolated func onProxySettingNotification(_ p0: ZoomSDKProxySettingHelper?) {
        // No proxy credentials are held anywhere; a venue that needs them is configured by hand.
        let host = p0?.getProxyHost() ?? "?", port = p0?.getProxyPort() ?? 0
        p0?.cancel()
        main {
            self.lastError = "the network wants proxy credentials (\(host):\(port)); none are configured"
            self.note("proxy auth wanted at \(host):\(port): cancelled")
        }
    }
    nonisolated func onSSLCertVerifyNotification(_ p0: ZoomSDKSSLVerificationHelper?) {
        let to = p0?.getCertIssueTo() ?? "?", by = p0?.getCertIssueBy() ?? "?", fp = p0?.getCertFingerprint() ?? "?"
        Task { @MainActor in
            if self.trustVenueCertificates {
                p0?.trust()
                self.note("certificate \(to) by \(by) [\(fp)]: TRUSTED (venue certificates allowed)")
            } else {
                p0?.cancel()
                self.lastError = "the venue network presents an untrusted certificate (\(by)); POST /trust?on=1 to accept venue certificates"
                self.note("certificate \(to) by \(by) [\(fp)]: refused")
            }
        }
    }
}

// MARK: - Waiting room

extension SDKZoomEngine: ZoomSDKWaitingRoomDelegate {
    nonisolated func onUserJoinWaitingRoom(_ p0: UInt32) { main { self.refreshWaiting(); ShowLog.log("waiting room: \(p0) arrived") } }
    nonisolated func onUserLeftWaitingRoom(_ p0: UInt32) { main { self.refreshWaiting() } }
    nonisolated func onWaitingRoomUserNameChanged(_ p0: UInt32, userName: String) {}
    nonisolated func onWaitingRoomEntranceEnabled(_ p0: Bool) { main { ShowLog.log("waiting room on entry: \(p0)") } }
    nonisolated func onWaitingRoomPresetAudioStatusChanged(_ p0: Bool) {}
    nonisolated func onWaitingRoomPresetVideoStatusChanged(_ p0: Bool) {}
    nonisolated func onCustomWaitingRoomDataUpdated(_ p0: ZoomSDKCustomWaitingRoomData?, handle: ZoomSDKWaitingRoomDataDownloadHandler?) {}
}

extension SDKZoomEngine {
    func refreshWaiting() { waitingRoomIDs = waitingRoom().map(\.id) }
}


// MARK: - Screen share: who is sharing, and which source id the renderer wants

extension SDKZoomEngine: ZoomSDKASControllerDelegate {
    /// The content type is UNKNOWN at begin and settles on onShareContentChanged (header note), but the
    /// SOURCE ID is right from the first event, which is all the renderer needs.
    @objc(onSharingStatusChanged:)
    nonisolated func onSharingStatusChanged(_ info: ZoomSDKSharingSourceInfo) {
        let status = info.status, uid = info.userID, sid = info.shareSourceID
        Task { @MainActor in
            switch status {
            case ZoomSDKShareStatus_OtherBegin, ZoomSDKShareStatus_ViewOther, ZoomSDKShareStatus_Resume:
                if uid != self.myID { self.activeShare = (sid, uid); ShowLog.log("share: \(self.participants.first { $0.id == uid }?.displayName ?? "\(uid)") started (source \(sid))") }
            case ZoomSDKShareStatus_OtherEnd, ZoomSDKShareStatus_None, ZoomSDKShareStatus_Disconnected:
                if uid != self.myID || status == ZoomSDKShareStatus_None { ShowLog.log("share ended"); self.refreshShare() }
            case ZoomSDKShareStatus_SelfBegin, ZoomSDKShareStatus_SelfEnd:
                self.isSharing = status == ZoomSDKShareStatus_SelfBegin
            default: break
            }
        }
    }

    @objc(onShareContentChanged:)
    nonisolated func onShareContentChanged(_ info: ZoomSDKSharingSourceInfo) {
        let uid = info.userID, sid = info.shareSourceID, type = info.contentType.rawValue
        Task { @MainActor in
            if uid != self.myID { self.activeShare = (sid, uid); ShowLog.log("share content type \(type) from \(uid), source \(sid)") }
        }
    }

    @objc(onFailedToStartShare)
    nonisolated func onFailedToStartShare() { Task { @MainActor in self.lastError = "the share failed to start" } }

    @objc(onSharedVideoEnded)
    nonisolated func onSharedVideoEnded() {}
}


// MARK: - Chat

extension SDKZoomEngine: ZoomSDKMeetingChatControllerDelegate {
    nonisolated func onChatMessageNotification(_ chatInfo: ZoomSDKChatInfo) {
        Task { @MainActor in self.received(chatInfo) }
    }
    nonisolated func onChatMessageEditNotification(_ chatInfo: ZoomSDKChatInfo) {
        Task { @MainActor in self.received(chatInfo) }
    }
    // File transfer over chat: not a show feature; the events must exist and do nothing.
    nonisolated func onFileReceived(_ p0: ZoomSDKFileReceiver) {}
    nonisolated func onFileSendStart(_ p0: ZoomSDKFileSender) {}
    nonisolated func onFileTransferProgress(_ p0: ZoomSDKFileTransferInfo) {}
}


// MARK: - Captions (optional methods, matched by selector)

extension SDKZoomEngine: ZoomSDKCloseCaptionControllerDelegate {
    @objc(onLiveTranscriptionMsgInfoReceived:)
    nonisolated func onLiveTranscriptionMsgInfoReceived(_ info: ZoomSDKLiveTranscriptionMessageInfo?) {
        guard let info else { return }
        let speaker = info.speakerName ?? "\(info.speakerID)", text = info.messageContent ?? "", id = info.messageID, t = info.timeStamp, type = info.messageType.rawValue
        Task { @MainActor in
            // Operation types: 0 add, 1 update, 2 delete, 3 complete (Zoom's numbering in this SDK).
            let final = type == 3
            self.caption(speaker, text, id: id, final: final, at: t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : Date())
        }
    }
    @objc(onReceiveCCMessageWithString:senderID:)
    nonisolated func onReceiveCCMessage(withString text: String, senderID: UInt32) {
        Task { @MainActor in self.caption(self.participants.first { $0.id == senderID }?.displayName ?? "captioner", text, final: true) }
    }
    @objc(onReceiveCCRealtimeMessage:)
    nonisolated func onReceiveCCRealtimeMessage(_ text: String) {
        Task { @MainActor in self.caption("captioner", text, id: "realtime", final: false) }
    }
    @objc(onLiveTranscriptionStatus:)
    nonisolated func onLiveTranscriptionStatus(_ status: ZoomSDKLiveTranscriptionStaus) {
        let raw = status.rawValue
        Task { @MainActor in self.transcriptionStatus = SDKZoomEngine.transcriptionWord(raw); ShowLog.log("transcription status \(raw)") }
    }
    @objc(onLiveTranscriptionMsgError:transcriptLanguage:)
    nonisolated func onLiveTranscriptionMsgError(_ spoken: ZoomSDKLiveTranscriptionLanguage?, transcriptLanguage: ZoomSDKLiveTranscriptionLanguage?) {
        let a = spoken?.languageName ?? "?", b = transcriptLanguage?.languageName ?? "?"
        Task { @MainActor in ShowLog.error("Zoom SDK: live transcription error (spoken \(a), transcript \(b))") }
    }
    @objc(onCaptionStatusChanged:)
    nonisolated func onCaptionStatusChanged(_ enable: Bool) { Task { @MainActor in ShowLog.log("captions \(enable ? "enabled" : "disabled") by the meeting") } }
    @objc(onRequestLiveTranscriptionStatusChange:)
    nonisolated func onRequestLiveTranscriptionStatusChange(_ enabled: Bool) { Task { @MainActor in ShowLog.log("live transcription requests \(enabled ? "allowed" : "blocked")") } }
    @objc(onManualCaptionStatusChanged:)
    nonisolated func onManualCaptionStatusChanged(_ enabled: Bool) { Task { @MainActor in ShowLog.log("manual captions \(enabled ? "on" : "off")") } }
    @objc(onOriginalLanguageMsgReceived:)
    nonisolated func onOriginalLanguageMsgReceived(_ info: ZoomSDKLiveTranscriptionMessageInfo?) { onLiveTranscriptionMsgInfoReceived(info) }
}

// MARK: - Recording (all required)

extension SDKZoomEngine: ZoomSDKMeetingRecordDelegate {
    nonisolated func onRecord2MP4Done(_ success: Bool, path recordPath: String) {
        Task { @MainActor in
            self.mp4Progress = success ? 100 : -1
            self.recordingStatus = "OFF"
            self.lastRecordingPath = success ? recordPath : nil
            ShowLog.log(success ? "recording ready: \(recordPath)" : "recording conversion FAILED")
        }
    }
    nonisolated func onRecord2MP4Progressing(_ percentage: Int32) { Task { @MainActor in self.mp4Progress = Int(percentage) } }
    nonisolated func onCloudRecordingStatus(_ status: ZoomSDKRecordingStatus) { Task { @MainActor in ShowLog.log("cloud recording status \(status.rawValue)") } }
    nonisolated func onRecordPrivilegeChange(_ canRec: Bool) { Task { @MainActor in ShowLog.log("recording privilege: \(canRec)") } }
    nonisolated func onCustomizedRecordingSourceReceived(_ helper: CustomizedRecordingLayoutHelper) {}
    nonisolated func onLocalRecord(_ status: ZoomSDKRecordingStatus, userID: UInt32) {
        Task { @MainActor in if userID == self.myID, self.recordingKind == "local" { let w = self.recordingWord(status); if w != "OFF" || self.recordingStatus != "CONVERTING" { self.recordingStatus = w } } }
    }
    nonisolated func onLocalRecordingPrivilegeRequest(_ status: ZoomSDKRequestLocalRecordingStatus) {}
    nonisolated func onLocalRecordingPrivilegeRequested(_ handler: ZoomSDKRequestLocalRecordingPrivilegeHandler?) {
        // A participant asks to record locally: the operator decides, so it is noted, not granted.
        Task { @MainActor in self.note("a participant asked to record locally; not granted") }
    }
    nonisolated func onCloudRecordingStorageFull(_ gracePeriodDate: time_t) { Task { @MainActor in self.lastWarning = "CLOUD STORAGE FULL" } }
    nonisolated func onRequestCloudRecordingResponse(_ status: ZoomSDKRequestStartCloudRecordingStatus) {}
    nonisolated func onStartCloudRecordingRequested(_ handler: ZoomSDKRequestStartCloudRecordingHandler?) { Task { @MainActor in self.note("a participant asked for cloud recording; not started") } }
    /// The account has smart recording (AI Companion) ENABLED, so a cloud recording start comes back
    /// through this request: the SDK will not start until the host answers the legal notice one way or
    /// the other. ARC wants the plain recording, so the answer is "without smart recording". Measured
    /// 2026-09-21: startCloudRecording answered WrongUsage and this handler sat empty.
    nonisolated func onEnableAndStartSmartRecordingRequested(_ handler: ZoomSDKRequestEnableAndStartSmartRecordingHandler?) {
        Task { @MainActor in
            guard let handler else { ShowLog.error("smart recording request with no handler"); return }
            let e = handler.startCloudRecordingWithoutEnableSmartRecording()
            ShowLog.log("smart recording request answered: plain cloud recording (\(Self.name(for: e)))")
            if e == ZoomSDKError_Success { self.recordingStatus = "CLOUD REC"; self.recordingKind = "cloud" }
        }
    }
    nonisolated func onSmartRecordingEnableActionCallback(_ handler: ZoomSDKSmartRecordingEnableActionHandler?) {}
}

// MARK: - Reactions

extension SDKZoomEngine: ZoomSDKReactionControllerDelegate {
    nonisolated func onEmojiReactionReceived(_ userid: UInt32, reactionType type: ZoomSDKEmojiReactionType, reactionSkinTone: ZoomSDKEmojiReactionSkinTone) {
        Task { @MainActor in
            let r = Reaction(user: userid, name: self.participants.first { $0.id == userid }?.displayName ?? "\(userid)", type: self.reactionName(type), time: Date())
            self.reactions.append(r); if self.reactions.count > 200 { self.reactions.removeFirst(100) }
        }
    }
    nonisolated func onEmojiReactionReceived(inWebinar type: ZoomSDKEmojiReactionType) {
        Task { @MainActor in self.reactions.append(Reaction(user: 0, name: "attendee", type: self.reactionName(type), time: Date())) }
    }
    nonisolated func onEmojiFeedbackReceived(_ userid: UInt32, emojiFeedbackType type: ZoomSDKEmojiFeedbackType) {}
    nonisolated func onEmojiFeedbackCanceled(_ userid: UInt32) {}
}
