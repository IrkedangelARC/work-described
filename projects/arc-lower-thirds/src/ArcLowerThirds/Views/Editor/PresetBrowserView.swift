//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Grid-based preset browser with search, preview, apply, and management.
/// Opened from the PRESETS section in the inspector panel.
struct PresetBrowserView: View {
    let graphic: Graphic
    @Environment(PresetManager.self) private var presetManager
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var showSaveSheet = false
    @State private var presetName = ""
    @State private var presetToDelete: DesignPreset?
    @State private var showDeleteConfirm = false

    private var filteredPresets: [DesignPreset] {
        presetManager.search(searchText)
    }

    private var groupedPresets: [(String, [DesignPreset])] {
        let grouped = Dictionary(grouping: filteredPresets) {
            GraphicTemplate(rawValue: $0.template)?.displayName ?? $0.template
        }
        return grouped.sorted { $0.key < $1.key }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(ARCTheme.accent)
                Text("PRESET BROWSER")
                    .font(ARCTheme.caption)
                    .foregroundStyle(ARCTheme.textSecondary)
                Spacer()
                Text("\(filteredPresets.count) presets")
                    .font(.system(size: 11))
                    .foregroundStyle(ARCTheme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Search + Save bar
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(ARCTheme.textTertiary)
                    TextField("Search presets...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(ARCTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Button {
                    presetName = "\(graphic.template.displayName) — \(graphic.line1)"
                    showSaveSheet = true
                } label: {
                    Label("Save Current", systemImage: "plus.square")
                        .font(.system(size: 11, weight: .medium))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(ARCTheme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Grid body
            if filteredPresets.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(ARCTheme.textTertiary)
                    if searchText.isEmpty {
                        Text("No presets saved yet")
                            .font(ARCTheme.bodyText)
                            .foregroundStyle(ARCTheme.textSecondary)
                        Text("Save your current graphic's design as a preset to reuse it later")
                            .font(.system(size: 11))
                            .foregroundStyle(ARCTheme.textTertiary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("No presets matching \"\(searchText)\"")
                            .font(ARCTheme.bodyText)
                            .foregroundStyle(ARCTheme.textSecondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(groupedPresets, id: \.0) { templateName, presets in
                            Section {
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(presets) { preset in
                                        presetCard(preset)
                                    }
                                }
                            } header: {
                                Text(templateName)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(ARCTheme.textTertiary)
                                    .padding(.leading, 4)
                            }
                        }
                    }
                    .padding(16)
                }
            }

            Divider()

            // Footer
            HStack {
                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    if panel.runModal() == .OK, let url = panel.url {
                        presetManager.importPresets(from: url)
                    }
                } label: {
                    Label("Import File...", systemImage: "square.and.arrow.down")
                        .font(.system(size: 11))
                }
                .controlSize(.small)

                if !presetManager.presets.isEmpty {
                    Button {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        encoder.dateEncodingStrategy = .iso8601
                        guard let data = try? encoder.encode(presetManager.presets) else { return }
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [.json]
                        panel.nameFieldStringValue = "ARC_Presets.json"
                        if panel.runModal() == .OK, let url = panel.url {
                            try? data.write(to: url)
                        }
                    } label: {
                        Label("Export All", systemImage: "square.and.arrow.up")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                }

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(ARCTheme.background)
        .alert("Save Preset", isPresented: $showSaveSheet) {
            TextField("Preset name", text: $presetName)
            Button("Save") {
                let preset = DesignPreset.from(graphic, name: presetName)
                presetManager.save(preset)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Name this design preset:")
        }
        .alert("Delete Preset?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let preset = presetToDelete {
                    presetManager.delete(preset)
                }
            }
            Button("Cancel", role: .cancel) { presetToDelete = nil }
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - Preset Card

    private func presetCard(_ preset: DesignPreset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Color preview bar (shows accent + background colors)
            HStack(spacing: 0) {
                ARCTheme.color(from: preset.accentColor)
                    .frame(width: 40)
                (preset.titleBgColor.map { ARCTheme.color(from: $0) } ?? Color.black.opacity(0.8))
            }
            .frame(height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Name + template
            Text(preset.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ARCTheme.textPrimary)
                .lineLimit(1)

            Text(GraphicTemplate(rawValue: preset.template)?.displayName ?? preset.template)
                .font(.system(size: 9))
                .foregroundStyle(ARCTheme.textTertiary)

            Text(preset.createdAt, style: .date)
                .font(.system(size: 9))
                .foregroundStyle(ARCTheme.textTertiary)
        }
        .padding(8)
        .background(ARCTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ARCTheme.divider, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double-click: apply + close
            presetManager.apply(preset, to: graphic)
            dismiss()
        }
        .onTapGesture(count: 1) {
            // Single-click: apply (stay open for browsing)
            presetManager.apply(preset, to: graphic)
        }
        .contextMenu {
            Button("Apply to Graphic") {
                presetManager.apply(preset, to: graphic)
            }
            Button("Duplicate") {
                presetManager.duplicate(preset)
            }
            Divider()
            Button("Delete", role: .destructive) {
                presetToDelete = preset
                showDeleteConfirm = true
            }
        }
    }
}
