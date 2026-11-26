//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import SwiftData

/// Root view — show list in sidebar, main editor in detail.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(ExternalDisplayManager.self) private var displayManager
    @Query(sort: \Show.updatedAt, order: .reverse) private var shows: [Show]

    @State private var selectedShow: Show?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedShow) {
                if shows.isEmpty {
                    ContentUnavailableView(
                        "No Shows",
                        systemImage: "tv.slash",
                        description: Text("Create a show to get started.")
                    )
                } else {
                    ForEach(shows) { show in
                        NavigationLink(value: show) {
                            showRow(show)
                        }
                        .contextMenu {
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
                }
            }
            .navigationTitle("Shows")
            .navigationSubtitle("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
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
                MainEditorView(show: selectedShow)
            } else {
                ContentUnavailableView(
                    "Select a Show",
                    systemImage: "tv",
                    description: Text("Choose a show from the sidebar to edit graphics.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onReceive(NotificationCenter.default.publisher(for: .openStageWindow)) { _ in
            openWindow(id: "stage-output")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                displayManager.openOnExternalScreen()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openKeyWindow)) { _ in
            openWindow(id: "key-output")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                displayManager.openKeyOnExternalScreen()
            }
        }
    }

    // MARK: - Show Row

    private func showRow(_ show: Show) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(show.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ARCTheme.textPrimary)

                if let arcNumber = show.arcNumber, !arcNumber.isEmpty {
                    Text(arcNumber)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(ARCTheme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(ARCTheme.accent.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }

            HStack(spacing: 10) {
                if let venue = show.venue, !venue.isEmpty {
                    Label(venue, systemImage: "mappin")
                        .font(.system(size: 11))
                        .foregroundStyle(ARCTheme.textSecondary)
                }

                Label("\(show.graphicCount)", systemImage: "rectangle.stack")
                    .font(.system(size: 11))
                    .foregroundStyle(ARCTheme.textTertiary)

                Text(show.date, style: .date)
                    .font(.system(size: 11))
                    .foregroundStyle(ARCTheme.textTertiary)
            }
        }
        .padding(.vertical, 3)
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
