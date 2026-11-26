//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Compact inline editor for a single cue, displayed within the 280pt sidebar.
/// Mutates the @Model Cue directly — changes propagate to TimerEngine on next tick.
struct CueInlineEditor: View {
    let cue: Cue
    var onDelete: (() -> Void)?
    /// Opens the full CUE EDITOR for every field (the ARC expand glyph beside the title).
    var onExpand: (() -> Void)?

    @State private var title: String = ""
    @State private var minutes: Int = 0
    @State private var seconds: Int = 0
    @State private var notes: String = ""
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title, and the way into the full editor
            HStack(spacing: 4) {
                TextField("Cue Title", text: $title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ARCTheme.textPrimary)
                    .textFieldStyle(.plain)
                    .padding(6)
                    .background(ARCTheme.background, in: RoundedRectangle(cornerRadius: 4))
                if let onExpand {
                    ARCExpandButton(tip: "Open the full CUE EDITOR: format, schedule, thresholds, speakers, notes", action: onExpand)
                }
            }

            // Duration — minutes : seconds steppers
            HStack(spacing: 4) {
                Text("DUR")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(ARCTheme.textTertiary)

                Spacer()

                // Minutes stepper
                Button { if minutes > 0 { minutes -= 1 } } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ARCTheme.accent)

                Text(String(format: "%02d", minutes))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ARCTheme.textPrimary)
                    .frame(width: 28)

                Text(":")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ARCTheme.textTertiary)

                Text(String(format: "%02d", seconds))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ARCTheme.textPrimary)
                    .frame(width: 28)

                Button { if minutes < 999 { minutes += 1 } } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ARCTheme.accent)

                Spacer().frame(width: 8)

                // Seconds stepper
                Button { seconds = max(0, seconds - 10) } label: {
                    Text("-10s")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .frame(height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ARCTheme.textSecondary)

                Button {
                    seconds += 10
                    if seconds >= 60 {
                        minutes += seconds / 60
                        seconds = seconds % 60
                    }
                } label: {
                    Text("+10s")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .frame(height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ARCTheme.textSecondary)
            }

            // Notes (single line)
            TextField("Notes", text: $notes)
                .font(.system(size: 12))
                .foregroundStyle(ARCTheme.textSecondary)
                .textFieldStyle(.plain)
                .padding(6)
                .background(ARCTheme.background, in: RoundedRectangle(cornerRadius: 4))

            // Remove cue button (only if onDelete is provided)
            if let onDelete {
                Button {
                    showDeleteConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text("REMOVE CUE")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .confirmationDialog("Remove this cue?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { onDelete() }
                    Button("Cancel", role: .cancel) { }
                }
            }
        }
        .padding(.horizontal, ARCTheme.paddingSmall)
        .padding(.vertical, ARCTheme.paddingSmall)
        .background(ARCTheme.surfaceLight.opacity(0.5))
        .onAppear { loadFromCue() }
        .onChange(of: title) { _, val in cue.title = val }
        .onChange(of: minutes) { _, _ in commitDuration() }
        .onChange(of: seconds) { _, _ in commitDuration() }
        .onChange(of: notes) { _, val in cue.notes = val.isEmpty ? nil : val }
    }

    private func loadFromCue() {
        title = cue.title
        let total = cue.durationSeconds
        minutes = total / 60
        seconds = total % 60
        notes = cue.notes ?? ""
    }

    private func commitDuration() {
        cue.durationSeconds = minutes * 60 + seconds
    }
}
