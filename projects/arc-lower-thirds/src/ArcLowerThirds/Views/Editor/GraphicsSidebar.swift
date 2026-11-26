//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Left sidebar in the editor — scrollable list of graphics with selection, reorder, delete.
struct GraphicsSidebar: View {
    @Bindable var show: Show
    @Binding var selectedID: UUID?
    var onAdd: (GraphicType) -> Void
    var onDelete: (Graphic) -> Void
    var onMove: (IndexSet, Int) -> Void

    @Environment(GraphicsEngine.self) private var engine
    @State private var searchText = ""

    private var filteredGraphics: [Graphic] {
        let sorted = show.sortedGraphics
        guard !searchText.isEmpty else { return sorted }
        let query = searchText.lowercased()
        return sorted.filter {
            $0.line1.lowercased().contains(query) ||
            ($0.line2?.lowercased().contains(query) ?? false) ||
            ($0.line3?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(ARCTheme.accent)
                Text("GRAPHICS")
                    .font(ARCTheme.caption)
                    .foregroundStyle(ARCTheme.textSecondary)
                Spacer()
                Text("\(show.graphics.count)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(ARCTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()
                .background(ARCTheme.divider)

            // Search bar
            if show.graphics.count > 5 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(ARCTheme.textTertiary)
                        .font(.system(size: 12))
                    TextField("Filter", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(ARCTheme.textTertiary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(ARCTheme.background)
            }

            // Graphics list
            if show.sortedGraphics.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 28))
                        .foregroundStyle(ARCTheme.textTertiary)
                    Text("No Graphics")
                        .font(ARCTheme.bodyText)
                        .foregroundStyle(ARCTheme.textTertiary)
                    Button("Add Graphic") { onAdd(.lowerThird) }
                        .buttonStyle(.bordered)
                        .tint(ARCTheme.accent)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(Array(filteredGraphics.enumerated()), id: \.element.id) { index, graphic in
                        sidebarRow(graphic: graphic, index: index)
                            .tag(graphic.id)
                            .contextMenu {
                                Button {
                                    engine.copyStyle(from: graphic)
                                } label: {
                                    Label("Copy Style", systemImage: "paintbrush")
                                }
                                Button {
                                    engine.pasteStyle(to: graphic)
                                } label: {
                                    Label("Paste Style", systemImage: "paintbrush.fill")
                                }
                                .disabled(!engine.hasClipboardStyle)
                                Divider()
                                Button {
                                    duplicateGraphic(graphic)
                                } label: {
                                    Label("Duplicate", systemImage: "doc.on.doc")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    onDelete(graphic)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { offsets in
                        let sorted = show.sortedGraphics
                        for index in offsets {
                            onDelete(sorted[index])
                        }
                    }
                    .onMove(perform: onMove)
                }
                .listStyle(.sidebar)
            }

            Divider()
                .background(ARCTheme.divider)

            // Footer: add button
            HStack {
                Menu {
                    ForEach(GraphicType.allCases) { type in
                        Button {
                            onAdd(type)
                        } label: {
                            Label(type.displayName, systemImage: type.sfSymbol)
                        }
                    }
                } label: {
                    Label("Add Graphic", systemImage: "plus")
                        .font(ARCTheme.caption)
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(ARCTheme.accent)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(ARCTheme.surface)
    }

    // MARK: - Row

    private func sidebarRow(graphic: Graphic, index: Int) -> some View {
        HStack(spacing: 8) {
            // Index badge
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(ARCTheme.textSecondary)
                .frame(width: 22, height: 22)
                .background(ARCTheme.surfaceLight)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Accent dot (with legibility warning)
            ZStack {
                Circle()
                    .fill(ARCTheme.color(from: graphic.accentColor))
                    .frame(width: 8, height: 8)
                if graphic.hasLegibilityWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                        .offset(x: 8, y: -6)
                }
            }

            // Text
            VStack(alignment: .leading, spacing: 1) {
                Text(graphic.line1)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ARCTheme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    // Type indicator
                    if graphic.graphicType != .lowerThird {
                        Image(systemName: graphic.graphicType.sfSymbol)
                            .font(.system(size: 9))
                            .foregroundStyle(ARCTheme.accent)
                    }

                    if let line2 = graphic.line2, !line2.isEmpty {
                        Text(line2)
                            .font(.system(size: 11))
                            .foregroundStyle(ARCTheme.textSecondary)
                            .lineLimit(1)
                    }

                    // Template indicator (lower thirds only)
                    if graphic.graphicType == .lowerThird {
                        Image(systemName: graphic.template.sfSymbol)
                            .font(.system(size: 9))
                            .foregroundStyle(ARCTheme.textTertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Duplicate

    private func duplicateGraphic(_ source: Graphic) {
        let nextOrder = (show.graphics.map(\.sortOrder).max() ?? -1) + 1
        let copy = Graphic(
            line1: source.line1,
            line2: source.line2,
            line3: source.line3,
            animationPreset: source.animationPreset,
            accentColor: source.accentColor,
            sortOrder: nextOrder,
            notes: source.notes,
            template: source.template,
            positionPreset: source.positionPreset,
            fontFamily: source.fontFamily,
            line1FontSize: source.line1FontSize,
            line2FontSize: source.line2FontSize,
            line3FontSize: source.line3FontSize,
            backgroundOpacity: source.backgroundOpacity
        )
        copy.show = show
        show.graphics.append(copy)
        selectedID = copy.id
    }
}
