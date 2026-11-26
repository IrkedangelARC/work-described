//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import SystemExtensions

/// Installs, updates and removes the "ARC QUAD" camera extension on this Mac.
/// PHASE 0 (spike): install/remove and status only. The program address is fixed in the
/// extension (kProgramURL) until phase 2.
@main
struct QuadCameraApp: App {
    @StateObject private var installer = ExtensionInstaller()

    var body: some Scene {
        WindowGroup("ARC QUAD Camera") {
            VStack(alignment: .leading, spacing: 14) {
                Text("ARC QUAD CAMERA").font(.system(size: 20, weight: .bold, design: .monospaced))
                Text("Publishes QUAD's program as the camera \"ARC QUAD\" to Zoom, Teams, ARC Zoom and any other app on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("INSTALL / UPDATE") { installer.activate() }
                    Button("REMOVE") { installer.deactivate() }
                }
                Text(installer.status).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(width: 460)
            .onAppear {
                // `--install` lets a deploy script activate without a click on the button.
                if CommandLine.arguments.contains("--install") { installer.activate() }
            }
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let extensionID = "com.example.arc.ArcQuadCamera.Extension"
    @Published var status = "idle"

    func activate() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            status = "Move ARC QUAD Camera to /Applications first: macOS installs camera extensions only from there."
            return
        }
        status = "requesting install..."
        let r = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
    }

    func deactivate() {
        status = "requesting removal..."
        let r = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.status = "APPROVAL NEEDED: System Settings > General > Login Items & Extensions > Camera Extensions > turn on ARC QUAD Camera."
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            guard result == .completed else { self.status = "done: reboot required to finish"; return }
            // An UPDATE reports .completed even when the previous build is still unloading. In
            // that state the CMIO registrar never launches the new build and "ARC QUAD" is gone
            // from every camera list until a reboot (measured twice, 2026-09-26, builds 2 and 3).
            // So ask sysextd for every staged version before claiming the camera is available.
            self.status = "installed, checking..."
            let r = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
            r.delegate = self
            OSSystemExtensionManager.shared.submitRequest(r)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        Task { @MainActor in
            let live = properties.filter { $0.isEnabled && !$0.isUninstalling }.map(\.bundleVersion)
            if properties.contains(where: { $0.isUninstalling }) {
                self.status = "REBOOT REQUIRED: the previous build is still unloading, so \"ARC QUAD\" is NOT available until this Mac restarts. Build \(live.joined(separator: ", ")) takes over after the reboot."
            } else if live.isEmpty {
                self.status = "installed but not enabled: approve it in System Settings > General > Login Items & Extensions > Camera Extensions."
            } else {
                self.status = "done: \"ARC QUAD\" (build \(live.joined(separator: ", "))) is available as a camera"
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            self.status = "failed: \(error.localizedDescription)"
        }
    }
}
