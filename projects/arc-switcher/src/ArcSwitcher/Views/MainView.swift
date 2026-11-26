//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Primary layout: source sidebar + center preview + command inspector.
struct MainView: View {
    @Environment(SwitcherEngine.self) private var engine
    @Environment(HTTPRemoteServer.self) private var server

    @State private var selectedSourceId: String?
    @State private var showingAppPicker = false
    @State private var showingOBSSettings = false
    @State private var obsMonitors: [[String: Any]] = []

    var body: some View {
        HSplitView {
            // Left: source list
            SourceListView(
                selectedId: $selectedSourceId,
                onShowAppPicker: { showingAppPicker = true }
            )
            .frame(minWidth: 220, idealWidth: ARCTheme.sidebarWidth, maxWidth: 320)

            // Center: active source preview
            PreviewPanel(selectedSourceId: selectedSourceId)
                .frame(minWidth: 300)

            // Right: commands for selected source
            if let sourceId = selectedSourceId {
                InspectorView(sourceId: sourceId)
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .foregroundStyle(ARCTheme.accent)
                    Text("ARC SWITCHER")
                        .font(ARCTheme.headerBar)
                        .foregroundStyle(ARCTheme.textPrimary)
                    Text("v2")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(ARCTheme.textTertiary)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    // OBS connection status
                    Button {
                        if engine.obs.isConnected {
                            engine.disconnectOBS()
                        } else {
                            engine.connectOBS()
                            // Initialize after connection settles
                            Task {
                                try? await Task.sleep(for: .seconds(1))
                                await engine.initializeOBS()
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "video.fill")
                            Text(obsStatusText)
                                .font(ARCTheme.monoSmall)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(obsStatusColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("OBS Settings...") { showingOBSSettings = true }
                        if engine.obs.isConnected {
                            Button("Reinitialize Scenes") {
                                Task { await engine.initializeOBS() }
                            }
                        }
                    }

                    // Control screen indicator
                    HStack(spacing: 4) {
                        Image(systemName: "lock.display")
                        Text(controlDisplayName)
                            .font(ARCTheme.monoSmall)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(engine.windowManager.controlDisplayID != nil ? .orange : ARCTheme.textTertiary, in: Capsule())

                    // Output display picker (OBS monitor indices)
                    Menu {
                        if obsMonitors.isEmpty {
                            Button("Refresh Monitors") { refreshOBSMonitors() }
                        }
                        ForEach(Array(obsMonitors.enumerated()), id: \.offset) { _, monitor in
                            let idx = monitor["monitorIndex"] as? Int ?? 0
                            let name = monitor["monitorName"] as? String ?? "Display \(idx)"
                            let w = monitor["monitorWidth"] as? Int ?? 0
                            let h = monitor["monitorHeight"] as? Int ?? 0
                            let selected = engine.outputMonitorIndex == idx
                            Button {
                                engine.outputMonitorIndex = idx
                                if engine.obs.isConnected {
                                    Task { try? await engine.obs.openFullscreenProjector(monitorIndex: idx) }
                                }
                            } label: {
                                Text("\(selected ? ">> " : "")\(name) (\(w)x\(h))")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "display")
                            Text(outputDisplayName)
                                .font(ARCTheme.monoSmall)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(engine.outputMonitorIndex != nil ? ARCTheme.accent : ARCTheme.textTertiary, in: Capsule())
                    }
                    .onAppear { refreshOBSMonitors() }

                    // Transition picker
                    if engine.obs.isConnected {
                        Menu {
                            Button("Cut") { engine.setTransition("Cut") }
                            Button("Fade (300ms)") { engine.setTransition("Fade", duration: 300) }
                            Button("Fade (500ms)") { engine.setTransition("Fade", duration: 500) }
                            Button("Fade (1000ms)") { engine.setTransition("Fade", duration: 1000) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.right.arrow.left")
                                Text("TRANS")
                                    .font(ARCTheme.monoSmall)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(ARCTheme.surface, in: Capsule())
                        }
                    }

                    // HTTP status
                    Button {
                        if server.isRunning { server.stop() } else { server.start() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                            Text(server.isRunning ? ":\(server.port)" : "OFF")
                                .font(ARCTheme.monoSmall)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(server.isRunning ? Color.green : ARCTheme.textTertiary, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if server.isRunning, let ip = HTTPRemoteServer.localIPAddress() {
                        Text(ip)
                            .font(ARCTheme.monoSmall)
                            .foregroundStyle(ARCTheme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .sheet(isPresented: $showingAppPicker) {
            AppPickerSheet()
        }
        .sheet(isPresented: $showingOBSSettings) {
            OBSSettingsSheet()
                .environment(engine)
        }
        .overlay(alignment: .bottom) {
            if let error = engine.errorMessage {
                Text(error)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 8)
                    .onTapGesture { engine.errorMessage = nil }
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            engine.errorMessage = nil
                        }
                    }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .background(ARCTheme.background)
    }

    // MARK: - Helpers

    private var obsStatusText: String {
        switch engine.obs.state {
        case .disconnected: "OBS OFF"
        case .connecting: "OBS..."
        case .authenticating: "AUTH..."
        case .connected: "OBS"
        case .error: "OBS ERR"
        }
    }

    private var obsStatusColor: Color {
        switch engine.obs.state {
        case .disconnected: ARCTheme.textTertiary
        case .connecting, .authenticating: .orange
        case .connected: .green
        case .error: .red
        }
    }

    private var controlDisplayName: String {
        engine.windowManager.controlScreen?.localizedName ?? "CTRL"
    }

    private var outputDisplayName: String {
        guard let index = engine.outputMonitorIndex else { return "Output" }
        if let monitor = obsMonitors.first(where: { ($0["monitorIndex"] as? Int) == index }) {
            return monitor["monitorName"] as? String ?? "Monitor \(index)"
        }
        return "Monitor \(index)"
    }

    private func refreshOBSMonitors() {
        guard engine.obs.isConnected else { return }
        Task {
            if let monitors = try? await engine.obs.getMonitorList() {
                await MainActor.run { obsMonitors = monitors }
            }
        }
    }
}

// MARK: - OBS Settings Sheet

struct OBSSettingsSheet: View {
    @Environment(SwitcherEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var host: String = "127.0.0.1"
    @State private var port: String = "4455"
    @State private var password: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("OBS WebSocket Settings")
                .font(.system(size: 16, weight: .bold))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Host:")
                        .frame(width: 60, alignment: .trailing)
                    TextField("127.0.0.1", text: $host)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Port:")
                        .frame(width: 60, alignment: .trailing)
                    TextField("4455", text: $port)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Password:")
                        .frame(width: 60, alignment: .trailing)
                    SecureField("Optional", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text("OBS must be running with WebSocket Server enabled.\nTools > WebSocket Server Settings in OBS.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save & Connect") {
                    engine.obs.host = host
                    engine.obs.port = UInt16(port) ?? 4455
                    engine.obs.password = password.isEmpty ? nil : password
                    UserDefaults.standard.set(host, forKey: "OBSHost")
                    UserDefaults.standard.set(port, forKey: "OBSPort")
                    UserDefaults.standard.set(password, forKey: "OBSPassword")
                    engine.connectOBS()
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        await engine.initializeOBS()
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 350)
        .onAppear {
            host = UserDefaults.standard.string(forKey: "OBSHost") ?? "127.0.0.1"
            port = UserDefaults.standard.string(forKey: "OBSPort") ?? "4455"
        }
    }
}
