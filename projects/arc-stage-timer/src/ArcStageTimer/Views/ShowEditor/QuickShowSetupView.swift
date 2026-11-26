//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import SwiftData

/// Rapid show builder — name cues, pick durations, hit Run.
/// No schedule times, no formats, no metadata. Pure countdown.
struct QuickShowSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showName = ""
    @State private var cueTitle = ""
    @State private var customMinutes = 15
    @State private var cues: [Cue] = []
    @State private var warningSeconds = 120
    @State private var dangerSeconds = 30
    @State private var savedShow: Show?
    @State private var runImmediately = false

    private let presetDurations: [(String, Int)] = [
        ("5m", 300),
        ("10m", 600),
        ("15m", 900),
        ("30m", 1800),
        ("45m", 2700),
        ("60m", 3600),
    ]

    var body: some View {
        ZStack {
            ARCTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Show name
                HStack(spacing: 12) {
                    Image(systemName: "timer")
                        .font(.system(size: 20))
                        .foregroundStyle(ARCTheme.accent)
                    TextField("Show Name", text: $showName)
                        .font(.system(size: 20, weight: .semibold))
                        .textFieldStyle(.plain)
                        .foregroundStyle(ARCTheme.textPrimary)
                        .help("Show Name — give your show a name (e.g. \"Board Meeting\" or \"Panel Discussion\")")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(ARCTheme.surface)

                Divider().background(ARCTheme.divider)

                // Cue entry row
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Cue name", text: $cueTitle)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .foregroundStyle(ARCTheme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(ARCTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                            .onSubmit {
                                addCue(duration: customMinutes * 60)
                            }
                            .help("Cue Name — type a name for this segment (e.g. \"Opening Remarks\"), then press Return or tap a duration to add it")

                        // Custom duration stepper
                        HStack(spacing: 4) {
                            Button {
                                if customMinutes > 1 { customMinutes -= 1 }
                            } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 11, weight: .bold))
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(ARCTheme.textSecondary)

                            Text("\(customMinutes)m")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(ARCTheme.textPrimary)
                                .frame(width: 36)

                            Button {
                                if customMinutes < 180 { customMinutes += 1 }
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .bold))
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(ARCTheme.textSecondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(ARCTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                        .help("Duration — adjust the countdown length for the next cue you add")

                        Button {
                            addCue(duration: customMinutes * 60)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(cueTitle.isEmpty ? ARCTheme.textTertiary : ARCTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(cueTitle.isEmpty)
                        .help("Add Cue — add the cue with the duration shown to the left")
                    }

                    // Preset duration buttons
                    HStack(spacing: 6) {
                        ForEach(presetDurations, id: \.1) { label, seconds in
                            Button {
                                customMinutes = seconds / 60
                                addCue(duration: seconds)
                            } label: {
                                Text(label)
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(cueTitle.isEmpty ? ARCTheme.textTertiary : ARCTheme.textPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(ARCTheme.surface, in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .disabled(cueTitle.isEmpty)
                        }
                        Spacer()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider().background(ARCTheme.divider)

                // Cue list
                if cues.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 36))
                            .foregroundStyle(ARCTheme.textTertiary)
                        Text("Type a cue name above and press Enter or tap a duration")
                            .font(.system(size: 13))
                            .foregroundStyle(ARCTheme.textTertiary)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(ARCTheme.textTertiary)
                                    .frame(width: 20)

                                Text(cue.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(ARCTheme.textPrimary)

                                Spacer()

                                Text(cue.formattedDuration)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(ARCTheme.textSecondary)
                            }
                            .listRowBackground(ARCTheme.surface)
                        }
                        .onDelete { offsets in
                            cues.remove(atOffsets: offsets)
                            reindex()
                        }
                        .onMove { source, dest in
                            cues.move(fromOffsets: source, toOffset: dest)
                            reindex()
                        }
                    }
                    .scrollContentBackground(.hidden)
                }

                Divider().background(ARCTheme.divider)

                // Footer: thresholds + total + Run
                VStack(spacing: 10) {
                    // Threshold controls
                    HStack(spacing: 20) {
                        HStack(spacing: 6) {
                            Circle().fill(ARCTheme.timerYellow).frame(width: 8, height: 8)
                            Text("WARN")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(ARCTheme.textTertiary)
                            Picker("", selection: $warningSeconds) {
                                Text("30s").tag(30)
                                Text("1m").tag(60)
                                Text("2m").tag(120)
                                Text("3m").tag(180)
                                Text("5m").tag(300)
                            }
                            .labelsHidden()
                            .frame(width: 70)
                        }
                        .help("Warning Threshold — timer turns yellow when this much time remains. Applied to all cues.")

                        HStack(spacing: 6) {
                            Circle().fill(ARCTheme.timerRed).frame(width: 8, height: 8)
                            Text("DANGER")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(ARCTheme.textTertiary)
                            Picker("", selection: $dangerSeconds) {
                                Text("10s").tag(10)
                                Text("15s").tag(15)
                                Text("30s").tag(30)
                                Text("60s").tag(60)
                            }
                            .labelsHidden()
                            .frame(width: 70)
                        }
                        .help("Danger Threshold — timer turns red when this much time remains. Applied to all cues.")

                        Spacer()

                        if !cues.isEmpty {
                            Text("\(cues.count) cues  \(formattedTotal)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(ARCTheme.textSecondary)
                        }
                    }

                    // Action buttons
                    HStack(spacing: 12) {
                        Button("Cancel") { dismiss() }
                            .keyboardShortcut(.cancelAction)

                        Spacer()

                        Button {
                            saveShow()
                        } label: {
                            Text("SAVE")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                        }
                        .disabled(showName.isEmpty || cues.isEmpty)
                        .help("Save — save the show to the library without starting the timer")

                        Button {
                            saveShow()
                            runImmediately = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                Text("RUN")
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                            }
                            .foregroundStyle(ARCTheme.background)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(ARCTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(showName.isEmpty || cues.isEmpty)
                        .help("Run — save the show and immediately start the timer on the first cue")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        #if os(macOS)
        .frame(minWidth: 580, minHeight: 420)
        #endif
        .navigationTitle("Quick Timer")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(item: $savedShow) { show in
            TimerRunView(show: show, displayMode: .standalone)
        }
    }

    // MARK: - Actions

    private func addCue(duration: Int) {
        let name = cueTitle.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        let cue = Cue(
            title: name,
            sortOrder: cues.count,
            durationSeconds: duration,
            warningThreshold: warningSeconds,
            dangerThreshold: dangerSeconds,
            overtimeAllowed: true
        )
        cues.append(cue)
        cueTitle = ""
    }

    private func reindex() {
        for (i, cue) in cues.enumerated() {
            cue.sortOrder = i
        }
    }

    private func saveShow() {
        // Apply current threshold settings to all cues
        for cue in cues {
            cue.warningThreshold = warningSeconds
            cue.dangerThreshold = dangerSeconds
        }

        let show = Show(name: showName.isEmpty ? "Quick Show" : showName, date: .now)
        modelContext.insert(show)
        for cue in cues {
            cue.show = show
            modelContext.insert(cue)
        }
        show.cues = cues
        show.updatedAt = .now
        try? modelContext.save()

        if runImmediately {
            savedShow = show
        } else {
            dismiss()
        }
    }

    private var formattedTotal: String {
        let total = cues.reduce(0) { $0 + $1.durationSeconds }
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
