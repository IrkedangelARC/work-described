//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import Foundation
import AppKit
import CoreVideo
import ZoomSDK

// MARK: - Roster
// The roster is the truth and it is POLLED: join/leave/video/audio/hand/spotlight events never fire here; clearMeetingState with the meeting.
// State lives in SDKZoomEngine.swift; this file is behaviour only (PLAN_stability_refactor.md step 11).

extension SDKZoomEngine {
    /// Read the share state from the controller. Polled once a second from `sample()` because the share
    /// controller's events did not fire for a phone share on 2026-09-20; the list is the truth either way.
    /// `onUserJoin` / `onUserLeft` do not fire in this setup (the same silence as the share and chat
    /// delegates, 2026-09-20: a device admitted from the waiting room sat in the meeting for 35 s with the
    /// roster still showing the sidecar alone until `POST /refresh`). Compare the SDK's id list each tick and
    /// re-read the roster every tick (video, audio and hand status events are silent too: the iPad's camera
    /// was on for a minute while the roster said off and GALLERY drew one tile); `refreshRoster` only
    /// publishes and logs when something changed, and the per-user maps of anyone gone are dropped here.
    func pollRoster() {
        let before = participants
        refreshRoster()
        let known = Set(before.map(\.id)), now = Set(participants.map(\.id))
        for id in known.subtracting(now) { raisedHands.remove(id); talking.remove(id); userQuality[id] = nil; handRaisedAt[id] = nil }
        let joined = now.subtracting(known).sorted(), left = known.subtracting(now).sorted()
        if !joined.isEmpty { ShowLog.log("joined (polled): \(joined)") }
        if !left.isEmpty { ShowLog.log("left (polled): \(left)") }
    }

    /// Read the meeting's user list into `participants`. Enough for gating item 1: who is here, and
    /// whether the ZAK really made us the host.
    /// Everything keyed by a participant id dies with the meeting. Ids are reused by the next meeting on the
    /// same PMI, so a map that survives the end reports the ended meeting's users as if they were still here
    /// (2026-09-20: `GET /health` listed two ids from an ended meeting beside the new meeting's roster of one).
    func clearMeetingState() {
        participants = []
        myID = nil; hostID = nil; amHost = false; amCoHost = false
        activeSpeakerID = nil
        talking = []; lastSpoke = [:]
        raisedHands = []; handRaisedAt = [:]
        spotlightAccepted = []; spotlightRemovalSeen = []; spotlightPending = [:]
        userQuality = [:]; lastWarning = nil
        waitingRoomIDs = []
        reactions = []
        captions = []; captionHistorySeen = []
        transcriptionStatus = "OFF"; lastCaptionAt = nil; transcriptionOnSince = nil
        chatMessages = []; seenChatIDs = []; unreadChat = 0
        isSharing = false; shareDescription = nil; sharedWindowTitle = nil; lastShareList = []; myShareSources = 0
        recordingStatus = "OFF"; recordingKind = ""; mp4Progress = -1
        meetingLocked = false; meetingTopic = nil; micTestRunning = false
        meetingNumber = nil
        invite = (nil, nil, nil)
    }

    /// The raw list, settled: an ADDITION is believed at once; a REMOVAL only when the raw list has
    /// missed that id on two consecutive readings, because the list reads empty for a moment on every
    /// change and one blank reading is not a removal. Order: the previous order for survivors, new ids
    /// appended in the raw list's order. Pure, so it is tested.
    nonisolated static func settleSpotlights(previous: [UInt32], raw: [UInt32], removalSeen: inout Set<UInt32>) -> [UInt32] {
        var out: [UInt32] = []
        for id in previous {
            if raw.contains(id) { removalSeen.remove(id); out.append(id) }
            else if removalSeen.contains(id) { removalSeen.remove(id) }          // second miss: gone
            else { removalSeen.insert(id); out.append(id) }                       // first miss: keep, watch
        }
        for id in raw where !out.contains(id) { out.append(id); removalSeen.remove(id) }
        return out
    }

    /// The SDK's spotlight list with the operator's still-pending commands laid over it: a pending ON
    /// appends the user, a pending OFF removes them, until the SDK agrees or the hold expires. Pure,
    /// so it is tested; it also prunes the entries the SDK has caught up with.
    nonisolated static func withPendingSpotlights(_ list: [UInt32], pending: inout [UInt32: (on: Bool, until: Date)], now: Date) -> [UInt32] {
        var out = list
        for (id, p) in pending {
            let agrees = p.on == list.contains(id)
            if agrees || now > p.until { pending[id] = nil; continue }
            if p.on { out.append(id) } else { out.removeAll { $0 == id } }
        }
        return out
    }

    func refreshRoster() {
        guard let service = ZoomSDK.shared().getMeetingService() else { return }
        let userCtrl = service.getMeetingActionController()
        let ids = (userCtrl.getParticipantsList() as? [NSNumber]) ?? []
        let rawSpotlights = ((userCtrl.getSpotlightedUserList() as? [NSNumber]) ?? []).map { $0.uint32Value }
        let settled = Self.settleSpotlights(previous: spotlightAccepted, raw: rawSpotlights, removalSeen: &spotlightRemovalSeen)
        let spotlightOrder = Self.withPendingSpotlights(settled, pending: &spotlightPending, now: Date())
        spotlightAccepted = spotlightOrder
        let spotlit = Set(spotlightOrder)
        var found: [Participant] = []
        for n in ids {
            let uid = n.uint32Value
            guard let info = userCtrl.getUserByUserID(uid) else { continue }
            var p = Participant(id: uid, name: info.getUserName() ?? "participant \(uid)")
            p.isMe = info.isMySelf()
            p.isHost = info.isHost()
            p.isCoHost = info.getUserRole() == UserRole_CoHost
            p.videoOn = info.isVideoOn()
            let status = info.getAudioStatus()
            p.audioJoined = status != ZoomSDKAudioStatus_None
            p.audioOn = p.audioJoined && ![ZoomSDKAudioStatus_Muted, ZoomSDKAudioStatus_MutedByHost, ZoomSDKAudioStatus_MutedAllByHost].contains(status)
            p.handRaised = info.isRaisingHand()
            p.isSpotlighted = spotlit.contains(uid)
            p.spotlightRank = spotlightOrder.firstIndex(of: uid)
            if p.handRaised { if handRaisedAt[p.id] == nil { handRaisedAt[p.id] = Date() }; raisedHands.insert(p.id) } else { raisedHands.remove(p.id); handRaisedAt[p.id] = nil }
            found.append(p)
        }
        guard found != participants else { return }   // polled every second: publish only on change
        participants = found
        myID = found.first { $0.isMe }?.id
        amHost = found.contains { $0.isMe && $0.isHost }
        amCoHost = found.contains { $0.isMe && $0.isCoHost }
        hostID = found.first { $0.isHost }?.id
        onRosterChange?()
        if audioJoinPending, myID != nil, state == .inMeeting { joinAudioOnEntry() }
        ShowLog.log("roster: \(found.map { "\($0.name)\($0.isHost ? " (host)" : "")\($0.isMe ? " (me)" : "")\($0.videoOn ? "" : " (cam off)")" }.joined(separator: ", "))")
    }
}
