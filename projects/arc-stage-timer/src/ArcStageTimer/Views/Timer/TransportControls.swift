//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct TransportControls: View {
    @Bindable var engine: TimerEngine
    /// The OPERATE widget wants the compact keys on a Mac, where the size class never says so.
    var forceCompact: Bool = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isCompact: Bool { forceCompact || sizeClass == .compact }

    var body: some View {
        HStack(spacing: isCompact ? 8 : 10) {
            // Previous cue
            transportButton(icon: "backward.end.fill", enabled: engine.hasPrevious) {
                triggerHaptic()
                engine.previous()
            }
            .help("Previous Cue — jump to the prior cue in the run of show")

            // -1 minute
            timeAdjustButton(label: "-1m") {
                triggerHaptic()
                engine.subtractTime(seconds: 60)
            }
            .help("Subtract 1 Minute — remove 60 seconds from the current cue countdown")

            // -10 seconds
            timeAdjustButton(label: "-10s") {
                triggerHaptic()
                engine.subtractTime(seconds: 10)
            }
            .help("Subtract 10 Seconds — remove 10 seconds from the current cue countdown")

            // Reset cue
            Button {
                triggerHaptic()
                engine.reset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: isCompact ? 16 : 19, weight: .heavy))
                    .foregroundStyle(canReset ? ARCTheme.text0 : ARCTheme.text2)
                    .frame(width: isCompact ? 44 : 52, height: isCompact ? 38 : 44)
                    .background(ARCTheme.surfaceLight)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(!canReset)
            .help("Reset Cue: restart the current cue timer from the beginning")

            // Play / Pause
            // The one control that is doing something reads as doing it: running = ARC red.
            Button {
                triggerHaptic(heavy: true)
                engine.togglePlayPause()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: playPauseIcon).font(.system(size: isCompact ? 18 : 22, weight: .heavy))
                    Text(isRunning ? "PAUSE" : "START")
                        .font(.system(size: isCompact ? 14 : 17, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(isRunning ? ARCTheme.ink : ARCTheme.text0)
                .frame(width: isCompact ? 120 : 148, height: isCompact ? 44 : 52)
                .background(isRunning ? ARCTheme.arcRed : ARCTheme.surfaceLight)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isRunning ? ARCTheme.arcRed : ARCTheme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help(playPauseHelp)

            // +10 seconds
            timeAdjustButton(label: "+10s") {
                triggerHaptic()
                engine.addTime(seconds: 10)
            }
            .help("Add 10 Seconds — extend the current cue countdown by 10 seconds")

            // +1 minute
            timeAdjustButton(label: "+1m") {
                triggerHaptic()
                engine.addTime(seconds: 60)
            }
            .help("Add 1 Minute — extend the current cue countdown by 60 seconds")

            // Next cue
            transportButton(icon: "forward.end.fill", enabled: engine.hasNext) {
                triggerHaptic()
                engine.next()
            }
            .help("Next Cue — advance to the next cue in the run of show")
        }
    }

    private var isRunning: Bool { engine.state == .running || engine.state == .overtime }

    private var canReset: Bool {
        engine.elapsedSeconds > 0 || engine.state == .overtime || engine.state == .finished
    }

    private var playPauseHelp: String {
        switch engine.state {
        case .running, .overtime: "Pause — freeze the countdown timer"
        case .paused: "Resume — continue the countdown from where it stopped"
        case .idle, .finished: "Start — begin the countdown for the current cue"
        }
    }

    private var playPauseIcon: String {
        switch engine.state {
        case .running, .overtime: "pause.fill"
        case .paused: "play.fill"
        case .idle, .finished: "play.fill"
        }
    }

    private func triggerHaptic(heavy: Bool = false) {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: heavy ? .medium : .light).impactOccurred()
        #endif
    }

    /// One construction for every transport key: the console's rectangle, hairline border, monospace.
    private func key<Content: View>(width: CGFloat, enabled: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: width, height: isCompact ? 38 : 44)
            .background(ARCTheme.surfaceLight)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .opacity(enabled ? 1 : 0.45)
    }

    private func transportButton(icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            key(width: isCompact ? 48 : 56, enabled: enabled) {
                Image(systemName: icon)
                    .font(.system(size: isCompact ? 16 : 19, weight: .heavy))
                    .foregroundStyle(enabled ? ARCTheme.text0 : ARCTheme.text2)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func timeAdjustButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            key(width: isCompact ? 50 : 60) {
                Text(label.uppercased())
                    .font(.system(size: isCompact ? 13 : 15, weight: .heavy, design: .monospaced))
                    .foregroundStyle(ARCTheme.text0)
            }
        }
        .buttonStyle(.plain)
    }
}
