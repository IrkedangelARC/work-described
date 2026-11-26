//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// The MESSAGE TO PRESENTER module's expanded controls, in a floating window
/// (2026-09-19: "that button and all like it should open an expanded
/// floating control window"). COMPOSE: what is on the monitor now, a field,
/// SEND and CLEAR. PRESETS: the six rail buttons, edited in place and saved
/// as typed, each with its own SEND, and RESET to the stock six.
struct MessageWindowView: View {
    @Environment(MessageEngine.self) private var messages
    @Environment(UserPreferences.self) private var prefs
    @FocusState private var composeFocused: Bool

    var body: some View {
        @Bindable var messages = messages
        let _ = prefs.quickMessagesVersion
        VStack(spacing: ARCTheme.paddingSmall) {
            // COMPOSE
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("ON THE MONITOR").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.text1).frame(width: 130, alignment: .leading)
                    Text(messages.isShowingMessage ? messages.currentMessage : "nothing")
                        .font(ARCTheme.mono(15, .heavy))
                        .foregroundStyle(messages.isShowingMessage ? .white : ARCTheme.text2)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 4).fill(messages.isShowingMessage ? ARCTheme.arcRed : ARCTheme.panel))
                    chip("CLEAR", accent: messages.isShowingMessage) { messages.clear() }
                        .disabled(!messages.isShowingMessage)
                        .help("Take the message off the monitor (Cmd+Shift+C)")
                }
                HStack(spacing: 8) {
                    Text("COMPOSE").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.text1).frame(width: 130, alignment: .leading)
                    TextField("Type a message, Return sends it", text: $messages.draftMessage)
                        .font(.system(size: 15, weight: .medium))
                        .textFieldStyle(.roundedBorder)
                        .focusEffectDisabled()
                        .focused($composeFocused)
                        .onSubmit { messages.sendDraft() }
                    chip("SEND", accent: true) { messages.sendDraft() }
                        .disabled(messages.draftMessage.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(ARCTheme.modulePad)
            .arcModule(title: "Compose", tint: ARCTheme.secOrange)

            // PRESETS
            VStack(spacing: 6) {
                ForEach(0..<6, id: \.self) { i in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.text2).frame(width: 18, alignment: .trailing)
                        TextField("empty preset", text: Binding(
                            get: { i < prefs.quickMessages.count ? prefs.quickMessages[i] : "" },
                            set: { v in var all = prefs.quickMessages; if i < all.count { all[i] = v.uppercased(); prefs.quickMessages = all } }
                        ))
                        .font(ARCTheme.mono(13, .bold))
                        .textFieldStyle(.roundedBorder)
                        .focusEffectDisabled()
                        let msg = i < prefs.quickMessages.count ? prefs.quickMessages[i] : ""
                        chip("SEND", accent: false) { messages.send(msg) }
                            .disabled(msg.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                HStack {
                    Text("Saved as typed. The rail shows these six, three by two.").font(ARCTheme.caption).foregroundStyle(ARCTheme.text2)
                    Spacer(minLength: 0)
                    chip("RESET", accent: false) { prefs.resetQuickMessages() }
                        .help("Back to the stock six: 5 MIN, 2 MIN, 1 MIN, TIME, WRAP UP, SPEAK UP")
                }
            }
            .padding(ARCTheme.modulePad)
            .arcModule(title: "Presets", tint: ARCTheme.line)
        }
        .padding(ARCTheme.paddingMedium)
        .frame(minWidth: 520)
        .background(ARCTheme.background)
        .onAppear { composeFocused = true }
    }

    private func chip(_ label: String, accent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(ARCTheme.mono(12, .heavy))
                .foregroundStyle(accent ? .white : ARCTheme.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(accent ? ARCTheme.arcRed : ARCTheme.appGrey)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(accent ? ARCTheme.arcRed : ARCTheme.line, lineWidth: 1))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}
