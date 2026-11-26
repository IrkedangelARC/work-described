//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import Foundation
import AppKit
import CoreVideo
import ZoomSDK

// MARK: - Chat
// Chat, polled (getAllChatMessageID), sent to everyone, one person or the waiting room.
// State lives in SDKZoomEngine.swift; this file is behaviour only (PLAN_stability_refactor.md step 11).

extension SDKZoomEngine {
    var chat: ZoomSDKMeetingChatController? { ZoomSDK.shared().getMeetingService()?.getMeetingChatController() }

    /// Send to everyone (nil) or to one participant. Waiting-room messages go by `toWaitingRoom`.
    func sendChat(_ text: String, to receiver: UInt32? = nil, toWaitingRoom: Bool = false) -> Bool {
        guard state == .inMeeting, let chat else { lastError = "not in a meeting"; return false }
        let b = ZoomSDKChatMsgInfoBuilder()
        _ = b.setContent(text)
        if toWaitingRoom { _ = b.setMessageType(ZoomSDKChatMessageType_To_WaitingRoomUsers) }
        else if let r = receiver { _ = b.setReceiver(r); _ = b.setMessageType(ZoomSDKChatMessageType_To_Individual) }
        else { _ = b.setMessageType(ZoomSDKChatMessageType_To_All) }
        let info = b.build()
        let e = chat.sendChatMsg(to: info)
        guard e == ZoomSDKError_Success else { lastError = "chat refused (\(Self.name(for: e)))"; ShowLog.error("chat: \(lastError!)"); return false }
        let who = toWaitingRoom ? "waiting room" : (receiver.flatMap { r in participants.first { $0.id == r }?.displayName } ?? "everyone")
        ShowLog.log("chat to \(who): \(text)")
        // Our own message may not echo back through the delegate; keep it in the log either way.
        chatMessages.append(ChatMessage(id: UUID().uuidString, senderID: myID ?? 0, sender: "ARC Zoom", receiver: who, text: text, time: Date(), toAll: receiver == nil && !toWaitingRoom, mine: true))
        return true
    }

    func markChatRead() { unreadChat = 0 }

    func pollChat() {
        guard let m = ZoomSDK.shared().getMeetingService(), let chat else { return }
        let ids = (m.getMeetingActionController().getAllChatMessageID() ?? [])
        for id in ids where !seenChatIDs.contains(id) {
            seenChatIDs.insert(id)
            if let info = chat.getChatMessage(byId: id) { received(info) }
        }
        if seenChatIDs.count > 2000 { seenChatIDs = Set(ids) }
    }

    func received(_ info: ZoomSDKChatInfo) {
        let mine = info.getSenderUserID() == myID
        let m = ChatMessage(id: info.getMessageID() ?? UUID().uuidString, senderID: info.getSenderUserID(),
                            sender: info.getSenderDisplayName() ?? "\(info.getSenderUserID())",
                            receiver: info.getReceiverDisplayName() ?? (info.getChatMessageType() == ZoomSDKChatMessageType_To_All ? "everyone" : ""),
                            text: info.getMsgContent() ?? "", time: Date(timeIntervalSince1970: TimeInterval(info.getTimeStamp())),
                            toAll: info.getChatMessageType() == ZoomSDKChatMessageType_To_All, mine: mine)
        if chatMessages.contains(where: { $0.id == m.id }) { return }
        if mine, let i = chatMessages.firstIndex(where: { $0.mine && $0.text == m.text && $0.id.count == 36 }) { chatMessages[i] = m; return }
        chatMessages.append(m)
        if chatMessages.count > 500 { chatMessages.removeFirst(chatMessages.count - 500) }
        if !mine { unreadChat += 1; ShowLog.log("chat from \(m.sender)\(m.toAll ? "" : " (private)"): \(m.text)") }
    }

    var chatJSON: String {
        let list = chatMessages.suffix(100).map { m in
            "{\"id\":\"\(jsonEscape(m.id))\",\"from\":\"\(jsonEscape(m.sender))\",\"to\":\"\(jsonEscape(m.receiver))\",\"text\":\"\(jsonEscape(m.text))\",\"time\":\(Int(m.time.timeIntervalSince1970)),\"toAll\":\(m.toAll),\"mine\":\(m.mine)}"
        }.joined(separator: ",")
        return "{\"unread\":\(unreadChat),\"messages\":[\(list)]}"
    }
}
