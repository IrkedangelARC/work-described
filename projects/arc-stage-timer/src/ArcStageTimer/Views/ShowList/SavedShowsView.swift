//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import SwiftData

struct SavedShowsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var savedShows: [SavedShowInfo] = []
    @State private var loadError: String?
    @State private var loadedShowName: String?
    var onLoad: (Show) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                ARCTheme.background.ignoresSafeArea()

                if savedShows.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "folder")
                            .font(.system(size: 40, weight: .ultraLight))
                            .foregroundStyle(ARCTheme.textTertiary)
                        Text("No Saved Shows")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(ARCTheme.textSecondary)
                        Text("Save a show from the context menu to store it here")
                            .font(.system(size: 13))
                            .foregroundStyle(ARCTheme.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(savedShows) { info in
                            savedShowRow(info)
                                .listRowBackground(ARCTheme.surface)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        deleteShow(info)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        loadShow(info)
                                    } label: {
                                        Label("Load", systemImage: "square.and.arrow.down")
                                    }
                                    .tint(ARCTheme.accent)
                                }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Saved Shows")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Load Error", isPresented: .init(
                get: { loadError != nil },
                set: { if !$0 { loadError = nil } }
            )) {
                Button("OK") { loadError = nil }
            } message: {
                Text(loadError ?? "")
            }
            .alert("Show Loaded", isPresented: .init(
                get: { loadedShowName != nil },
                set: { if !$0 { loadedShowName = nil } }
            )) {
                Button("OK") {
                    loadedShowName = nil
                    dismiss()
                }
            } message: {
                Text("\"\(loadedShowName ?? "")\" has been loaded into your shows.")
            }
        }
        .onAppear {
            refresh()
        }
    }

    private func savedShowRow(_ info: SavedShowInfo) -> some View {
        Button {
            loadShow(info)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        if let arc = info.arcNumber, !arc.isEmpty {
                            Text(arc)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(ARCTheme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ARCTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        }
                        Text(info.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(ARCTheme.textPrimary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 10) {
                        if let date = info.eventDate {
                            Label(date, systemImage: "calendar")
                                .font(.system(size: 12))
                                .foregroundStyle(ARCTheme.textSecondary)
                        }
                        if let venue = info.venue, !venue.isEmpty {
                            Label(venue, systemImage: "mappin")
                                .font(.system(size: 12))
                                .foregroundStyle(ARCTheme.textTertiary)
                                .lineLimit(1)
                        }
                    }

                    HStack(spacing: 10) {
                        Text("Saved \(info.formattedSavedDate)")
                            .font(.system(size: 11))
                            .foregroundStyle(ARCTheme.textTertiary)
                        Text(info.formattedFileSize)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(ARCTheme.textTertiary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(info.cueCount) cues")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(ARCTheme.textSecondary)
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 14))
                        .foregroundStyle(ARCTheme.accent)
                }
            }
            .padding(.vertical, 6)
        }
        .contextMenu {
            Button {
                loadShow(info)
            } label: {
                Label("Load into Shows", systemImage: "square.and.arrow.down")
            }
            Button(role: .destructive) {
                deleteShow(info)
            } label: {
                Label("Delete File", systemImage: "trash")
            }
        }
    }

    private func loadShow(_ info: SavedShowInfo) {
        do {
            let show = try ShowFileManager.load(from: info.url)
            modelContext.insert(show)
            for cue in show.cues {
                cue.show = show
                modelContext.insert(cue)
            }
            try? modelContext.save()
            onLoad(show)
            loadedShowName = show.name
        } catch {
            loadError = "Failed to load show: \(error.localizedDescription)"
        }
    }

    private func deleteShow(_ info: SavedShowInfo) {
        try? ShowFileManager.delete(at: info.url)
        refresh()
    }

    private func refresh() {
        savedShows = ShowFileManager.listSavedShows()
    }
}
