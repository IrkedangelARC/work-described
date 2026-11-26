//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct MessageControlView: View {
    @Environment(UserPreferences.self) private var prefs
    @Environment(MessageEngine.self) private var messages

    var body: some View {
        @Bindable var messages = messages

        VStack(spacing: 6) {
            // One row: field, send, Clear (when a message is up), preset editing.
            // Half the old module height so MUSIC fits the rail on a 1152 px
            // display (2026-09-12: "reduce the message box by half").
            HStack(spacing: 6) {
                TextField("Type message...", text: $messages.draftMessage)
                    .font(.system(size: 14, weight: .medium))
                    .textFieldStyle(.roundedBorder)
                    .focusEffectDisabled()   // no system-teal focus ring on an ARC surface (2026-09-12)
                    .onSubmit {
                        messages.sendDraft()
                        NSApp.keyWindow?.makeFirstResponder(nil)   // the keyboard is the clicker again
                    }
                    .help("Type a custom message and press Enter to display on confidence monitor")

                Button {
                    messages.sendDraft()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(ARCTheme.accent)
                }
                .buttonStyle(.plain)
                .disabled(messages.draftMessage.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Send message to confidence monitor")

                if messages.isShowingMessage {
                    chip("CLEAR", accent: true) { messages.clear() }
                        .help("Clear message from confidence monitor (Cmd+Shift+C)")
                }
            }

            // Preset grid, 3 x 2. Edited in the MESSAGE window (the band's expand button); stored in preferences.
            // FOUR columns, not six: six left 69 pt a button, which holds the longest
            // label ("MIC CLOSER") only at 11 pt, so the larger console text shrank
            // that one and squeezed its neighbours: twelve buttons in three sizes.
            // At four every label fits at ONE size (identical construction).
            // Six presets, three by two, beside the text box (2026-09-18).
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(0..<6, id: \.self) { i in
                        let msg = i < prefs.quickMessages.count ? prefs.quickMessages[i] : ""
                        Button {
                            if !msg.isEmpty { messages.send(msg) }
                        } label: {
                            Text(msg.isEmpty ? " " : msg)
                                .font(ARCTheme.mono(12, .heavy))
                                .foregroundStyle(ARCTheme.textPrimary)
                                .lineLimit(1).minimumScaleFactor(0.85)   // a custom message longer than the presets
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(msg.isEmpty ? ARCTheme.moduleBg : ARCTheme.surfaceLight)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .disabled(msg.isEmpty)
                        .help(msg.isEmpty ? "Empty preset (set it in the MESSAGE window)" : "Send \"\(msg)\" to the confidence monitor")
                }
            }
            .id(prefs.quickMessagesVersion)
        }
    }

    private func chip(_ label: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(ARCTheme.mono(11, .bold))
                .foregroundStyle(accent ? .white : ARCTheme.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(accent ? ARCTheme.arcRed : ARCTheme.appGrey)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(accent ? ARCTheme.arcRed : ARCTheme.line, lineWidth: 1))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}
