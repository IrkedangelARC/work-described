//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import SwiftData

/// Primary 3-column editor for a show.
/// Left: graphics sidebar. Center: canvas preview. Right: inspector panel.
struct MainEditorView: View {
    @Bindable var show: Show
    @Environment(\.modelContext) private var modelContext
    @Environment(GraphicsEngine.self) private var engine
    @Environment(\.openWindow) private var openWindow

    @State private var selectedGraphicID: UUID?
    @State private var selectedElement: CanvasElement?
    @State private var showingImportSheet = false
    @State private var showingDocImportSheet = false
    @State private var importText = ""
    @State private var showingRunView = false

    private var selectedGraphic: Graphic? {
        guard let id = selectedGraphicID else { return nil }
        return show.sortedGraphics.first { $0.id == id }
    }

    var body: some View {
        HSplitView {
            // Left sidebar — graphics list
            GraphicsSidebar(
                show: show,
                selectedID: $selectedGraphicID,
                onAdd: { type in addGraphic(type: type) },
                onDelete: deleteGraphic,
                onMove: moveGraphics
            )
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)

            // Center — canvas preview
            CanvasPreview(graphic: selectedGraphic, selectedElement: $selectedElement)
                .frame(minWidth: 400)

            // Right — inspector panel
            if let graphic = selectedGraphic {
                InspectorPanel(graphic: graphic, defaultTemplate: show.defaultTemplate, scrollToElement: selectedElement)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            } else {
                VStack {
                    Spacer()
                    Text("Select a graphic to edit")
                        .font(ARCTheme.bodyText)
                        .foregroundStyle(ARCTheme.textTertiary)
                    Spacer()
                }
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                .background(ARCTheme.surface)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                HStack(spacing: 8) {
                    if let arcNumber = show.arcNumber, !arcNumber.isEmpty {
                        Text(arcNumber)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(ARCTheme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ARCTheme.accent.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Text(show.name)
                        .font(.system(size: 16, weight: .semibold))
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button {
                        showingImportSheet = true
                    } label: {
                        Label("Import from Text...", systemImage: "text.alignleft")
                    }
                    Button {
                        showingDocImportSheet = true
                    } label: {
                        Label("Import from Document...", systemImage: "doc.richtext")
                    }
                } label: {
                    Label("Import", systemImage: "doc.text")
                }

                Menu {
                    ForEach(GraphicType.allCases) { type in
                        Button {
                            addGraphic(type: type)
                        } label: {
                            Label(type.displayName, systemImage: type.sfSymbol)
                        }
                    }
                } label: {
                    Label("Add Graphic", systemImage: "plus")
                }

                Divider()

                // Key mode picker — accessible from main editor
                Picker("Key Mode", selection: $show.keyMode) {
                    ForEach(KeyMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.sfSymbol)
                            .tag(mode)
                    }
                }
                .help(show.keyMode.description)

                Button {
                    engine.loadShow(show)
                    showingRunView = true
                } label: {
                    Label("Run Show", systemImage: "play.fill")
                }
                .tint(ARCTheme.readyGreen)
            }
        }
        .sheet(isPresented: $showingImportSheet) {
            importSheet
        }
        .sheet(isPresented: $showingDocImportSheet) {
            DocumentImportView(show: show)
        }
        .sheet(isPresented: $showingRunView) {
            OperatorRunView()
                .environment(engine)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .onAppear {
            // Auto-select first graphic
            if selectedGraphicID == nil, let first = show.sortedGraphics.first {
                selectedGraphicID = first.id
            }
        }
        .onChange(of: selectedGraphicID) {
            selectedElement = nil
        }
    }

    // MARK: - Actions

    private func addGraphic(type: GraphicType = .lowerThird) {
        let nextOrder = (show.graphics.map(\.sortOrder).max() ?? -1) + 1
        let defaultLine1: String
        let defaultFontSize: Double
        switch type {
        case .lowerThird: defaultLine1 = "New Speaker";   defaultFontSize = 48
        case .ticker:     defaultLine1 = "Breaking news"; defaultFontSize = 36
        case .logoBug:    defaultLine1 = "LOGO";          defaultFontSize = 24
        case .fullTitle:  defaultLine1 = "Title";         defaultFontSize = 72
        case .clock:      defaultLine1 = "Clock";         defaultFontSize = 36
        }
        let graphic = Graphic(
            line1: defaultLine1,
            animationPreset: type == .fullTitle ? show.defaultAnimation : .cut,
            sortOrder: nextOrder,
            template: show.defaultTemplate,
            line1FontSize: defaultFontSize,
            graphicType: type
        )
        graphic.show = show
        show.graphics.append(graphic)
        modelContext.insert(graphic)
        show.updatedAt = .now
        selectedGraphicID = graphic.id
    }

    private func deleteGraphic(_ graphic: Graphic) {
        if selectedGraphicID == graphic.id {
            // Select next or previous
            let sorted = show.sortedGraphics
            if let idx = sorted.firstIndex(where: { $0.id == graphic.id }) {
                if idx + 1 < sorted.count {
                    selectedGraphicID = sorted[idx + 1].id
                } else if idx > 0 {
                    selectedGraphicID = sorted[idx - 1].id
                } else {
                    selectedGraphicID = nil
                }
            }
        }
        show.graphics.removeAll { $0.id == graphic.id }
        modelContext.delete(graphic)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste tab-separated or line-separated text.\nFormat: Line1 [TAB] Line2 [TAB] Line3")
                .font(ARCTheme.caption)
                .foregroundStyle(ARCTheme.textSecondary)

            TextEditor(text: $importText)
                .font(.system(size: 14, design: .monospaced))
                .frame(minWidth: 500, minHeight: 200)
                .border(ARCTheme.divider)

            HStack {
                Spacer()
                Button("Cancel") { showingImportSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    let parsed = GraphicsTextParser.parse(importText)
                    let startOrder = (show.graphics.map(\.sortOrder).max() ?? -1) + 1
                    for (i, entry) in parsed.enumerated() {
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
                    importText = ""
                    showingImportSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 550)
    }
}
