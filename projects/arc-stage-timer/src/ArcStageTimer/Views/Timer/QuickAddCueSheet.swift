//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Minimal form for adding a cue mid-show. Presented as a sheet from the sidebar.
struct QuickAddCueSheet: View {
    let onSave: (String, CueFormat, Int) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var format: CueFormat = .other
    @State private var minutes: Int = 15
    @State private var seconds: Int = 0

    var body: some View {
        NavigationStack {
            ZStack {
                ARCTheme.background.ignoresSafeArea()

                VStack(spacing: 20) {
                    // Title
                    TextField("Cue Title", text: $title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ARCTheme.textPrimary)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(ARCTheme.surface, in: RoundedRectangle(cornerRadius: 8))

                    // Format picker
                    HStack {
                        Text("FORMAT")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(ARCTheme.textTertiary)

                        Spacer()

                        Picker("Format", selection: $format) {
                            ForEach(CueFormat.allCases) { fmt in
                                HStack {
                                    Image(systemName: fmt.icon)
                                    Text(fmt.label)
                                }
                                .tag(fmt)
                            }
                        }
                        .tint(ARCTheme.accent)
                    }

                    // Duration
                    HStack {
                        Text("DURATION")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(ARCTheme.textTertiary)

                        Spacer()

                        // Minutes
                        Button { if minutes > 0 { minutes -= 1 } } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 18))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ARCTheme.accent)

                        Text(String(format: "%02d", minutes))
                            .font(.system(size: 24, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ARCTheme.textPrimary)
                            .frame(width: 36)

                        Text(":")
                            .font(.system(size: 24, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ARCTheme.textTertiary)

                        Text(String(format: "%02d", seconds))
                            .font(.system(size: 24, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ARCTheme.textPrimary)
                            .frame(width: 36)

                        Button {
                            minutes += 1
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 18))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ARCTheme.accent)

                        Spacer().frame(width: 12)

                        // Quick seconds adjust
                        Button {
                            seconds = max(0, seconds - 30)
                        } label: {
                            Text("-30s")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ARCTheme.textSecondary)

                        Button {
                            seconds += 30
                            if seconds >= 60 {
                                minutes += seconds / 60
                                seconds = seconds % 60
                            }
                        } label: {
                            Text("+30s")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ARCTheme.textSecondary)
                    }

                    Spacer()
                }
                .padding(ARCTheme.paddingMedium)
            }
            .navigationTitle("Add Cue")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let duration = minutes * 60 + seconds
                        onSave(title, format, max(duration, 1))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onChange(of: format) { _, newFormat in
            // Update duration to format default when format changes
            let def = newFormat.defaultDurationSeconds
            minutes = def / 60
            seconds = def % 60
        }
    }
}
