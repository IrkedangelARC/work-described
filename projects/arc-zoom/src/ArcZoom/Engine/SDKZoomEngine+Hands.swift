//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import Foundation
import AppKit
import CoreVideo
import ZoomSDK

// MARK: - Hands
// Raised-hand queue (polled via isRaisingHand), reactions.
// State lives in SDKZoomEngine.swift; this file is behaviour only (PLAN_stability_refactor.md step 11).

extension SDKZoomEngine {
    var handQueue: [(id: UInt32, since: Date)] { raisedHands.map { ($0, handRaisedAt[$0] ?? Date()) }.sorted { $0.since < $1.since } }
    func lowerHand(_ id: UInt32) -> Bool { let ok = apply("hand lowered: \(id)", act?.raiseHand(false, userID: id)); if ok { raisedHands.remove(id) }; return ok }

    func reactionName(_ t: ZoomSDKEmojiReactionType) -> String {
        switch t {
        case ZoomSDKEmojiReactionType_Clap: return "👏"
        case ZoomSDKEmojiReactionType_Thumbsup: return "👍"
        case ZoomSDKEmojiReactionType_Heart: return "❤️"
        case ZoomSDKEmojiReactionType_Joy: return "😂"
        case ZoomSDKEmojiReactionType_Openmouth: return "😮"
        case ZoomSDKEmojiReactionType_Tada: return "🎉"
        default: return "?"
        }
    }
    func sendReaction(_ name: String) -> Bool {
        let map: [String: ZoomSDKEmojiReactionType] = ["clap": ZoomSDKEmojiReactionType_Clap, "thumbsup": ZoomSDKEmojiReactionType_Thumbsup, "heart": ZoomSDKEmojiReactionType_Heart, "joy": ZoomSDKEmojiReactionType_Joy, "openmouth": ZoomSDKEmojiReactionType_Openmouth, "tada": ZoomSDKEmojiReactionType_Tada]
        guard let t = map[name.lowercased()] else { lastError = "reaction must be clap|thumbsup|heart|joy|openmouth|tada"; return false }
        return apply("reaction \(name)", ZoomSDK.shared().getMeetingService()?.getReactionController().send(t))
    }
    var handsJSON: String {
        let hands = handQueue.map { h in "{\"id\":\(h.id),\"name\":\"\(jsonEscape(participants.first { p in p.id == h.id }?.displayName ?? "\(h.id)"))\",\"since\":\(Int(h.since.timeIntervalSince1970))}" }.joined(separator: ",")
        let recent = reactions.filter { Date().timeIntervalSince($0.time) < 60 }.map { "{\"name\":\"\(jsonEscape($0.name))\",\"type\":\"\($0.type)\",\"time\":\(Int($0.time.timeIntervalSince1970))}" }.joined(separator: ",")
        return "{\"hands\":[\(hands)],\"reactions\":[\(recent)]}"
    }
}
