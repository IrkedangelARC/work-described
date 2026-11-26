//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Preset and custom message controls for the stage display.
struct MessageControlPanel: View {
    @Environment(StageDirector.self) private var director
    @State private var customText = ""
    @State private var messageDuration: Double = 5

    private let presets: [[String]] = [
        ["WRAP UP", "STOP", "HOLD", "THANK YOU"],
        ["SPEED UP", "SLOW DOWN", "Q&A", "BREAK"]
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Preset grid
            ForEach(presets, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { label in
                        Button {
                            director.sendMessage(label, duration: messageDuration)
                        } label: {
                            Text(label)
                                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                                .foregroundStyle(ARCTheme.text0)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)      // "THANK YOU" was clipping to "THANK"
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(ARCTheme.surfaceLight)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help(messageHelp(for: label))
                    }
                }
            }

            // Duration control
            HStack(spacing: 8) {
                Text("HOLD")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(ARCTheme.textTertiary)
                Slider(value: $messageDuration, in: 2...15, step: 1)
                    .tint(ARCTheme.secOrange)
                    .help("Message Duration: how long the message stays on the confidence monitor (\(Int(messageDuration)) seconds)")
                Text("\(Int(messageDuration))S")
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .foregroundStyle(ARCTheme.text0)
                    .frame(width: 32, alignment: .trailing)
            }

            // Custom message input
            HStack(spacing: 8) {
                // A plain field on the module ground: the rounded-border style brought the system's own
                // focus ring, which is the one blue left in the console.
                TextField("", text: $customText, prompt: Text("CUSTOM MESSAGE").foregroundStyle(ARCTheme.text2))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(ARCTheme.text0)
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(ARCTheme.ink)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    // Return sends and leaves the field (the show keys come back); Esc leaves without sending.
                    .onSubmit {
                        sendCustom()
                        #if os(macOS)
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        #endif
                    }
                    .onExitCommand {
                        #if os(macOS)
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        #endif
                    }
                    .help("Custom Message: type any text for the stage screen, then Send or Return")

                Button {
                    sendCustom()
                } label: {
                    Text("SEND")
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        .foregroundStyle(customText.isEmpty ? ARCTheme.text2 : ARCTheme.ink)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(customText.isEmpty ? ARCTheme.surfaceLight : ARCTheme.secOrange)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(customText.isEmpty ? ARCTheme.line : ARCTheme.secOrange, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(customText.isEmpty)
                .help("Send Message: display your custom text on the stage screen for \(Int(messageDuration)) seconds")

                // TEXT ALERT (2026-09-24): the loud red banner that stays until cleared; in every layout.
                Button {
                    director.sendAlert(customText); customText = ""
                } label: {
                    Text("ALERT")
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        .foregroundStyle(customText.isEmpty ? ARCTheme.text2 : .white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(customText.isEmpty ? ARCTheme.surfaceLight : ARCTheme.arcRed)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(customText.isEmpty ? ARCTheme.line : ARCTheme.arcRed, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(customText.isEmpty)
                .help("TEXT ALERT: a loud red banner across the confidence monitor that stays until cleared")

                Button {
                    director.clearMessage(); director.clearAlert()
                } label: {
                    Text("CLEAR")
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        .foregroundStyle(director.message != nil || director.alert != nil ? ARCTheme.text0 : ARCTheme.text2)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(ARCTheme.surfaceLight)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Clear the message and the ALERT from the confidence monitor")
            }
        }
        .arcModule(title: "Stage Messages", tint: ARCTheme.secOrange)
    }

    private func messageHelp(for label: String) -> String {
        switch label {
        case "WRAP UP": return "Wrap Up — tell the speaker to finish their remarks"
        case "STOP": return "Stop — signal the speaker to stop immediately"
        case "HOLD": return "Hold — tell the speaker to pause and wait"
        case "THANK YOU": return "Thank You — signal the speaker that their time is complete"
        case "SPEED UP": return "Speed Up — tell the speaker to pick up the pace"
        case "SLOW DOWN": return "Slow Down — tell the speaker to ease up"
        case "Q&A": return "Q&A — signal transition to question and answer period"
        case "BREAK": return "Break — announce a break to the audience"
        default: return "Send \"\(label)\" to the confidence monitor"
        }
    }

    private func sendCustom() {
        guard !customText.isEmpty else { return }
        director.sendMessage(customText.uppercased(), duration: messageDuration)
        customText = ""
    }
}
