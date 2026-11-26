//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

@MainActor
@Observable
final class MessageEngine {
    private(set) var currentMessage: String = ""
    private(set) var isShowingMessage: Bool = false
    var draftMessage: String = ""

    /// Twelve presets a technical director actually sends to a stage, in the
    /// order they tend to be needed: time, flow, delivery. Editable in the
    /// operator window and stored in preferences (2026-09-12).
    /// Six, customisable, beside a text box (2026-09-18: "6
    /// customisable statements and a text box"). Was twelve.
    static let defaultQuickMessages = [
        "5 MIN", "2 MIN", "1 MIN",
        "TIME", "WRAP UP", "SPEAK UP",
    ]
    static var quickMessages: [String] { UserPreferences.storedQuickMessages }

    func send(_ message: String) {
        guard !message.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        currentMessage = message.uppercased()
        isShowingMessage = true
        draftMessage = ""
        ShowLog.log("message: \(currentMessage)")
    }

    func sendDraft() {
        send(draftMessage)
    }

    func clear() {
        if isShowingMessage { ShowLog.log("message cleared") }
        currentMessage = ""
        isShowingMessage = false
    }
}
