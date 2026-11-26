//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct TimerControlView: View {
    @Environment(TimerEngine.self) private var timer
    @Environment(DeckManager.self) private var deckManager
    @Environment(SlideEngine.self) private var engine
    @State private var durationText: String = ""
    @State private var cueLabel: String = ""
    @FocusState private var durationFieldFocused: Bool

    var body: some View {
        @Bindable var timer = timer

        VStack(spacing: 6) {
            // One row, one construction: transport | clock | mode.
            HStack(spacing: 8) {
                Button(action: { timer.toggle() }) {
                    Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 16))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(timer.isRunning ? ARCTheme.liveRed : ARCTheme.readyGreen)
                }
                .buttonStyle(.plain)
                .help(timer.isRunning ? "Pause timer (Cmd+Shift+T)" : "Start timer (Cmd+Shift+T)")

                Button(action: { timer.reset() }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(ARCTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Reset timer to zero (Cmd+Shift+R)")

                Spacer(minLength: 4)

                VStack(spacing: 0) {
                    Text(timer.displayString)
                        .font(ARCTheme.slideCounter)
                        .foregroundStyle(timer.isOvertime ? ARCTheme.liveRed : ARCTheme.textPrimary)
                    if timer.isOvertime {
                        // A state, not a tally: the room does not need to know by how much (2026-09-18).
                        Text("OVER")
                            .font(ARCTheme.statusBadge)
                            .foregroundStyle(ARCTheme.liveRed)
                    }
                }

                Spacer(minLength: 4)

                Picker("", selection: $timer.mode) {
                    ForEach(TimerEngine.Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .help("Count Up: elapsed time. Count Down: remaining time with overtime warning.")
            }

            // Duration controls (countdown mode only)
            if timer.mode == .countDown {
                ARCTheme.divider.frame(height: 1)

                // Increment/decrement buttons
                HStack(spacing: 4) {
                    adjustButton(label: "-15", minutes: -15)
                    adjustButton(label: "-5", minutes: -5)
                    adjustButton(label: "-1", minutes: -1)

                    Spacer().frame(width: 8)

                    adjustButton(label: "+1", minutes: 1)
                    adjustButton(label: "+5", minutes: 5)
                    adjustButton(label: "+15", minutes: 15)
                }
            }

            // Timer cue controls
            cueSection
        }
    }

    // MARK: - Timer Cue Section

    @ViewBuilder
    private var cueSection: some View {
        let currentPage = engine.currentPage
        let currentCue = deckManager.liveDeck?.cueFor(page: currentPage)
        let hasCue = currentCue != nil

        ARCTheme.divider.frame(height: 1)

        VStack(spacing: 4) {
            // Active cue label
            if !deckManager.activeCueLabel.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(ARCTheme.accent)
                    Text(deckManager.activeCueLabel)
                        .font(ARCTheme.mono(12, .bold))
                        .foregroundStyle(ARCTheme.accent)
                        .lineLimit(1)
                    Spacer()
                }
            }

            // SET shares the cue row (2026-09-23): the rail has to fit NEXT, TIMER, MESSAGE and MUSIC
            // unscrolled at 945 pt tall, and SET had a row of its own with 370 pt of nothing beside it.
            HStack(spacing: 6) {
                if timer.mode == .countDown {
                    durationEntry
                    Rectangle().fill(ARCTheme.line).frame(width: 1, height: 18)
                }
                if hasCue {
                    // Show existing cue info
                    HStack(spacing: 4) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(ARCTheme.accent)
                        Text("S\(currentPage)")
                            .font(ARCTheme.mono(12, .bold))
                            .foregroundStyle(ARCTheme.textPrimary)
                        if let cue = currentCue {
                            Text(cue.action == .stop ? "STOP" : formatDuration(cue.duration))
                                .font(ARCTheme.mono(12, .medium))
                                .foregroundStyle(ARCTheme.textSecondary)
                        }
                    }

                    Spacer()

                    Button("CLR") {
                        deckManager.liveDeck?.removeCue(at: currentPage)
                    }
                    .font(ARCTheme.mono(11, .bold))
                    .buttonStyle(.plain)
                    .foregroundStyle(ARCTheme.liveRed)
                    .help("Remove timer cue from slide \(currentPage)")
                } else {
                    // Set cue controls
                    TextField("Label", text: $cueLabel)
                        .font(ARCTheme.mono(12, .medium))
                        .textFieldStyle(.roundedBorder)
                    .focusEffectDisabled()   // no system-teal focus ring on an ARC surface (2026-09-12)
                        .frame(width: 100)
                        .help("Optional label for this cue (e.g., presenter name)")

                    Spacer()

                    Button("CUE") {
                        deckManager.liveDeck?.setCue(
                            at: currentPage,
                            duration: timer.countdownDuration,
                            label: cueLabel,
                            action: .startCountdown
                        )
                        cueLabel = ""
                    }
                    .font(ARCTheme.mono(11, .heavy))
                    .buttonStyle(.plain)
                    .foregroundStyle(ARCTheme.accent)
                    .help("Set countdown cue (\(timer.durationDisplayString)) on slide \(currentPage)")

                    Button("STOP") {
                        deckManager.liveDeck?.setCue(
                            at: currentPage,
                            duration: 0,
                            label: cueLabel,
                            action: .stop
                        )
                        cueLabel = ""
                    }
                    .font(ARCTheme.mono(11, .heavy))
                    .buttonStyle(.plain)
                    .foregroundStyle(ARCTheme.liveRed)
                    .help("Set stop cue on slide \(currentPage) (auto-pause timer)")
                }
            }
        }
    }

    /// Direct entry of the countdown length: "SET  mm:ss", Enter applies.
    private var durationEntry: some View {
        @Bindable var timer = timer
        return HStack(spacing: 6) {
            Text("SET")
                .font(ARCTheme.mono(12, .heavy))
                .foregroundStyle(ARCTheme.textSecondary)

            TextField("mm:ss", text: $durationText)
                .font(ARCTheme.mono(16, .medium))
                .textFieldStyle(.roundedBorder)
                .focusEffectDisabled()   // no system-teal focus ring on an ARC surface (2026-09-12)
                .frame(width: 90)
                .focused($durationFieldFocused)
                .help("Type duration as mm:ss then press Enter")
                .onSubmit {
                    timer.setDuration(from: durationText)
                    durationText = timer.durationDisplayString
                    durationFieldFocused = false
                }
        }
        .fixedSize()
        .onAppear { durationText = timer.durationDisplayString }
        .onChange(of: timer.countdownDuration) {
            if !durationFieldFocused {
                durationText = timer.durationDisplayString
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func adjustButton(label: String, minutes: Int) -> some View {
        Button {
            timer.adjustDuration(byMinutes: minutes)
        } label: {
            Text(label)
                .font(ARCTheme.mono(13, .heavy))
                .foregroundStyle(minutes < 0 ? ARCTheme.liveRed : ARCTheme.readyGreen)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(ARCTheme.surfaceLight)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder((minutes < 0 ? ARCTheme.liveRed : ARCTheme.readyGreen).opacity(0.3), lineWidth: 1)
                )
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help("Adjust countdown by \(minutes > 0 ? "+" : "")\(minutes) minute\(abs(minutes) == 1 ? "" : "s")")
    }
}
