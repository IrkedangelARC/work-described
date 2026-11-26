//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Sheet for pasting raw agenda text and importing it as a Show.
struct AgendaImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var onImport: ((Show) -> Void)?

    @State private var eventName: String = ""
    @State private var agendaText: String = ""
    @State private var previewSessions: [ROSSession] = []
    @State private var showingPreview = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ARCTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Event name field
                    VStack(alignment: .leading, spacing: 4) {
                        Text("EVENT NAME")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(ARCTheme.textTertiary)
                        TextField("Annual Summit 2026", text: $eventName)
                            .font(ARCTheme.bodyText)
                            .foregroundStyle(ARCTheme.textPrimary)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(ARCTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.horizontal, ARCTheme.paddingMedium)
                    .padding(.top, ARCTheme.paddingMedium)

                    // Agenda text editor
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AGENDA TEXT")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(ARCTheme.textTertiary)
                        TextEditor(text: $agendaText)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(ARCTheme.textPrimary)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(ARCTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxHeight: .infinity)
                    }
                    .padding(.horizontal, ARCTheme.paddingMedium)
                    .padding(.top, ARCTheme.paddingSmall)

                    // Error message
                    if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ARCTheme.timerRed)
                            .padding(.horizontal, ARCTheme.paddingMedium)
                            .padding(.top, 4)
                    }

                    // Preview section
                    if showingPreview && !previewSessions.isEmpty {
                        previewList
                    }

                    // Action buttons
                    HStack(spacing: 12) {
                        Button("Preview") {
                            runPreview()
                        }
                        .buttonStyle(.bordered)
                        .disabled(agendaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Import") {
                            runImport()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(previewSessions.isEmpty)
                    }
                    .padding(ARCTheme.paddingMedium)
                }
            }
            .navigationTitle("Paste Agenda")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { prefillFromClipboard() }
        }
    }

    // MARK: - Preview List

    private var previewList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(previewSessions.count) SESSIONS FOUND")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(ARCTheme.accent)
                Spacer()
            }
            .padding(.horizontal, ARCTheme.paddingMedium)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(previewSessions.enumerated()), id: \.offset) { _, session in
                        HStack {
                            if let time = session.resolvedTimeRange {
                                Text(time)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(ARCTheme.textTertiary)
                                    .frame(width: 120, alignment: .leading)
                            }
                            Text(session.resolvedTitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ARCTheme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            if let mins = session.resolvedDurationMinutes {
                                Text("\(mins)m")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(ARCTheme.textTertiary)
                            }
                        }
                        .padding(.horizontal, ARCTheme.paddingMedium)
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 200)
            .background(ARCTheme.surface.opacity(0.5))
        }
    }

    // MARK: - Actions

    private func prefillFromClipboard() {
        #if os(iOS)
        if let clip = UIPasteboard.general.string, !clip.isEmpty {
            agendaText = clip
        }
        #elseif os(macOS)
        if let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty {
            agendaText = clip
        }
        #endif
    }

    private func runPreview() {
        errorMessage = nil
        let name = eventName.isEmpty ? nil : eventName
        guard let doc = AgendaTextParser.parse(agendaText, eventName: name) else {
            errorMessage = "No sessions found. Check that each line has a time or duration."
            previewSessions = []
            showingPreview = false
            return
        }
        previewSessions = doc.sessions ?? []
        showingPreview = true
    }

    private func runImport() {
        errorMessage = nil
        let name = eventName.isEmpty ? nil : eventName
        guard let doc = AgendaTextParser.parse(agendaText, eventName: name) else {
            errorMessage = "No sessions found."
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(doc)
            let show = try ROSImporter.importShow(from: data)
            modelContext.insert(show)
            for cue in show.cues {
                cue.show = show
                modelContext.insert(cue)
            }
            try? modelContext.save()
            onImport?(show)
            dismiss()
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}
