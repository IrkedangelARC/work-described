//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Right panel: app-specific commands for the selected source.
struct InspectorView: View {
    let sourceId: String
    @Environment(SwitcherEngine.self) private var engine

    private var source: Source? {
        engine.sources.first { $0.id == sourceId }
    }

    private var commands: Set<AppCommand> {
        engine.supportedCommands(for: sourceId)
    }

    private var profile: any AppProfile {
        guard let source else { return GenericProfile(bundleIdentifier: "", displayName: "Unknown") }
        return ProfileRegistry.profile(for: source.bundleIdentifier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("CONTROLS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(ARCTheme.textTertiary)
                    .tracking(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().background(ARCTheme.divider)

            if let source {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Source info
                        HStack(spacing: 10) {
                            if let icon = source.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 32, height: 32)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.friendlyName)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(ARCTheme.textPrimary)
                                Text(profile.displayName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(ARCTheme.textTertiary)
                            }
                        }

                        // Switch button
                        if source.id != engine.activeSourceId {
                            Button {
                                engine.switchTo(sourceId: source.id)
                            } label: {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text("SWITCH LIVE")
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(ARCTheme.liveRed, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .disabled(!source.isAvailable)
                        }

                        // Slide commands
                        if !commands.isDisjoint(with: Set(AppCommand.slideCommands)) {
                            commandSection("SLIDES", commands: AppCommand.slideCommands)
                        }

                        // Transport commands
                        if !commands.isDisjoint(with: Set(AppCommand.transportCommands)) {
                            commandSection("TRANSPORT", commands: AppCommand.transportCommands)
                        }

                        // Volume commands
                        if !commands.isDisjoint(with: Set(AppCommand.volumeCommands)) {
                            commandSection("VOLUME", commands: AppCommand.volumeCommands)
                        }

                        if commands.isEmpty {
                            Text("No app-specific controls available for this source.")
                                .font(.system(size: 12))
                                .foregroundStyle(ARCTheme.textTertiary)
                        }

                        Spacer()
                    }
                    .padding(12)
                }
            }
        }
        .background(ARCTheme.surface)
    }

    private func commandSection(_ title: String, commands list: [AppCommand]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(ARCTheme.textTertiary)
                .tracking(1)

            let available = list.filter { commands.contains($0) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 6) {
                ForEach(available) { command in
                    Button {
                        engine.sendCommand(command, toSourceId: sourceId)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: command.sfSymbol)
                                .font(.system(size: 11))
                            Text(command.displayName)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(ARCTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(ARCTheme.surfaceLight, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
