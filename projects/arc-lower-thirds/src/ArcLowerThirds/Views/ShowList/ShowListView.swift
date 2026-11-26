//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import SwiftData

/// Root view — list of all shows with create/edit/delete/duplicate/run.
struct ShowListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(GraphicsEngine.self) private var engine
    @Query(sort: \Show.updatedAt, order: .reverse) private var shows: [Show]

    @State private var showingNewShow = false
    @State private var selectedShow: Show?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedShow) {
                if shows.isEmpty {
                    ContentUnavailableView(
                        "No Shows",
                        systemImage: "tv.slash",
                        description: Text("Create a show to get started with lower thirds.")
                    )
                } else {
                    ForEach(shows) { show in
                        NavigationLink(value: show) {
                            showRow(show)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteShow(show)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                duplicateShow(show)
                            } label: {
                                Label("Duplicate", systemImage: "doc.on.doc")
                            }
                            .tint(ARCTheme.accent)
                        }
                    }
                }
            }
            .navigationTitle("ARC Lower Thirds")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        createNewShow()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        } detail: {
            if let selectedShow {
                ShowEditorView(show: selectedShow)
            } else {
                ContentUnavailableView(
                    "Select a Show",
                    systemImage: "tv",
                    description: Text("Choose a show from the sidebar to edit graphics.")
                )
            }
        }
    }

    // MARK: - Show Row

    private func showRow(_ show: Show) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(show.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ARCTheme.textPrimary)

                if let arcNumber = show.arcNumber, !arcNumber.isEmpty {
                    Text(arcNumber)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(ARCTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ARCTheme.accent.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            HStack(spacing: 12) {
                if let venue = show.venue, !venue.isEmpty {
                    Label(venue, systemImage: "mappin")
                        .font(ARCTheme.caption)
                        .foregroundStyle(ARCTheme.textSecondary)
                }

                Label("\(show.graphicCount) graphics", systemImage: "rectangle.stack")
                    .font(ARCTheme.caption)
                    .foregroundStyle(ARCTheme.textTertiary)

                Text(show.date, style: .date)
                    .font(ARCTheme.caption)
                    .foregroundStyle(ARCTheme.textTertiary)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                engine.loadShow(show)
            } label: {
                Label("Run Show", systemImage: "play.fill")
            }

            Button {
                duplicateShow(show)
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                deleteShow(show)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func createNewShow() {
        let show = Show(name: "New Show")
        modelContext.insert(show)
        try? modelContext.save()
        selectedShow = show
    }

    private func duplicateShow(_ show: Show) {
        let copy = show.deepCopy()
        modelContext.insert(copy)
        for graphic in copy.graphics {
            modelContext.insert(graphic)
        }
        try? modelContext.save()
    }

    private func deleteShow(_ show: Show) {
        if selectedShow?.id == show.id {
            selectedShow = nil
        }
        modelContext.delete(show)
        try? modelContext.save()
    }
}
