//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PDFKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ShowListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Show.date, order: .reverse) private var shows: [Show]
    @State private var showingImporter = false
    @State private var showingNewShow = false
    @State private var showingQuickSetup = false
    @State private var showingPasteAlert = false
    @State private var showingAgendaImport = false
    @State private var importedShow: Show?
    @State private var importError: String?
    @State private var showingClockMode = false
    @State private var showToRun: Show?
    /// Open the run screen in the control-panel layout (the automation bridge asks for this).
    @State private var runExtended = false
    /// Requests from the HTTP API and the launch flags (Automation.swift). This view has the model context and
    /// the navigation state, so it is the one that can carry them out.
    @State private var showingSavedShows = false
    @State private var saveConfirmation: String?
    #if os(iOS)
    @State private var isScanning = false
    @State private var showingStageDisplay = false
    #elseif os(macOS)
    @Environment(OutputRoutingManager.self) private var routingManager
    @Environment(DeckLinkOutputManager.self) private var deckLinkManager
    @State private var showingOutputRouting = false
    #endif

    var body: some View {
        ZStack {
            ARCTheme.background.ignoresSafeArea()

            // The welcome screen in the console's language (Presenter 5.5's): NEW on the left, the SHOWS on the right.
            HStack(alignment: .top, spacing: ARCTheme.paddingSmall) {
                // NEW gives up a little width on a narrow console before the SHOWS table does (2026-09-25).
                newShowModule.frame(width: listWidth < 1200 ? 280 : 340)
                if shows.isEmpty { emptyState } else { showList }
            }
            .padding(ARCTheme.paddingSmall)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
        .navigationTitle("Shows")
        #if os(macOS)
        .navigationSubtitle("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
        #endif
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 12) {
                    Button {
                        showingClockMode = true
                    } label: {
                        Image(systemName: "clock")
                            .foregroundStyle(ARCTheme.textSecondary)
                    }
                    .help("Clock Mode — display a full-screen clock (no show required)")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Quick Timer", systemImage: "bolt.fill") {
                        showingQuickSetup = true
                    }
                    Divider()
                    Button("New Show", systemImage: "plus") {
                        showingNewShow = true
                    }
                    Button("Import from Files", systemImage: "doc.badge.plus") {
                        showingImporter = true
                    }
                    Button("Paste ROS JSON", systemImage: "doc.on.clipboard") {
                        importFromClipboard()
                    }
                    Button("Paste Agenda Text", systemImage: "text.alignleft") {
                        showingAgendaImport = true
                    }
                    Divider()
                    Button("Load from Library", systemImage: "folder") {
                        showingSavedShows = true
                    }
                    if Bundle.main.url(forResource: "sample_ros", withExtension: "json") != nil {
                        Divider()
                        Button("Load Sample Show", systemImage: "star") {
                            loadBundledSample()
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewShow) {
            NavigationStack {
                ShowEditorView(show: nil)
            }
        }
        .sheet(isPresented: $showingQuickSetup) {
            NavigationStack {
                QuickShowSetupView()
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json, .pdf, .plainText, .commaSeparatedText, .spreadsheet]
                + [
                    UTType("org.openxmlformats.spreadsheetml.sheet"),
                    UTType("com.microsoft.excel.xls"),
                    UTType("org.openxmlformats.wordprocessingml.document"),
                    UTType("com.microsoft.word.doc")
                ].compactMap { $0 },
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .navigationDestination(item: $importedShow) { show in
            ShowEditorView(show: show)
        }
        #if DEBUG
        // DEBUG harness (/api/debug/edit-show?name=): open a show's editor with nobody at the mouse.
        .onReceive(NotificationCenter.default.publisher(for: .openShowEditor)) { note in
            if let name = note.object as? String, let show = shows.first(where: { $0.name == name }) { importedShow = show }
        }
        #endif
        // The automation bridge, hooked up ONCE. Nothing here is read in the body: doing that stalled the
        // first layout and the window never appeared (2026-09-17).
        .onAppear { Automation.shared.connect(handleAutomation) }
        .onChange(of: showToRun) { _, show in Automation.shared.setOpenShow(show?.name) }
        .onChange(of: shows.count) { _, _ in Automation.shared.setShowNames(shows.map(\.name)) }
        .navigationDestination(item: $showToRun) { show in
            TimerRunView(show: show, displayMode: runExtended ? .extended : .standalone)
        }
        .sheet(isPresented: $showingAgendaImport) {
            AgendaImportView { show in
                importedShow = show
            }
        }
        .sheet(isPresented: $showingSavedShows) {
            SavedShowsView { show in
                importedShow = show
            }
        }
        .alert("Import Error", isPresented: .init(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("Saved", isPresented: .init(
            get: { saveConfirmation != nil },
            set: { if !$0 { saveConfirmation = nil } }
        )) {
            Button("OK") { saveConfirmation = nil }
        } message: {
            Text(saveConfirmation ?? "")
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingClockMode) {
            ZStack(alignment: .topTrailing) {
                ClockDisplayView(stage: true)
                Button {
                    showingClockMode = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding()
                }
            }
            .background(Color.black)
            .preferredColorScheme(.dark)
        }
        .fullScreenCover(isPresented: $showingStageDisplay) {
            ZStack(alignment: .topTrailing) {
                StageDisplayView()
                    .environment(ArcStageTimerApp.sharedRemoteState.displayState)
                Button {
                    showingStageDisplay = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.3))
                        .padding()
                }
            }
            .background(Color.black)
            .preferredColorScheme(.dark)
        }
        #else
        .sheet(isPresented: $showingClockMode) {
            ZStack(alignment: .topTrailing) {
                ClockDisplayView(stage: true)
                Button {
                    showingClockMode = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding()
                }
            }
            .background(Color.black)
            .preferredColorScheme(.dark)
            .frame(minWidth: 800, minHeight: 450)
        }
        #endif
    }

    /// Carry out one automation request. This view is the only place with the model context AND the
    /// navigation state, so this is where a request becomes a show on screen.
    private func handleAutomation(_ request: Automation.Request) {
        switch request {
        case .testShow(let spec):
            guard let show = AutomationShows.makeTestShow(spec, in: modelContext) else {
                Automation.shared.note("could not build the test show \"\(spec.name)\"")
                return
            }
            Automation.shared.setShowNames(shows.map(\.name))
            if spec.open { runExtended = spec.extended; showToRun = show }
            Automation.shared.note("built \"\(show.name)\" with \(show.cues.count) cue(s)" + (spec.open ? " and opened it on the run screen" : ""))
        case .open(let name):
            guard let show = AutomationShows.show(named: name, in: modelContext) else {
                Automation.shared.note("no show called \"\(name)\"")
                return
            }
            showToRun = show
            Automation.shared.note("opened \"\(name)\" on the run screen")
        case .close:
            showToRun = nil
            Automation.shared.note("closed the run screen")
        case .openOutput(let id):
            openWindow.output(id)
            #if os(macOS)
            // On ITS display (the OUTPUTS assignment), as the chips and panel do.
            if let w = StageWindow(sceneID: id), w.isOutput { ArcStageTimerApp.sharedPlacement.placeWhenOpen(w) }
            #endif
            Automation.shared.note("opened the \(id) window")
        }
    }

    /// Everything that makes a show, as console keys. Quick Timer is THE action (red); the rest are chips.
    private var newShowModule: some View {
        VStack(alignment: .leading, spacing: 8) {
            ARCActionButton("Quick Timer", size: 14) { showingQuickSetup = true }
                .frame(height: 48)
                .help("Quick Timer: name your cues, pick durations, and run immediately")
            ARCModuleCaption("A countdown in seconds: cues and durations, then run.")
            VStack(spacing: 4) {
                newKey("New Show", "plus", "Full show editor: cue details, speakers, formats, scheduled times, thresholds") { showingNewShow = true }
                newKey("Import from Files", "doc.badge.plus", "Load a run of show from JSON, PDF, Excel, Word or a plain-text agenda") { showingImporter = true }
                newKey("Paste ROS JSON", "doc.on.clipboard", "Import a run of show from JSON text on the clipboard") { importFromClipboard() }
                newKey("Paste Agenda Text", "text.alignleft", "Paste a plain-text agenda: sessions, times and durations are detected") { showingAgendaImport = true }
                newKey("Load from Library", "folder", "Open a show saved to the local library") { showingSavedShows = true }
                if Bundle.main.url(forResource: "sample_ros", withExtension: "json") != nil {
                    newKey("Load Sample Show", "star", "A demo show with example cues") { loadBundledSample() }
                }
            }
            Rectangle().fill(ARCTheme.line).frame(height: 1).padding(.vertical, 4)
            newKey("Clock Mode", "clock", "A full-screen clock, no show required") { showingClockMode = true }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .arcModule(title: "New", tint: ARCTheme.secBlue)
    }

    private func newKey(_ title: String, _ icon: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).frame(width: 20)
                Text(title.uppercased()).font(ARCTheme.mono(13, .heavy)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ARCTheme.text0)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(ARCTheme.surfaceLight)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("NO SHOWS YET")
                .font(ARCTheme.mono(17, .heavy)).tracking(2)
                .foregroundStyle(ARCTheme.text0)
            guideStep(number: "1", title: "Make a show", detail: "Quick Timer for a fast countdown, or New Show for a full run of show with cue details, speakers and scheduled times.")
            guideStep(number: "2", title: "Give the outputs their displays", detail: "The OUTPUTS chips in the header: the CONFIDENCE MONITOR (and the KEY OVERLAY for an ATEM) each to a display, one click. Remembered per display, across launches and replugs.")
            guideStep(number: "3", title: "Run it", detail: "RUN on a show. Space plays and pauses, the arrow keys step cues, 1-4 flash the stage.")
            guideStep(number: "4", title: "Talk to the stage", detail: "Messages (WRAP UP, STOP, Q&A) and colour flashes go straight to the confidence monitor.")
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .arcModule(title: "Shows", badge: ARCBandBadge(text: "0", fill: ARCTheme.ink))
    }

    private func guideStep(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(ARCTheme.mono(14, .heavy))
                .foregroundStyle(ARCTheme.ink)
                .frame(width: 26, height: 26)
                .background(ARCTheme.secBlue)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(ARCTheme.mono(13, .heavy))
                    .foregroundStyle(ARCTheme.textPrimary)
                Text(detail)
                    .font(ARCTheme.mono(12, .regular))
                    .foregroundStyle(ARCTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    /// Column widths of the SHOWS table (header and rows share them).
    /// The window's width, measured: the table drops VENUE before it lets NAME shrink below a readable width.
    @State private var listWidth: CGFloat = 1600
    private var showVenue: Bool { listWidth >= 1240 }

    private enum Col {
        static let arc: CGFloat = 110
        static let date: CGFloat = 90
        static let venue: CGFloat = 170
        static let cues: CGFloat = 70
        static let length: CGFloat = 80
        static let run: CGFloat = 76
        static let nameMin: CGFloat = 150
    }

    private var showList: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(spacing: 10) {
                Text("ARC #").frame(width: Col.arc, alignment: .leading)
                Text("NAME").frame(minWidth: Col.nameMin, maxWidth: .infinity, alignment: .leading)
                Text("DATE").frame(width: Col.date, alignment: .leading)
                if showVenue { Text("VENUE").frame(width: Col.venue, alignment: .leading) }
                Text("CUES").frame(width: Col.cues, alignment: .trailing)
                Text("LENGTH").frame(width: Col.length, alignment: .trailing)
                Color.clear.frame(width: Col.run, height: 1)
            }
            .font(ARCTheme.mono(11, .heavy))
            .foregroundStyle(ARCTheme.text2)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Rectangle().fill(ARCTheme.line).frame(height: 1)
            #endif
            List {
                #if os(iOS)
                remoteSection
                #endif
                ForEach(shows) { show in
                    NavigationLink {
                        ShowEditorView(show: show)
                    } label: {
                        showRow(show)
                    }
                    .listRowBackground(ARCTheme.moduleBg)
                    .listRowSeparatorTint(ARCTheme.line)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            modelContext.delete(show)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            showToRun = show
                        } label: {
                            Label("Run", systemImage: "play.fill")
                        }
                        .tint(.green)
                    }
                    .contextMenu {
                        Button {
                            showToRun = show
                        } label: {
                            Label("Run Timer", systemImage: "play.fill")
                        }
                        Divider()
                        Button {
                            saveShowToLibrary(show)
                        } label: {
                            Label("Save to Library", systemImage: "folder.badge.plus")
                        }
                        Button {
                            duplicateShow(show)
                        } label: {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            modelContext.delete(show)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            #if os(macOS)
            Rectangle().fill(ARCTheme.line).frame(height: 1)
            Text("CLICK a show to edit it   RUN starts the timer   RIGHT-CLICK: save, duplicate, delete")
                .font(ARCTheme.mono(11, .bold))
                .foregroundStyle(ARCTheme.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
            #endif
        }
        .padding(-ARCTheme.modulePad)   // the table runs edge to edge inside the module
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .arcModule(title: "Shows", badge: ARCBandBadge(text: "\(shows.count)", fill: ARCTheme.ink))
    }

    private func showRow(_ show: Show) -> some View {
        #if os(macOS)
        HStack(spacing: 10) {
            Text(show.arcNumber?.isEmpty == false ? show.arcNumber! : "-")
                .font(ARCTheme.mono(12, .heavy))
                .foregroundStyle(show.arcNumber?.isEmpty == false ? ARCTheme.text0 : ARCTheme.text2)
                .frame(width: Col.arc, alignment: .leading)
            Text(show.name)
                .font(ARCTheme.mono(15, .bold))
                .foregroundStyle(ARCTheme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .frame(minWidth: Col.nameMin, maxWidth: .infinity, alignment: .leading)
                .help(show.name)
            Text(show.date.formatted(.dateTime.month(.abbreviated).day()).uppercased())
                .frame(width: Col.date, alignment: .leading)
            if showVenue {
                Text((show.venue ?? "").uppercased())
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: Col.venue, alignment: .leading)
            }
            Text("\(show.cues.count)")
                .frame(width: Col.cues, alignment: .trailing)
            Text(show.formattedTotalDuration.uppercased())
                .frame(width: Col.length, alignment: .trailing)
            ARCChip("Run", tint: ARCTheme.secOrange, on: true) { showToRun = show }
                .frame(width: Col.run)
                .help("Run this show on the timer")
        }
        .font(ARCTheme.mono(12, .bold))
        .foregroundStyle(ARCTheme.textSecondary)
        .padding(.vertical, 6)
        #else
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    if let arcNum = show.arcNumber, !arcNum.isEmpty {
                        Text(arcNum).font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.text0)
                    }
                    Text(show.name).font(ARCTheme.mono(15, .bold)).foregroundStyle(ARCTheme.textPrimary).lineLimit(1)
                }
                Text([show.date.formatted(.dateTime.month(.abbreviated).day()), show.venue ?? ""].filter { !$0.isEmpty }.joined(separator: "   "))
                    .font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(show.formattedTotalDuration).font(ARCTheme.mono(14, .bold)).foregroundStyle(ARCTheme.textSecondary)
                Text("\(show.cues.count) CUES").font(ARCTheme.mono(11, .bold)).foregroundStyle(ARCTheme.textTertiary)
            }
        }
        .padding(.vertical, 6)
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var remoteSection: some View {
            Section("Confidence Monitor") {
                if !isScanning {
                    Button("Scan for Controllers") {
                        isScanning = true
                        ArcStageTimerApp.sharedBonjourBrowser.startBrowsing()
                    }
                    .listRowBackground(ARCTheme.surface)
                } else if ArcStageTimerApp.sharedRemoteState.connectionState == .connected {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(ArcStageTimerApp.sharedRemoteState.serverName)
                            .foregroundStyle(ARCTheme.textPrimary)
                        Spacer()
                        Button("Disconnect") {
                            ArcStageTimerApp.sharedRemoteState.disconnect()
                            isScanning = false
                        }
                        .font(ARCTheme.caption)
                        .foregroundStyle(ARCTheme.textTertiary)
                    }
                    .listRowBackground(ARCTheme.surface)

                    Button {
                        showingStageDisplay = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "ipad.landscape")
                                .foregroundStyle(ARCTheme.accent)
                            Text("Open Confidence Monitor")
                                .foregroundStyle(ARCTheme.accent)
                        }
                    }
                    .listRowBackground(ARCTheme.surface)
                    .onChange(of: ArcStageTimerApp.sharedRemoteState.displayState.state) { _, newState in
                        if !showingStageDisplay && newState != "idle" && newState != "finished" {
                            showingStageDisplay = true
                        }
                    }
                } else if ArcStageTimerApp.sharedBonjourBrowser.servers.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Searching...")
                            .foregroundStyle(ARCTheme.textTertiary)
                    }
                    .listRowBackground(ARCTheme.surface)
                } else {
                    ForEach(ArcStageTimerApp.sharedBonjourBrowser.servers) { server in
                        Button {
                            ArcStageTimerApp.sharedRemoteState.connect(to: server)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "desktopcomputer")
                                    .foregroundStyle(ARCTheme.accent)
                                Text(server.name)
                                    .foregroundStyle(ARCTheme.textPrimary)
                                Spacer()
                                Text("Connect")
                                    .font(ARCTheme.caption)
                                    .foregroundStyle(ARCTheme.accent)
                            }
                        }
                        .listRowBackground(ARCTheme.surface)
                    }
                }
            }
    }
    #endif

    // MARK: - Import Methods

    private func saveShowToLibrary(_ show: Show) {
        do {
            try ShowFileManager.save(show)
            saveConfirmation = "\"\(show.name)\" saved to library."
        } catch {
            importError = "Save failed: \(error.localizedDescription)"
        }
    }

    private func duplicateShow(_ show: Show) {
        let copy = show.deepCopy()
        modelContext.insert(copy)
        for cue in copy.cues {
            modelContext.insert(cue)
        }
        try? modelContext.save()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        let ext = url.pathExtension.lowercased()
        if ext == "json" {
            importData(try Data(contentsOf: url))
        } else {
            // Non-JSON: read as text and run through AgendaTextParser
            importFromTextFile(url)
        }
    }

    private func importFromTextFile(_ url: URL) {
        do {
            let ext = url.pathExtension.lowercased()

            // XLSX — tabular data, map columns to cue fields
            if ext == "xlsx" || ext == "xls" {
                let fileData = try Data(contentsOf: url)
                guard let rows = DocumentParser.extractRowsFromXLSX(fileData), !rows.isEmpty else {
                    importError = "Could not read spreadsheet data from \(url.lastPathComponent)."
                    return
                }
                importSpreadsheetRows(rows, eventName: url.deletingPathExtension().lastPathComponent)
                return
            }

            // DOCX — extract text, feed through AgendaTextParser
            if ext == "docx" || ext == "doc" {
                let fileData = try Data(contentsOf: url)
                guard let text = DocumentParser.extractTextFromDOCX(fileData),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    importError = "Could not extract text from \(url.lastPathComponent).\n\nTry pasting the agenda text instead."
                    return
                }
                importAgendaText(text, eventName: url.deletingPathExtension().lastPathComponent)
                return
            }

            // PDF — extract text via PDFKit
            let text: String
            if ext == "pdf" {
                guard let pdfDoc = PDFDocument(url: url) else {
                    importError = "Could not open PDF.\n\nTry pasting the agenda text instead."
                    return
                }
                var extracted = ""
                for i in 0..<pdfDoc.pageCount {
                    if let pageText = pdfDoc.page(at: i)?.string {
                        extracted += pageText + "\n"
                    }
                }
                text = extracted
            } else {
                // Plain text, CSV
                text = try String(contentsOf: url, encoding: .utf8)
            }

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                importError = "File appears empty or could not be read as text."
                return
            }

            importAgendaText(text, eventName: url.deletingPathExtension().lastPathComponent)
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }

    /// Parse agenda text through AgendaTextParser → ROSImporter pipeline
    private func importAgendaText(_ text: String, eventName: String) {
        guard let doc = AgendaTextParser.parse(text, eventName: eventName) else {
            importError = "No agenda sessions found.\n\nTry Paste Agenda Text to manually adjust the input."
            return
        }
        do {
            let data = try JSONEncoder().encode(doc)
            let show = try ROSImporter.importShow(from: data)
            modelContext.insert(show)
            for cue in show.cues {
                cue.show = show
                modelContext.insert(cue)
            }
            try? modelContext.save()
            importedShow = show
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }

    /// Map spreadsheet rows to cues. Auto-detects columns by header row.
    /// Supported headers: title, time, duration, format, speakers, notes, subtitle
    private func importSpreadsheetRows(_ rows: [[String]], eventName: String) {
        guard !rows.isEmpty else { return }

        // Try to detect header row
        let firstRow = rows[0].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        let headerKeywords = Set(["title", "session", "name", "time", "duration", "format", "speaker", "speakers", "notes", "subtitle"])
        let hasHeader = firstRow.contains { headerKeywords.contains($0) }

        var titleCol = 0, timeCol = -1, durationCol = -1, formatCol = -1
        var speakersCol = -1, notesCol = -1, subtitleCol = -1

        if hasHeader {
            for (i, header) in firstRow.enumerated() {
                switch header {
                case "title", "session", "name", "session title", "cue", "cue title":
                    titleCol = i
                case "time", "start", "start time", "time range":
                    timeCol = i
                case "duration", "duration (min)", "minutes", "mins", "length":
                    durationCol = i
                case "format", "type", "session type":
                    formatCol = i
                case "speaker", "speakers", "presenter", "presenters":
                    speakersCol = i
                case "notes", "note", "comments":
                    notesCol = i
                case "subtitle", "description":
                    subtitleCol = i
                default: break
                }
            }
        } else {
            // No header: assume col 0=title, col 1=time or duration (if exists)
            if firstRow.count > 1 { timeCol = 1 }
            if firstRow.count > 2 { durationCol = 2 }
        }

        let dataRows = hasHeader ? Array(rows.dropFirst()) : rows
        guard !dataRows.isEmpty else {
            importError = "Spreadsheet has header row but no data rows."
            return
        }

        let show = Show(name: eventName, date: .now)
        var cues: [Cue] = []

        for (index, row) in dataRows.enumerated() {
            let title = safeCol(row, titleCol)
            guard !title.isEmpty else { continue }

            var durationSeconds = 0
            if durationCol >= 0 {
                let durStr = safeCol(row, durationCol)
                if let mins = Double(durStr) {
                    durationSeconds = Int(mins * 60)
                }
            }

            let timeStr = timeCol >= 0 ? safeCol(row, timeCol) : nil
            let formatStr = formatCol >= 0 ? safeCol(row, formatCol) : nil
            let speakers = speakersCol >= 0 ? safeCol(row, speakersCol) : nil
            let notes = notesCol >= 0 ? safeCol(row, notesCol) : nil
            let subtitle = subtitleCol >= 0 ? safeCol(row, subtitleCol) : nil

            // If duration is 0 and we have a time range, try to parse it
            if durationSeconds == 0, let t = timeStr, t.contains("-") || t.contains("–") {
                if let parsed = parseDurationFromTimeRange(t) {
                    durationSeconds = parsed
                }
            }

            let format = resolveFormat(formatStr, title: title)

            if durationSeconds == 0 {
                durationSeconds = format.defaultDurationSeconds
            }

            let cue = Cue(
                title: title,
                sortOrder: index,
                subtitle: subtitle.flatMap { $0.isEmpty ? nil : $0 },
                format: format,
                speakers: speakers.flatMap { $0.isEmpty ? nil : $0 },
                durationSeconds: durationSeconds,
                notes: notes.flatMap { $0.isEmpty ? nil : $0 }
            )
            cues.append(cue)
        }

        guard !cues.isEmpty else {
            importError = "No valid rows found in spreadsheet."
            return
        }

        show.cues = cues
        modelContext.insert(show)
        for cue in cues {
            cue.show = show
            modelContext.insert(cue)
        }
        try? modelContext.save()
        importedShow = show
    }

    private func safeCol(_ row: [String], _ index: Int) -> String {
        guard index >= 0, index < row.count else { return "" }
        return row[index].trimmingCharacters(in: .whitespaces)
    }

    private func parseDurationFromTimeRange(_ range: String) -> Int? {
        let parts = range.components(separatedBy: CharacterSet(charactersIn: "-–—"))
        guard parts.count == 2 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["h:mm a", "HH:mm", "h:mma", "H:mm"] {
            formatter.dateFormat = fmt
            if let start = formatter.date(from: parts[0].trimmingCharacters(in: .whitespaces)),
               let end = formatter.date(from: parts[1].trimmingCharacters(in: .whitespaces)) {
                let interval = end.timeIntervalSince(start)
                if interval > 0 { return Int(interval) }
            }
        }
        return nil
    }

    private func resolveFormat(_ formatStr: String?, title: String) -> CueFormat {
        if let fmt = formatStr?.lowercased(), !fmt.isEmpty {
            switch fmt {
            case "fireside", "fireside chat": return .fireside
            case "panel", "panel discussion": return .panel
            case "keynote", "keynote address": return .keynote
            case "lightning", "lightning talk": return .lightning
            case "remarks", "opening remarks", "closing remarks": return .remarks
            case "social", "networking", "reception": return .social
            case "transition": return .transition
            case "break", "coffee break", "lunch": return .breakTime
            case "green room", "greenroom": return .greenRoom
            default: break
            }
        }
        // Infer from title
        let lower = title.lowercased()
        if lower.contains("break") || lower.contains("lunch") || lower.contains("coffee") { return .breakTime }
        if lower.contains("keynote") { return .keynote }
        if lower.contains("panel") { return .panel }
        if lower.contains("fireside") { return .fireside }
        if lower.contains("networking") || lower.contains("reception") { return .social }
        if lower.contains("transition") || lower.contains("changeover") { return .transition }
        return .other
    }

    private func importFromClipboard() {
        #if os(iOS)
        let clipboardString = UIPasteboard.general.string
        #elseif os(macOS)
        let clipboardString = NSPasteboard.general.string(forType: .string)
        #endif
        guard let string = clipboardString,
              let data = string.data(using: .utf8) else {
            importError = "No JSON text found on clipboard.\n\nCopy the ROS JSON, then tap Paste ROS JSON."
            return
        }
        importData(data)
    }

    private func loadBundledSample() {
        guard let url = Bundle.main.url(forResource: "sample_ros", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return }
        importData(data)
    }

    private func importData(_ dataResult: @autoclosure () throws -> Data) {
        do {
            let data = try dataResult()
            let show = try ROSImporter.importShow(from: data)
            modelContext.insert(show)
            for cue in show.cues {
                cue.show = show
                modelContext.insert(cue)
            }
            try? modelContext.save()
            importedShow = show
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }
}
