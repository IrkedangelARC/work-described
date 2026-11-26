//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Center panel showing the active source state and quick-switch grid.
struct PreviewPanel: View {
    let selectedSourceId: String?
    @Environment(SwitcherEngine.self) private var engine

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 8)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Active source banner
            if engine.isBlack {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "rectangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(ARCTheme.liveRed)
                    Text("BLACK")
                        .font(.system(size: 36, weight: .black, design: .monospaced))
                        .foregroundStyle(ARCTheme.liveRed)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let source = engine.activeSource {
                VStack(spacing: 8) {
                    Spacer()
                    if let icon = source.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                    Text(source.friendlyName)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(ARCTheme.textPrimary)
                    Text("PROGRAM")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(ARCTheme.liveRed)
                        .tracking(2)

                    // Hotkey reference for active source
                    hotkeyReference(for: source)

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundStyle(ARCTheme.textTertiary)
                    Text("No active source")
                        .font(ARCTheme.bodyText)
                        .foregroundStyle(ARCTheme.textTertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().background(ARCTheme.divider)

            // Quick-switch grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(engine.sources.enumerated()), id: \.element.id) { index, source in
                        Button {
                            engine.switchTo(sourceId: source.id)
                        } label: {
                            VStack(spacing: 4) {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(ARCTheme.textTertiary)
                                Text(source.friendlyName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(source.id == engine.activeSourceId ? .white : ARCTheme.textPrimary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                source.id == engine.activeSourceId
                                    ? ARCTheme.liveRed
                                    : source.isAvailable
                                        ? ARCTheme.surface
                                        : ARCTheme.surface.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        source.id == engine.activeSourceId
                                            ? ARCTheme.liveRed
                                            : ARCTheme.divider,
                                        lineWidth: source.id == engine.activeSourceId ? 2 : 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!source.isAvailable)
                    }
                }
                .padding(12)
            }
            .frame(height: 140)
        }
        .background(ARCTheme.background)
    }

    @ViewBuilder
    private func hotkeyReference(for source: Source) -> some View {
        let profile = ProfileRegistry.profile(for: source.bundleIdentifier)
        let labels = profile.hotkeyLabels
        if !labels.isEmpty {
            VStack(spacing: 2) {
                Text(profile.displayName.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(ARCTheme.textTertiary)
                    .tracking(1)
                    .padding(.bottom, 2)

                let ordered: [AppCommand] = [.startPresentation, .stopPresentation, .nextSlide, .previousSlide, .play, .pause, .stop]
                ForEach(ordered.filter { labels[$0] != nil }, id: \.self) { cmd in
                    HStack {
                        Text(cmd.displayName)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(ARCTheme.textSecondary)
                        Spacer()
                        Text(labels[cmd]!)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ARCTheme.accent)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
    }
}
