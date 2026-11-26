//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import Foundation
import AppKit
import ZoomSDK

// The meeting-service and auth delegates. Most SDK delegates are SILENT in this setup (measured 2026-09-20):
// the status machine and auth results do arrive; everything per user is backed by a poll in +Roster/+Health.

// MARK: - Auth delegate

// MARK: - Meeting delegate

extension SDKZoomEngine: ZoomSDKMeetingServiceDelegate {
    nonisolated func onMeetingStatusChange(_ status: ZoomSDKMeetingStatus, meetingError error: ZoomSDKMeetingError, end reason: EndMeetingReason) {
        Task { @MainActor in
            switch status {
            case ZoomSDKMeetingStatus_Connecting: self.set(.joining)
            case ZoomSDKMeetingStatus_InMeeting:
                let reconnected = self.state == .reconnecting
                self.set(.inMeeting)
                self.lastError = nil
                ShowLog.log(reconnected ? "back in the meeting after a reconnect" : "in the meeting")
                self.refreshRoster()
                self.invite = self.meetingInvite
                self.startSampling()
                self.reapplyBlurIfWanted()
                if reconnected { self.recoverAfterReconnect() }
            case ZoomSDKMeetingStatus_Reconnecting: self.set(.reconnecting)
            case ZoomSDKMeetingStatus_Failed:
                self.lastError = "the meeting failed (error \(error.rawValue))"
                ShowLog.error("Zoom SDK: \(self.lastError!)")
                self.teardownMeeting()
                self.onRosterChange?()
                self.set(.failed)
            case ZoomSDKMeetingStatus_Ended, ZoomSDKMeetingStatus_Idle:
                if self.state != .idle { ShowLog.log("meeting over (\(reason.rawValue == 0 ? "ended" : "end reason \(reason.rawValue)"))") }
                self.teardownMeeting()
                self.onRosterChange?()
                self.set(.idle)
            case ZoomSDKMeetingStatus_WaitingForHost:
                self.lastError = "waiting for the host: the ZAK did not make us the host"
                ShowLog.error("Zoom SDK: \(self.lastError!)")
            case ZoomSDKMeetingStatus_InWaitingRoom:
                self.lastError = "put in the waiting room: the ZAK did not make us the host"
                ShowLog.error("Zoom SDK: \(self.lastError!)")
            default:
                ShowLog.log("meeting status \(status.rawValue)")
            }
        }
    }

    // The prompts that stall an unattended join, answered here (PLAN_controls.md 3.4). Optional protocol
    // methods are matched by Objective-C selector, so each carries its selector explicitly.

    @objc(onJoinMeetingNeedUserInfo:)
    nonisolated func onJoinMeetingNeedUserInfo(_ handler: ZoomSDKMeetingInputUserInfoHandler?) {
        Task { @MainActor in
            let name = self.joinDisplayName
            let e = handler?.inputUserInfo(name, email: "user@example.com") ?? ZoomSDKError_Failed
            self.note("meeting asked for a name and email: answered \(name) (\(Self.name(for: e)))")
        }
    }

    @objc(onUserConfirmToStartArchive:)
    nonisolated func onUserConfirm(toStartArchive handler: ZoomSDKMeetingArchiveConfirmHandler?) {
        let e = handler?.join(withArchive: true) ?? ZoomSDKError_Failed
        Task { @MainActor in self.note("meeting archives; joined with archive (\(Self.name(for: e)))") }
    }

    @objc(onUserConfirmRecoverMeeting:)
    nonisolated func onUserConfirmRecoverMeeting(_ handler: ZoomSDKRecoverMeetingHandler?) {
        let e = handler?.recoverMeeting(true) ?? ZoomSDKError_Failed
        Task { @MainActor in self.note("meeting offered recovery; recovering (\(Self.name(for: e)))") }
    }

    @objc(onEndOtherMeetingToJoinMeetingNotification:actionCancel:)
    nonisolated func onEndOtherMeeting(toJoinMeetingNotification actionEndOtherMeeting: @escaping () -> ZoomSDKError, actionCancel: @escaping () -> Void) {
        // Never end a meeting we did not start: it may be the client's live show on the same account.
        actionCancel()
        Task { @MainActor in
            self.lastError = "this account already has a meeting running; end it from the Zoom client first"
            self.note("asked to end another meeting to join: refused")
        }
    }

    @objc(onMeetingFullToWatchLiveStream:)
    nonisolated func onMeetingFull(toWatchLiveStream url: String) {
        Task { @MainActor in
            self.lastError = "the meeting is full; the SDK offered the live stream instead"
            self.note("meeting full; live stream offered at \(url)")
        }
    }

    @objc(onMeetingParameterNotification:)
    nonisolated func onMeetingParameterNotification(_ p: ZoomSDKMeetingParameter?) {
        guard let p else { return }
        let topic = p.meetingTopic ?? "", local = p.isAutoRecordingLocal, cloud = p.isAutoRecordingCloud
        Task { @MainActor in
            self.meetingTopic = topic.isEmpty ? self.meetingTopic : topic
            if local || cloud { self.note("this meeting auto-records: local \(local), cloud \(cloud)") }
        }
    }

    @objc(onMeetingStatisticWarning:)
    nonisolated func onMeeting(_ type: StatisticWarningType) {
        let word: String
        switch type {
        case StatisticWarningType_NetworkBad: word = "NETWORK BAD"
        case StatisticWarningType_SystemBusy: word = "SYSTEM BUSY"
        case StatisticWarningType_CPUHigh: word = "CPU HIGH"
        default: word = ""
        }
        Task { @MainActor in
            self.lastWarning = word.isEmpty ? nil : word
            if !word.isEmpty { ShowLog.error("Zoom warns: \(word)") }
        }
    }

    @objc(onUserNetworkStatusChanged:level:userID:uplink:)
    nonisolated func onUserNetworkStatusChanged(_ component: ConnectionComponent, level: ZoomSDKConnectionQuality, userID: UInt32, uplink: Bool) {
        let comp: String
        switch component {
        case ConnectionComponent_Audio: comp = "audio"
        case ConnectionComponent_Video: comp = "video"
        case ConnectionComponent_Share: comp = "share"
        default: comp = "other"
        }
        let key = "\(comp).\(uplink ? "up" : "down")"
        let value = Self.qualityName(level)
        Task { @MainActor in self.userQuality[userID, default: [:]][key] = value }
    }

    nonisolated static func qualityName(_ q: ZoomSDKConnectionQuality) -> String {
        switch q {
        case ZoomSDKConnectionQuality_VeryBad: return "VeryBad"
        case ZoomSDKConnectionQuality_Bad: return "Bad"
        case ZoomSDKConnectionQuality_NotGood: return "NotGood"
        case ZoomSDKConnectionQuality_Normal: return "Normal"
        case ZoomSDKConnectionQuality_Good: return "Good"
        case ZoomSDKConnectionQuality_Excellent: return "Excellent"
        default: return "Unknown"
        }
    }
}

extension SDKZoomEngine: ZoomSDKAuthDelegate {
    nonisolated func onZoomSDKAuthReturn(_ returnValue: ZoomSDKAuthError) {
        Task { @MainActor in
            let ok = returnValue == ZoomSDKAuthError_Success
            if ok {
                ShowLog.log("Zoom SDK authenticated")
                self.lastError = nil
            } else {
                self.lastError = "the SDK rejected the credentials: \(Self.name(for: returnValue))"
                ShowLog.error("Zoom SDK: \(self.lastError!)")
            }
            if let c = self.authContinuation { self.authContinuation = nil; c.resume(returning: ok) }
        }
    }

    nonisolated func onZoomAuthIdentityExpired() {
        Task { @MainActor in
            self.isAuthenticated = false
            ShowLog.error("Zoom SDK: auth identity expired; re-minting the token")
            let ok = await self.reauthenticate()
            self.lastError = ok ? nil : "the SDK's authentication expired and could not be renewed"
        }
    }
}
