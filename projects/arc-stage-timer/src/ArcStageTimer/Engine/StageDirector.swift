//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

enum StageMode: String, CaseIterable {
    case timer
    case clock
    case hold

    var label: String {
        switch self {
        case .timer: "TIMER"
        case .clock: "CLOCK"
        case .hold: "HOLD"
        }
    }

    var icon: String {
        switch self {
        case .timer: "timer"
        case .clock: "clock"
        case .hold: "pause.rectangle"
        }
    }
}

/// Manages stage display overlays — text messages and color flashes.
/// Injected via environment alongside TimerEngine and ExternalDisplayManager.
@Observable
final class StageDirector {

    // MARK: - Stage Mode

    private(set) var stageMode: StageMode = .timer
    var holdEventName: String = ""

    func setMode(_ mode: StageMode) {
        stageMode = mode
    }

    // MARK: - Message Overlay

    private(set) var message: String?
    private(set) var messageOpacity: Double = 0

    // MARK: - Flash Overlay

    private(set) var flashColor: Color?
    private(set) var flashOpacity: Double = 0
    private(set) var flashSequence: Int = 0

    // MARK: - Message Sequence

    private(set) var messageSequence: Int = 0

    // MARK: - Auto-Flash

    var autoFlashEnabled: Bool = false
    private(set) var lastColorState: TimerColorState?

    // MARK: - Timers

    private var messageDismissTask: Task<Void, Never>?
    private var flashFadeTask: Task<Void, Never>?

    // MARK: - Alert (2026-09-24, the operator: "send messages and text alerts as well as flash color to get attention")

    /// A TEXT ALERT: the loud one. A full-width ARC-red banner on the confidence monitor that stays until
    /// CLEARED. Its own channel, so a message can still show underneath and neither replaces the other.
    private(set) var alert: String?
    private(set) var alertSequence: Int = 0

    func sendAlert(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        alertSequence += 1
        withAnimation(.easeIn(duration: 0.15)) { alert = t.uppercased() }
    }

    func clearAlert() {
        withAnimation(.easeOut(duration: 0.3)) { alert = nil }
    }

    /// Message, alert and flash all off the confidence monitor at once.
    func clearAll() {
        clearMessage()
        clearAlert()
        stopFlash()
    }

    // MARK: - Message Control

    /// The current message stays until cleared (sent with HOLD) rather than timing out.
    private(set) var messageHeld = false

    /// `duration` nil = HOLD: the message stays until CLEAR (or the next message).
    func sendMessage(_ text: String, duration: TimeInterval? = 5) {
        messageDismissTask?.cancel()
        messageSequence += 1
        message = text
        messageHeld = duration == nil
        withAnimation(.easeIn(duration: 0.2)) {
            messageOpacity = 1
        }
        guard let duration else { return }
        messageDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            clearMessage()
        }
    }

    func clearMessage() {
        messageHeld = false
        messageDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.5)) {
            messageOpacity = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            message = nil
        }
    }

    // MARK: - Flash Control

    func flash(color: Color, duration: TimeInterval = 0.8) {
        flashFadeTask?.cancel()
        flashSequence += 1
        flashColor = color
        flashOpacity = 0.8
        flashFadeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: duration)) {
                flashOpacity = 0
            }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            flashColor = nil
        }
    }

    /// An ATTENTION flash: `pulses` flashes of `color` in a row (the FLASH module), stoppable with STOP.
    private(set) var isFlashingForAttention = false
    private var attentionTask: Task<Void, Never>?

    func flashForAttention(color: Color, pulses: Int = 4) {
        attentionTask?.cancel()
        isFlashingForAttention = true
        attentionTask = Task { @MainActor in
            for _ in 0..<max(1, pulses) {
                guard !Task.isCancelled else { return }
                flash(color: color, duration: 0.45)
                try? await Task.sleep(for: .milliseconds(650))
            }
            guard !Task.isCancelled else { return }
            isFlashingForAttention = false
        }
    }

    func stopFlash() {
        attentionTask?.cancel()
        attentionTask = nil
        isFlashingForAttention = false
        flashFadeTask?.cancel()
        flashOpacity = 0
        flashColor = nil
    }

    // MARK: - Auto-Flash on Color State Transitions

    func handleColorStateChange(from oldState: TimerColorState, to newState: TimerColorState) {
        defer { lastColorState = newState }
        guard autoFlashEnabled else { return }

        switch (oldState, newState) {
        case (.nominal, .warning):
            flash(color: .yellow)
        case (.warning, .danger):
            flash(color: .red)
        case (_, .overtime):
            // Double flash for overtime entry
            flash(color: .red, duration: 0.4)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                flash(color: .red, duration: 0.8)
            }
        default:
            break
        }
    }
}
