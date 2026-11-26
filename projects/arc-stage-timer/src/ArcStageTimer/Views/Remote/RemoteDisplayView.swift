//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// iPad client mode — discovers Mac controllers, connects, and shows StageDisplayView.
struct RemoteDisplayView: View {
    let browser: BonjourBrowser
    let remote: RemoteTimerState
    let remoteDisplayState: StageDisplayState
    var onDismiss: () -> Void

    @State private var manualHost: String = ""
    @State private var manualPort: String = "8080"
    @State private var showManualEntry = false

    var body: some View {
        ZStack {
            switch remote.connectionState {
            case .disconnected:
                discoveryView
            case .resolving, .connecting:
                connectingView
            case .connected:
                connectedView
            case .reconnecting:
                connectedView
                    .overlay(reconnectingOverlay)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            browser.startBrowsing()
        }
        .onDisappear {
            browser.stopBrowsing()
        }
    }

    // MARK: - Discovery

    private var discoveryView: some View {
        NavigationStack {
            List {
                if browser.servers.isEmpty {
                    Section {
                        HStack(spacing: 16) {
                            ProgressView()
                            Text("Searching for ARC Stage Timer...")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    Section("Available Controllers") {
                        ForEach(browser.servers) { server in
                            Button {
                                remote.connect(to: server)
                            } label: {
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                        .font(.title2)
                                        .foregroundStyle(ARCTheme.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(server.name)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Text("Tap to connect")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showManualEntry.toggle()
                    } label: {
                        Label("Enter IP Manually", systemImage: "keyboard")
                    }

                    if showManualEntry {
                        HStack {
                            TextField("IP Address", text: $manualHost)
                                .textContentType(.URL)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                            Text(":")
                            TextField("Port", text: $manualPort)
                                .frame(width: 70)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                        }
                        Button("Connect") {
                            let port = UInt16(manualPort) ?? 8080
                            remote.connect(host: manualHost, port: port)
                        }
                        .disabled(manualHost.isEmpty)
                    }
                }
            }
            .navigationTitle("Confidence Monitor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        browser.stopBrowsing()
                        onDismiss()
                    }
                }
                ToolbarItem(placement: .automatic) {
                    if browser.isSearching {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Connecting

    private var connectingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to \(remote.serverName)...")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    // MARK: - Connected (full-screen stage display)

    private var connectedView: some View {
        ZStack(alignment: .topTrailing) {
            StageDisplayView()
                .environment(remoteDisplayState)

            // Disconnect button (subtle, top-right)
            Button {
                remote.disconnect()
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
            .padding(20)
        }
    }

    // MARK: - Reconnecting Overlay

    private var reconnectingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(remote.connectionState.label)
                .font(.headline)
                .foregroundStyle(.white)
            Button("Disconnect") {
                remote.disconnect()
            }
            .buttonStyle(.bordered)
        }
        .padding(40)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
