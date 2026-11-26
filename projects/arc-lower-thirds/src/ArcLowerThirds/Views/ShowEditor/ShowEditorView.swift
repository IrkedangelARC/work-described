//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(macOS)
import PDFKit
#endif

/// Editor for a Show — metadata + list of graphics with add/edit/delete/reorder.
struct ShowEditorView: View {
    @Bindable var show: Show
    @Environment(\.modelContext) private var modelContext
    @Environment(GraphicsEngine.self) private var engine

    @State private var showingImportSheet = false
    @State private var showingFileImporter = false
    @State private var importText = ""
    @State private var importError: String?

    var body: some View {
        List {
            // Show metadata
            Section("Show Details") {
                TextField("Show Name", text: $show.name)
                TextField("ARC Number", text: Binding(
                    get: { show.arcNumber ?? "" },
                    set: { show.arcNumber = $0.isEmpty ? nil : $0 }
                ))
                DatePicker("Date", selection: $show.date, displayedComponents: .date)
                TextField("Venue", text: Binding(
                    get: { show.venue ?? "" },
                    set: { show.venue = $0.isEmpty ? nil : $0 }
                ))
                Picker("Default Animation", selection: $show.defaultAnimation) {
                    ForEach(AnimationPreset.allCases) { preset in
                        Label(preset.displayName, systemImage: preset.sfSymbol)
                            .tag(preset)
                    }
                }

                Picker("Key Mode", selection: $show.keyMode) {
                    ForEach(KeyMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.sfSymbol)
                            .tag(mode)
                    }
                }
                Text(show.keyMode.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Graphics list
            Section {
                if show.sortedGraphics.isEmpty {
                    ContentUnavailableView(
                        "No Graphics",
                        systemImage: "rectangle.stack",
                        description: Text("Add graphics for your lower thirds.")
                    )
                } else {
                    ForEach(Array(show.sortedGraphics.enumerated()), id: \.element.id) { index, graphic in
                        NavigationLink {
                            GraphicEditorView(graphic: graphic, defaultAnimation: show.defaultAnimation)
                        } label: {
                            GraphicRowView(graphic: graphic, index: index)
                        }
                    }
                    .onDelete(perform: deleteGraphics)
                    .onMove(perform: moveGraphics)
                }
            } header: {
                HStack {
                    Text("Graphics (\(show.graphics.count))")
                    Spacer()
                    Button {
                        addGraphic()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }

            // Notes
            Section("Notes") {
                TextField("Show notes", text: Binding(
                    get: { show.notes ?? "" },
                    set: { show.notes = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                .lineLimit(3...8)
            }
        }
        .navigationTitle(show.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button {
                        addGraphic()
                    } label: {
                        Label("Add Graphic", systemImage: "plus")
                    }

                    Button {
                        showingImportSheet = true
                    } label: {
                        Label("Paste Text", systemImage: "doc.text")
                    }

                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("Import from File", systemImage: "doc.badge.plus")
                    }

                    Divider()

                    NavigationLink {
                        OperatorRunView()
                            .onAppear { engine.loadShow(show) }
                    } label: {
                        Label("Run Show", systemImage: "play.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingImportSheet) {
            importSheet
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.plainText, .commaSeparatedText, .pdf]
                + [
                    UTType("org.openxmlformats.wordprocessingml.document"),
                    UTType("org.openxmlformats.spreadsheetml.sheet"),
                    UTType("com.microsoft.word.doc"),
                    UTType("com.microsoft.excel.xls")
                ].compactMap { $0 },
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert("Import Error", isPresented: .init(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onChange(of: show.name) { _, _ in show.updatedAt = .now }
    }

    // MARK: - Actions

    private func addGraphic() {
        let nextOrder = (show.graphics.map(\.sortOrder).max() ?? -1) + 1
        let graphic = Graphic(
            line1: "New Speaker",
            animationPreset: show.defaultAnimation,
            sortOrder: nextOrder
        )
        graphic.show = show
        show.graphics.append(graphic)
        modelContext.insert(graphic)
        show.updatedAt = .now
    }

    private func deleteGraphics(at offsets: IndexSet) {
        let sorted = show.sortedGraphics
        for index in offsets {
            let graphic = sorted[index]
            show.graphics.removeAll { $0.id == graphic.id }
            modelContext.delete(graphic)
        }
        reindex()
        show.updatedAt = .now
    }

    private func moveGraphics(from source: IndexSet, to destination: Int) {
        var sorted = show.sortedGraphics
        sorted.move(fromOffsets: source, toOffset: destination)
        for (i, graphic) in sorted.enumerated() {
            graphic.sortOrder = i
        }
        show.updatedAt = .now
    }

    private func reindex() {
        for (i, graphic) in show.sortedGraphics.enumerated() {
            graphic.sortOrder = i
        }
    }

    // MARK: - Import Sheet

    private var importSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste tab-separated or line-separated text.\nFormat: Line1 [TAB] Line2 [TAB] Line3")
                    .font(ARCTheme.caption)
                    .foregroundStyle(ARCTheme.textSecondary)

                TextEditor(text: $importText)
                    .font(.system(size: 14, design: .monospaced))
                    .frame(minHeight: 200)
                    .border(ARCTheme.divider)
            }
            .padding()
            .navigationTitle("Import Graphics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingImportSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        importParsedGraphics(GraphicsTextParser.parse(importText))
                        importText = ""
                        showingImportSheet = false
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - File Import

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let ext = url.pathExtension.lowercased()
            let fileData = try Data(contentsOf: url)

            switch ext {
            case "docx", "doc":
                guard let text = DocumentParser.extractTextFromDOCX(fileData),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    importError = "Could not extract text from \(url.lastPathComponent).\n\nTry pasting the text instead."
                    return
                }
                importParsedGraphics(GraphicsTextParser.parse(text))

            case "xlsx", "xls":
                guard let rows = DocumentParser.extractRowsFromXLSX(fileData), !rows.isEmpty else {
                    importError = "Could not read spreadsheet data from \(url.lastPathComponent)."
                    return
                }
                importSpreadsheetRows(rows)

            case "pdf":
                #if os(macOS)
                guard let pdfDoc = PDFDocument(data: fileData) else {
                    importError = "Could not open PDF.\n\nTry pasting the text instead."
                    return
                }
                var extracted = ""
                for i in 0..<pdfDoc.pageCount {
                    if let pageText = pdfDoc.page(at: i)?.string {
                        extracted += pageText + "\n"
                    }
                }
                guard !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    importError = "PDF appears to have no extractable text."
                    return
                }
                importParsedGraphics(GraphicsTextParser.parse(extracted))
                #else
                importError = "PDF import is not supported on this platform."
                #endif

            default:
                // Plain text / CSV
                guard let text = String(data: fileData, encoding: .utf8),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    importError = "File appears empty or could not be read as text."
                    return
                }
                importParsedGraphics(GraphicsTextParser.parse(text))
            }
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }

    /// Add parsed graphics to the show
    private func importParsedGraphics(_ parsed: [GraphicsTextParser.ParsedGraphic]) {
        guard !parsed.isEmpty else {
            importError = "No graphics found in the imported data."
            return
        }
        let startOrder = (show.graphics.map(\.sortOrder).max() ?? -1) + 1
        for (i, entry) in parsed.enumerated() {
            let graphic = Graphic(
                line1: entry.line1,
                line2: entry.line2,
                line3: entry.line3,
                animationPreset: show.defaultAnimation,
                sortOrder: startOrder + i
            )
            graphic.show = show
            show.graphics.append(graphic)
            modelContext.insert(graphic)
        }
        show.updatedAt = .now
    }

    /// Map spreadsheet rows to graphics. Auto-detects columns by header.
    /// Supported headers: name/line1, title/line2, organization/line3
    private func importSpreadsheetRows(_ rows: [[String]]) {
        guard !rows.isEmpty else { return }

        let firstRow = rows[0].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        let headerKeywords = Set(["name", "line1", "line 1", "title", "line2", "line 2",
                                   "organization", "org", "line3", "line 3", "speaker",
                                   "first name", "last name"])
        let hasHeader = firstRow.contains { headerKeywords.contains($0) }

        var line1Col = 0, line2Col = -1, line3Col = -1

        if hasHeader {
            for (i, header) in firstRow.enumerated() {
                switch header {
                case "name", "line1", "line 1", "speaker", "full name":
                    line1Col = i
                case "title", "line2", "line 2", "role", "position":
                    line2Col = i
                case "organization", "org", "company", "line3", "line 3", "affiliation":
                    line3Col = i
                case "first name":
                    line1Col = i // will be combined if "last name" follows
                default: break
                }
            }
            // If only 1 column detected and rows have multiple columns, assume sequential
            if line2Col < 0 && firstRow.count > 1 {
                line2Col = line1Col + 1 < firstRow.count ? line1Col + 1 : -1
            }
            if line3Col < 0 && firstRow.count > 2 {
                line3Col = line1Col + 2 < firstRow.count ? line1Col + 2 : -1
            }
        } else {
            // No header: col 0=name, col 1=title, col 2=org
            if firstRow.count > 1 { line2Col = 1 }
            if firstRow.count > 2 { line3Col = 2 }
        }

        let dataRows = hasHeader ? Array(rows.dropFirst()) : rows
        var parsed: [GraphicsTextParser.ParsedGraphic] = []

        for row in dataRows {
            let name = safeCol(row, line1Col)
            guard !name.isEmpty else { continue }
            let title = line2Col >= 0 ? safeCol(row, line2Col) : nil
            let org = line3Col >= 0 ? safeCol(row, line3Col) : nil
            parsed.append(GraphicsTextParser.ParsedGraphic(
                line1: name,
                line2: title?.isEmpty == true ? nil : title,
                line3: org?.isEmpty == true ? nil : org
            ))
        }

        importParsedGraphics(parsed)
    }

    private func safeCol(_ row: [String], _ index: Int) -> String {
        guard index >= 0, index < row.count else { return "" }
        return row[index].trimmingCharacters(in: .whitespaces)
    }
}
