//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Menu bar extra content: quick source switching and status.
struct MenuBarView: View {
    @Environment(SwitcherEngine.self) private var engine
    @Environment(HTTPRemoteServer.self) private var server

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Active source
            if let source = engine.activeSource {
                Label("LIVE: \(source.friendlyName)", systemImage: "circle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 12, weight: .bold))
            } else if engine.isBlack {
                Label("BLACK", systemImage: "rectangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 12, weight: .bold))
            } else {
                Label("No active source", systemImage: "circle")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }

            Divider()

            // Source quick-switch
            ForEach(Array(engine.sources.enumerated()), id: \.element.id) { index, source in
                Button {
                    engine.switchTo(sourceId: source.id)
                } label: {
                    HStack {
                        Text("\(index + 1). \(source.friendlyName)")
                        Spacer()
                        if source.id == engine.activeSourceId {
                            Image(systemName: "checkmark")
                        }
                        if !source.isAvailable {
                            Text("offline")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!source.isAvailable)
            }

            if !engine.sources.isEmpty {
                Divider()

                Button(engine.isBlack ? "Cut From Black" : "Cut to Black") {
                    if engine.isBlack { engine.cutFromBlack() } else { engine.cutToBlack() }
                }
            }

            Divider()

            // OBS status
            HStack {
                Image(systemName: "video.fill")
                Text(engine.obs.isConnected ? "OBS Connected" : "OBS Disconnected")
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(engine.obs.isConnected ? .green : .secondary)

            if !engine.obs.isConnected {
                Button("Connect OBS") {
                    engine.connectOBS()
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        await engine.initializeOBS()
                    }
                }
            }

            // Server status
            HStack {
                Image(systemName: "network")
                Text(server.isRunning ? "HTTP :\(server.port)" : "HTTP OFF")
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(server.isRunning ? .green : .secondary)

            Divider()

            Button("Quit ARC Switcher") {
                engine.enableSleep()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
    }
}
