//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private struct JSONExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ShowEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let show: Show?

    @State private var name: String = ""
    @State private var arcNumber: String = ""
    @State private var date: Date = .now
    @State private var venue: String = ""
    @State private var notes: String = ""
    @State private var cues: [Cue] = []
    /// The cue open in the CUE EDITOR sheet.
    @State private var selectedCue: Cue?
    /// Set while the open cue is one + ADD just made, so CANCEL can take it back out.
    @State private var newCueID: UUID?
    @State private var showingExporter = false
    @State private var exportData: Data?
    @AppStorage("keyOverlayEnabled") private var keyOverlayOn = false

    private var isNew: Bool { show == nil }

    var body: some View {
        ZStack {
            ARCTheme.background.ignoresSafeArea()

            Form {
                if let show, !cues.isEmpty {
                    Section {
                        NavigationLink {
                            TimerRunView(show: show, displayMode: .standalone)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 14, weight: .heavy))
                                    .foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(ARCTheme.arcRed, in: RoundedRectangle(cornerRadius: 4))
                                Text("RUN TIMER")
                                    .font(ARCTheme.mono(15, .heavy))
                                    .tracking(1)
                                    .foregroundStyle(ARCTheme.textPrimary)
                                Spacer()
                                Text("\(cues.count) CUES   \(show.formattedTotalDuration.uppercased())")
                                    .font(ARCTheme.mono(13, .bold))
                                    .foregroundStyle(ARCTheme.textSecondary)
                            }
                        }
                        .listRowBackground(ARCTheme.moduleBg)
                    }
                }

                Section {
                    TextField("Show Name", text: $name)
                        .help("Show Name — the event or production name displayed in the show list and timer header")
                    TextField("ARC Number (e.g. JOB-0000)", text: $arcNumber)
                        .help("ARC Number — optional job tracking number (e.g. JOB-0000). Displayed as a badge in the show list.")
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .help("Date — the event date. Used for sorting shows and calculating scheduled offsets during playback.")
                    TextField("Venue", text: $venue)
                        .help("Venue — the event location. Shown in the show list for quick reference.")
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3)
                        .help("Notes — internal production notes (not shown on the confidence monitor). Use for load-in details, contacts, or setup reminders.")
                } header: {
                    EditorBand(title: "Show", tint: ARCTheme.secBlue)
                }
                .listRowBackground(ARCTheme.moduleBg)

                Section {
                    if cues.isEmpty {
                        Text("No cues yet. + ADD makes one.")
                            .foregroundStyle(ARCTheme.textTertiary)
                            .listRowBackground(ARCTheme.moduleBg)
                    } else {
                        ForEach(cues) { cue in
                            Button {
                                newCueID = nil
                                selectedCue = cue
                            } label: {
                                CueRowView(cue: cue)
                            }
                            .listRowBackground(ARCTheme.moduleBg)
                        }
                        .onDelete(perform: deleteCues)
                        .onMove(perform: moveCues)
                    }
                } header: {
                    EditorBand(title: "Run order", tint: ARCTheme.secOrange, badge: "\(cues.count) CUES") {
                        addCue()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .formStyle(.grouped)
            .font(ARCTheme.mono(13, .regular))
        }
        .navigationTitle(isNew ? "New Show" : name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Create" : "Save") {
                    save()
                    if isNew { dismiss() }
                }
                .disabled(name.isEmpty)
            }
            if let show {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Export JSON") {
                        save()
                        if let data = ROSImporter.exportShow(show) {
                            exportData = data
                            showingExporter = true
                        }
                    }
                    .disabled(cues.isEmpty)
                    .help("Export JSON — save this show as a portable JSON file you can share or import on another device")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Run Timer") {
                        NavigationLink("Standalone", destination: TimerRunView(show: show, displayMode: .standalone))
                        NavigationLink("With Confidence Monitor", destination: TimerRunView(show: show, displayMode: .extended))
                        #if os(macOS)
                        // Only while the KEY OVERLAY is enabled in Settings.
                        if keyOverlayOn {
                            Divider()
                            NavigationLink("Key Overlay (DSK)", destination: TimerRunView(show: show, displayMode: .confidenceOverlay))
                            NavigationLink("Key Overlay (PIP)", destination: TimerRunView(show: show, displayMode: .confidencePIP))
                        }
                        #endif
                    }
                    .disabled(cues.isEmpty)
                    .help("Run Timer — start the countdown. Choose Standalone (single screen), With Confidence Monitor (HDMI/AirPlay output) or a Key Overlay for the ATEM.")
                }
            }
        }
        #if DEBUG
        // DEBUG harness (/api/debug/cue-editor?index=N, or ?new=1 for + ADD).
        .onReceive(NotificationCenter.default.publisher(for: .openCueEditor)) { note in
            if let i = note.object as? Int {
                if i < 0 { addCue() } else if cues.indices.contains(i) { newCueID = nil; selectedCue = cues[i] }
            }
        }
        #endif
        .sheet(item: $selectedCue) { cue in
            let index = cues.firstIndex(where: { $0.id == cue.id }) ?? 0
            CueFullEditor(
                cue: cue,
                position: index + 1,
                count: cues.count,
                status: nil,
                isNew: cue.id == newCueID,
                onSave: { draft in
                    draft.apply(to: cue)
                    newCueID = nil
                    if let i = cues.firstIndex(where: { $0.id == cue.id }) { rechain(after: i) }
                },
                // A cue not added yet has nothing to remove: CANCEL takes it back out.
                onDelete: cue.id == newCueID ? nil : {
                    if let i = cues.firstIndex(where: { $0.id == cue.id }) { deleteCues(at: IndexSet(integer: i)) }
                    newCueID = nil
                },
                onCancel: {
                    // A cue + ADD made and the operator cancelled: it never existed. (The old editor left a
                    // stray "New Cue" in the run order.)
                    if cue.id == newCueID, let i = cues.firstIndex(where: { $0.id == cue.id }) {
                        deleteCues(at: IndexSet(integer: i))
                    }
                    newCueID = nil
                }
            )
            // The editor's draft is @State: a different cue must be a different editor, or it keeps the last
            // cue's fields (seen when the sheet swapped cues in place, 2026-09-25).
            .id(cue.id)
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportData.map { JSONExportDocument(data: $0) },
            contentType: .json,
            defaultFilename: "\(name.isEmpty ? "show" : name.replacingOccurrences(of: " ", with: "_"))_ROS.json"
        ) { result in
            if case .failure(let error) = result {
                print("Export failed: \(error.localizedDescription)")
            }
        }
        .onAppear {
            if let show {
                name = show.name
                arcNumber = show.arcNumber ?? ""
                date = show.date
                venue = show.venue ?? ""
                notes = show.notes ?? ""
                cues = show.sortedCues
            }
        }
    }

    private func addCue() {
        let cue = Cue(
            title: "New Cue",
            sortOrder: cues.count,
            format: .other,
            durationSeconds: 1800
        )
        cues.append(cue)
        newCueID = cue.id
        selectedCue = cue
    }

    private func deleteCues(at offsets: IndexSet) {
        cues.remove(atOffsets: offsets)
        reindex()
    }

    private func moveCues(from source: IndexSet, to destination: Int) {
        cues.move(fromOffsets: source, toOffset: destination)
        reindex()
    }

    private func reindex() {
        for (i, cue) in cues.enumerated() {
            cue.sortOrder = i
        }
        recalculateStartTimes()
    }

    /// After one cue is edited: the cues after it follow its end. The same rule as the run screen
    /// (TimerEngine.updateCue), so a start time set in the editor holds and the rest of the show moves with it.
    /// An unscheduled cue leaves the rest alone.
    private func rechain(after index: Int) {
        guard index < cues.count, var next = cues[index].startTime else { return }
        next = next.addingTimeInterval(Double(cues[index].durationSeconds))
        for cue in cues.dropFirst(index + 1) {
            cue.startTime = next
            next = next.addingTimeInterval(Double(cue.durationSeconds))
        }
    }

    private func recalculateStartTimes() {
        guard !cues.isEmpty else { return }
        // If first cue has no startTime, nothing to recalculate
        guard let baseTime = cues[0].startTime else { return }

        var nextStart = baseTime
        for cue in cues {
            cue.startTime = nextStart
            nextStart = nextStart.addingTimeInterval(Double(cue.durationSeconds))
        }
    }

    private func save() {
        if let show {
            show.name = name
            show.arcNumber = arcNumber.isEmpty ? nil : arcNumber
            show.date = date
            show.venue = venue.isEmpty ? nil : venue
            show.notes = notes.isEmpty ? nil : notes
            show.updatedAt = .now

            // Sync cues
            let existing = Set(show.cues.map(\.id))
            let current = Set(cues.map(\.id))

            // Remove deleted cues
            for cue in show.cues where !current.contains(cue.id) {
                modelContext.delete(cue)
            }

            // Add/update cues
            for cue in cues {
                cue.show = show
                if !existing.contains(cue.id) {
                    modelContext.insert(cue)
                }
            }
            show.cues = cues
        } else {
            let newShow = Show(
                name: name,
                arcNumber: arcNumber.isEmpty ? nil : arcNumber,
                date: date,
                venue: venue.isEmpty ? nil : venue,
                notes: notes.isEmpty ? nil : notes
            )
            modelContext.insert(newShow)
            for cue in cues {
                cue.show = newShow
                modelContext.insert(cue)
            }
            newShow.cues = cues
        }
    }
}

/// A Form section's header as the bracket's band: filled in the section colour, ink heavy mono, left-aligned,
/// with an optional ink cap (a count) and an optional + ADD key.
struct EditorBand: View {
    let title: String
    let tint: Color
    var badge: String? = nil
    var add: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            Text(title.uppercased())
                .font(ARCTheme.mono(11, .heavy)).tracking(1.4)
                .foregroundStyle(ARCTheme.ink)
                .padding(.leading, ARCTheme.modulePad)
            Spacer()
            if let badge {
                Rectangle().fill(ARCTheme.moduleBg).frame(width: ARCTheme.capGap)
                Text(badge).font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.text0)
                    .padding(.horizontal, 8).frame(maxHeight: .infinity).background(ARCTheme.ink)
            }
            if let add {
                Rectangle().fill(ARCTheme.moduleBg).frame(width: ARCTheme.capGap)
                Button(action: add) {
                    Text("+ ADD").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.text0)
                        .padding(.horizontal, 10).frame(maxHeight: .infinity).background(ARCTheme.ink)
                }
                .buttonStyle(.plain)
                .help("Add a cue")
            }
        }
        .frame(height: ARCTheme.moduleHeaderH + 4)
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .textCase(nil)
    }
}
