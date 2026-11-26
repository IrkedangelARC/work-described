//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Sidebar showing registered sources with live/offline status.
struct SourceListView: View {
    @Environment(SwitcherEngine.self) private var engine
    @Binding var selectedId: String?
    let onShowAppPicker: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("SOURCES")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(ARCTheme.textTertiary)
                    .tracking(1)
                Spacer()
                Button(action: onShowAppPicker) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(ARCTheme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().background(ARCTheme.divider)

            if engine.sources.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.system(size: 28))
                        .foregroundStyle(ARCTheme.textTertiary)
                    Text("No sources registered")
                        .font(.system(size: 12))
                        .foregroundStyle(ARCTheme.textTertiary)
                    Button("Add Source") { onShowAppPicker() }
                        .font(.system(size: 12))
                }
                Spacer()
            } else {
                List(selection: $selectedId) {
                    ForEach(engine.sources) { source in
                        SourceRowView(source: source, isActive: source.id == engine.activeSourceId)
                            .tag(source.id)
                            .contextMenu {
                                if source.isAvailable {
                                    Button("Switch Live") {
                                        engine.switchTo(sourceId: source.id)
                                    }

                                    let profile = ProfileRegistry.profile(for: source.bundleIdentifier)
                                    if profile.supportedCommands.contains(.startPresentation) {
                                        Button("Start Presentation") {
                                            engine.sendCommand(.startPresentation, toSourceId: source.id)
                                        }
                                        Button("Stop Presentation") {
                                            engine.sendCommand(.stopPresentation, toSourceId: source.id)
                                        }
                                    }

                                    Divider()
                                }

                                Button("Remove", role: .destructive) {
                                    engine.unregisterSource(id: source.id)
                                }
                            }
                            .listRowBackground(
                                source.id == selectedId
                                    ? ARCTheme.surfaceLight
                                    : source.id == engine.activeSourceId
                                        ? ARCTheme.liveRed.opacity(0.15)
                                        : Color.clear
                            )
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            engine.unregisterSource(id: engine.sources[i].id)
                        }
                    }
                    .onMove { source, dest in
                        engine.moveSources(from: source, to: dest)
                    }
                }
                .scrollContentBackground(.hidden)
            }

            Divider().background(ARCTheme.divider)

            VStack(spacing: 8) {
                // Show mode toggle
                Button {
                    if engine.isInShowMode { engine.exitShowMode() } else { engine.enterShowMode() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "display")
                        Text(engine.isInShowMode ? "EXIT SHOW MODE" : "ENTER SHOW MODE")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(engine.isInShowMode ? ARCTheme.accent : ARCTheme.textTertiary, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(engine.outputMonitorIndex == nil)

                // Black button
                Button {
                    if engine.isBlack { engine.cutFromBlack() } else { engine.cutToBlack() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: engine.isBlack ? "rectangle.fill" : "rectangle")
                        Text(engine.isBlack ? "BLACK LIVE" : "CUT TO BLACK")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(engine.isBlack ? ARCTheme.liveRed : ARCTheme.textTertiary, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
        .background(ARCTheme.surface)
    }
}
