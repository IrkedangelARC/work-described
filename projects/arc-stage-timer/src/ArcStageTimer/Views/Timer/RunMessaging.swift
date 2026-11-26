//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// MESSAGE and FLASH for the STANDALONE run view (2026-09-24: "add the ability to send messages and text
/// alerts as well as flash color to get attention"). The engine already had messages and flashes, but only the
/// control-deck layout showed them; the standalone view (RUN ORDER | NOW | TIMER | TRANSPORT) had neither.

/// The one-tap messages. The deck's eight, plus the time calls the desk actually sends.
enum MessagePresets {
    static let quick: [String] = ["WRAP UP", "5 MIN", "2 MIN", "1 MIN", "TIME'S UP",
                                  "SLOW DOWN", "SPEED UP", "SPEAK UP", "Q&A", "THANK YOU"]
}

extension Notification.Name {
    /// Show > Message (Cmd-Shift-M): put the cursor in the MESSAGE field.
    static let focusMessageField = Notification.Name("ARCStageTimerFocusMessageField")
}

// MARK: - MESSAGE (with ALERT)

struct RunMessageModule: View {
    @Environment(StageDirector.self) private var director
    @State private var text = ""
    /// Seconds a message stays up; nil = HOLD until cleared.
    @State private var seconds: Double? = 10
    @FocusState private var fieldFocused: Bool

    private static let durations: [(String, Double?)] = [("5 S", 5), ("10 S", 10), ("30 S", 30), ("HOLD", nil)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("", text: $text, prompt: Text("MESSAGE OR ALERT TEXT").foregroundStyle(ARCTheme.text2))
                    .textFieldStyle(.plain)
                    .font(ARCTheme.mono(14, .bold))
                    .foregroundStyle(ARCTheme.text0)
                    .focused($fieldFocused)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(ARCTheme.ink)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(fieldFocused ? ARCTheme.secOrange : ARCTheme.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    // Return SENDS and LEAVES the field, so Space and the arrows run the show again at once;
                    // Esc leaves without sending. Cmd-Shift-M comes back in.
                    .onSubmit { send(); fieldFocused = false }
                    .onExitCommand { fieldFocused = false }
                    .help("Type a message (Return sends it and gives the show keys back; Esc leaves the field) or an ALERT. Cmd-Shift-M puts the cursor here.")
                key("SEND", fill: ARCTheme.secOrange, enabled: !trimmed.isEmpty) { send() }
                    .help("Send the text to the confidence monitor as a message (\(durationWord))")
                key("ALERT", fill: ARCTheme.arcRed, text: .white, enabled: !trimmed.isEmpty) {
                    director.sendAlert(trimmed); text = ""
                }
                .help("TEXT ALERT: a loud red banner across the confidence monitor that stays until CLEAR ALERT")
            }
            presets
            // One row with the status when it fits; the status goes first, then the clears drop to a second row.
            // It used to truncate the status to "NO..." on a laptop (2026-09-25).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { durationBank; clearKeys; Spacer(minLength: 4); onAirStatus }
                HStack(spacing: 6) { durationBank; clearKeys; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 6) {
                    durationBank
                    HStack(spacing: 6) { clearKeys; Spacer(minLength: 0) }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusMessageField)) { _ in fieldFocused = true }
        #if os(macOS)
        // AppKit hands a new window's first responder to its first text field, which on the RUN layout is
        // this one: Space, the arrows and 1-4 then typed into it instead of running the show (measured
        // 2026-09-25, the console's first responder was the field editor on RUN, the window on DECK). The
        // show keys are live when the screen opens; Cmd-Shift-M or a click puts the cursor here.
        .onAppear {
            DispatchQueue.main.async {
                if let console = DisplayPlacement.windows(for: .control).first, console.firstResponder is NSText {
                    console.makeFirstResponder(nil)
                }
            }
        }
        #endif
    }

    private var durationBank: some View {
        ARCBank(Self.durations.map { label, value in
            ARCBankItem(label, on: seconds == value) { seconds = value }
        }, tint: ARCTheme.secOrange)
        .fixedSize()
        .help("How long a message stays up: 5, 10 or 30 seconds, or HOLD until cleared")
    }

    @ViewBuilder
    private var clearKeys: some View {
        key("CLEAR MSG", fill: ARCTheme.surfaceLight, text: ARCTheme.text0, enabled: director.message != nil) { director.clearMessage() }
        key("CLEAR ALERT", fill: ARCTheme.surfaceLight, text: ARCTheme.text0, enabled: director.alert != nil) { director.clearAlert() }
    }

    /// Ten keys in one row when it fits, else two rows of five. A key never shrinks its word.
    private var presets: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { ForEach(MessagePresets.quick, id: \.self) { presetKey($0) } }
            VStack(spacing: 4) {
                HStack(spacing: 4) { ForEach(MessagePresets.quick.prefix(5), id: \.self) { presetKey($0) } }
                HStack(spacing: 4) { ForEach(MessagePresets.quick.suffix(5), id: \.self) { presetKey($0) } }
            }
            // Narrower still (MESSAGE under FLASH on a small console): as many columns as fit.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 4)], spacing: 4) {
                ForEach(MessagePresets.quick, id: \.self) { presetKey($0) }
            }
        }
    }

    private func presetKey(_ label: String) -> some View {
        Button { director.sendMessage(label, duration: seconds) } label: {
            Text(label)
                .font(ARCTheme.mono(12, .heavy))
                .foregroundStyle(director.message == label ? ARCTheme.ink : ARCTheme.text0)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(director.message == label ? ARCTheme.secOrange : ARCTheme.surfaceLight)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(director.message == label ? ARCTheme.secOrange : ARCTheme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Send \"\(label)\" to the confidence monitor (\(durationWord))")
    }

    /// What the presenter is reading right now.
    private var onAirStatus: some View {
        HStack(spacing: 6) {
            // The ALERT has its own red band above NOW and the module's badge; this line is the message.
            if let m = director.message {
                statusTag(director.alert != nil ? "UNDER ALERT" : (director.messageHeld ? "HOLD" : "MSG"),
                          fill: director.alert != nil ? ARCTheme.text2 : ARCTheme.secOrange, fg: ARCTheme.ink)
                Text(m).font(ARCTheme.mono(12, .heavy)).foregroundStyle(ARCTheme.text0).lineLimit(1).truncationMode(.tail)
            }
            if director.message == nil {
                Text("NO MESSAGE UP").font(ARCTheme.mono(11, .bold)).foregroundStyle(ARCTheme.text2).lineLimit(1)
            }
        }
        .help("What is on the confidence monitor now")
    }

    private func statusTag(_ t: String, fill: Color, fg: Color) -> some View {
        Text(t).font(ARCTheme.mono(10, .heavy)).foregroundStyle(fg)
            .padding(.horizontal, 5).padding(.vertical, 2).background(fill)
            .clipShape(RoundedRectangle(cornerRadius: 2)).fixedSize()
    }

    private func key(_ title: String, fill: Color, text fg: Color = ARCTheme.ink, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(ARCTheme.mono(12, .heavy))
                .foregroundStyle(enabled ? fg : ARCTheme.text2)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(enabled ? fill : ARCTheme.surfaceLight)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(enabled ? fill : ARCTheme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var durationWord: String { seconds.map { "\(Int($0)) seconds" } ?? "until cleared" }

    private func send() {
        guard !trimmed.isEmpty else { return }
        director.sendMessage(trimmed.uppercased(), duration: seconds)
        text = ""
    }
}

// MARK: - FLASH

struct RunFlashModule: View {
    @Environment(StageDirector.self) private var director

    /// FlashControlPanel's colours; each key flashes the confidence monitor several times to get attention.
    private static let keys: [(String, Color)] = [("RED", .red), ("AMBER", .yellow), ("GREEN", .green), ("WHITE", .white)]

    var body: some View {
        @Bindable var director = director
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Self.keys, id: \.0) { label, color in
                    Button { director.flashForAttention(color: color) } label: {
                        Text(label)
                            .font(ARCTheme.mono(12, .heavy))
                            .foregroundStyle(ARCTheme.ink)
                            .lineLimit(1).fixedSize()
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(color)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Flash the confidence monitor \(label.lowercased()) four times to get the presenter's attention (Cmd-Shift-F: red)")
                }
            }
            HStack(spacing: 6) {
                Button { director.stopFlash() } label: {
                    Text("STOP")
                        .font(ARCTheme.mono(12, .heavy))
                        .foregroundStyle(director.isFlashingForAttention ? .white : ARCTheme.text2)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(director.isFlashingForAttention ? ARCTheme.arcRed : ARCTheme.surfaceLight)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(director.isFlashingForAttention ? ARCTheme.arcRed : ARCTheme.line, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Stop a flash that is running")
                Toggle(isOn: $director.autoFlashEnabled) {
                    Text("AUTO").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.text0)
                }
                .toggleStyle(.switch)
                .fixedSize()
                .help("Auto-Flash: flash the confidence monitor when the timer changes zone (warning, danger, overtime)")
                Spacer(minLength: 0)
                Text("KEYS 1-4: ONE FLASH").font(ARCTheme.mono(10, .bold)).foregroundStyle(ARCTheme.text2).lineLimit(1).fixedSize()
            }
        }
    }
}

// MARK: - The ALERT banner

/// The TEXT ALERT: ARC red, heavy, full width, a slow pulse on its border so it is noticed and then readable.
/// `scale` 1 = the operator's console; the stage passes its own height-derived size.
struct AlertBannerView: View {
    let text: String
    var fontSize: CGFloat = 20
    var height: CGFloat? = nil
    var isMatte = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: fontSize * 0.5) {
            Text("ALERT")
                .font(.system(size: fontSize * 0.55, weight: .heavy, design: .monospaced))
                .foregroundStyle(isMatte ? .white : ARCTheme.arcRed)
                .padding(.horizontal, fontSize * 0.3).padding(.vertical, fontSize * 0.1)
                .background(isMatte ? Color.black : .white)
                .fixedSize()
            Text(text)
                .font(.system(size: fontSize, weight: .heavy, design: .monospaced))
                .foregroundStyle(isMatte ? .black : .white)
                .lineLimit(2)
                .minimumScaleFactor(0.3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, fontSize * 0.6)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .padding(.vertical, height == nil ? fontSize * 0.35 : 0)
        .background(isMatte ? Color.white : ARCTheme.arcRed)
        .overlay(Rectangle().strokeBorder(.white.opacity(pulse ? 0.9 : 0.15), lineWidth: max(2, fontSize * 0.12)))
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

// MARK: - LAYOUT

/// How the run screen is laid out. Chosen on the run view's LAYOUT chip (and Show menu), remembered.
enum RunLayout: String, CaseIterable {
    case run, deck, widget
    static let defaultsKey = "runLayout"

    var label: String {
        switch self {
        case .run: "RUN"
        case .deck: "DECK"
        case .widget: "WIDGET"
        }
    }

    /// What each one gives, in the chip's tooltip and the Settings line.
    var tip: String {
        switch self {
        case .run: "RUN: run order, the cue, a big timer, transport, MESSAGE / ALERT and FLASH."
        case .deck: "DECK: every control on one screen: stage display, web stage, stage mode, transport, flash, messages with ALERT, outputs."
        case .widget: "WIDGET: a small floating panel (timer, transport, flash, messages, ALERT); the console goes to the Dock. Cmd-Shift-O switches back."
        }
    }
}
