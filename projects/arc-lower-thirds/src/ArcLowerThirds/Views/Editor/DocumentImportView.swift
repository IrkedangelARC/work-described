//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Import graphics from DOCX or XLSX files.
/// DOCX: each paragraph becomes a graphic (tab-separated for multi-line).
/// XLSX: each row becomes a graphic; user picks which columns map to line1/2/3.
struct DocumentImportView: View {
    @Bindable var show: Show
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [ImportEntry] = []
    @State private var errorMessage: String?
    @State private var sourceFileName = ""

    // XLSX column mapping
    @State private var rawRows: [[String]] = []
    @State private var columnCount = 0
    @State private var line1Column = 0
    @State private var line2Column = 1
    @State private var line3Column = 2
    @State private var skipHeader = true
    @State private var isXLSX = false

    struct ImportEntry: Identifiable {
        let id = UUID()
        var line1: String
        var line2: String?
        var line3: String?
        var selected = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(ARCTheme.accent)
                Text("IMPORT FROM DOCUMENT")
                    .font(ARCTheme.caption)
                    .foregroundStyle(ARCTheme.textSecondary)
                Spacer()
                if !sourceFileName.isEmpty {
                    Text(sourceFileName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ARCTheme.textTertiary)
                }
            }

            if entries.isEmpty && errorMessage == nil {
                // File picker phase
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "doc.badge.arrow.up")
                        .font(.system(size: 48))
                        .foregroundStyle(ARCTheme.textTertiary)
                    Text("Select a .docx or .xlsx file to import speaker names and titles")
                        .font(ARCTheme.bodyText)
                        .foregroundStyle(ARCTheme.textSecondary)
                    Button("Choose File...") { pickFile() }
                        .buttonStyle(.borderedProminent)
                        .tint(ARCTheme.accent)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.red)
                    Text(error)
                        .font(ARCTheme.bodyText)
                        .foregroundStyle(ARCTheme.textSecondary)
                    Button("Try Another File") {
                        errorMessage = nil
                        entries = []
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // XLSX column mapping
                if isXLSX && columnCount > 1 {
                    HStack(spacing: 16) {
                        columnPicker("Line 1 (Name)", selection: $line1Column)
                        if columnCount > 1 {
                            columnPicker("Line 2 (Title)", selection: $line2Column)
                        }
                        if columnCount > 2 {
                            columnPicker("Line 3", selection: $line3Column)
                        }
                        Toggle("Skip header row", isOn: $skipHeader)
                            .controlSize(.small)
                            .font(.system(size: 11))
                    }
                    .onChange(of: line1Column) { rebuildEntries() }
                    .onChange(of: line2Column) { rebuildEntries() }
                    .onChange(of: line3Column) { rebuildEntries() }
                    .onChange(of: skipHeader) { rebuildEntries() }
                }

                // Preview table
                List {
                    ForEach($entries) { $entry in
                        HStack(spacing: 8) {
                            Toggle("", isOn: $entry.selected)
                                .labelsHidden()
                                .controlSize(.small)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.line1)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(ARCTheme.textPrimary)
                                if let l2 = entry.line2, !l2.isEmpty {
                                    Text(l2)
                                        .font(.system(size: 11))
                                        .foregroundStyle(ARCTheme.textSecondary)
                                }
                                if let l3 = entry.line3, !l3.isEmpty {
                                    Text(l3)
                                        .font(.system(size: 10))
                                        .foregroundStyle(ARCTheme.textTertiary)
                                }
                            }
                            Spacer()
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 200)

                Text("\(entries.filter(\.selected).count) of \(entries.count) entries selected")
                    .font(.system(size: 11))
                    .foregroundStyle(ARCTheme.textTertiary)
            }

            // Footer
            HStack {
                if !entries.isEmpty {
                    Button("Select All") { entries.indices.forEach { entries[$0].selected = true } }
                        .controlSize(.small)
                    Button("Select None") { entries.indices.forEach { entries[$0].selected = false } }
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !entries.isEmpty {
                    Button("Import \(entries.filter(\.selected).count) Graphics") {
                        importSelected()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ARCTheme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(entries.filter(\.selected).isEmpty)
                }
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
    }

    // MARK: - Column Picker

    private func columnPicker(_ label: String, selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ARCTheme.textTertiary)
            Picker("", selection: selection) {
                ForEach(0..<columnCount, id: \.self) { i in
                    Text(columnLetter(i)).tag(i)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private func columnLetter(_ index: Int) -> String {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        guard index < letters.count else { return "Col \(index + 1)" }
        return String(letters[letters.index(letters.startIndex, offsetBy: index)])
    }

    // MARK: - File Picker

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "xlsx") ?? .data,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        sourceFileName = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Could not read file"
            return
        }

        let ext = url.pathExtension.lowercased()
        if ext == "xlsx" {
            isXLSX = true
            guard let rows = DocumentParser.extractRowsFromXLSX(data), !rows.isEmpty else {
                errorMessage = "No data found in spreadsheet"
                return
            }
            rawRows = rows
            columnCount = rows.map(\.count).max() ?? 0
            line1Column = 0
            line2Column = min(1, columnCount - 1)
            line3Column = min(2, columnCount - 1)
            rebuildEntries()
        } else {
            isXLSX = false
            guard let text = DocumentParser.extractTextFromDOCX(data) else {
                errorMessage = "No text found in document"
                return
            }
            let parsed = GraphicsTextParser.parse(text)
            entries = parsed.map { ImportEntry(line1: $0.line1, line2: $0.line2, line3: $0.line3) }
        }
    }

    // MARK: - XLSX Rebuild

    private func rebuildEntries() {
        let startRow = skipHeader ? 1 : 0
        guard startRow < rawRows.count else { entries = []; return }

        entries = rawRows[startRow...].compactMap { row in
            let l1 = line1Column < row.count ? row[line1Column] : ""
            guard !l1.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let l2 = line2Column < row.count ? row[line2Column] : nil
            let l3 = line3Column < row.count ? row[line3Column] : nil
            return ImportEntry(
                line1: l1.trimmingCharacters(in: .whitespaces),
                line2: l2?.trimmingCharacters(in: .whitespaces),
                line3: l3?.trimmingCharacters(in: .whitespaces)
            )
        }
    }

    // MARK: - Import

    private func importSelected() {
        let selected = entries.filter(\.selected)
        let startOrder = (show.graphics.map(\.sortOrder).max() ?? -1) + 1
        for (i, entry) in selected.enumerated() {
            let graphic = Graphic(
                line1: entry.line1,
                line2: entry.line2,
                line3: entry.line3,
                animationPreset: show.defaultAnimation,
                sortOrder: startOrder + i,
                template: show.defaultTemplate
            )
            graphic.show = show
            show.graphics.append(graphic)
            modelContext.insert(graphic)
        }
        show.updatedAt = .now
        dismiss()
    }
}
