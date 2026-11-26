//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

#if os(macOS)
import AppKit
import ARCDeckLink

/// Drives the "DeckLink Fill+Key" output (Thunderbolt/ATEM).
///
/// When enabled, this manager:
///   1. Opens a hidden borderless window with a fully TRANSPARENT background
///      rendering the confidence-overlay layout (timer elements floating,
///      everything else clear).
///   2. Captures that window with alpha via ScreenCaptureKit
///      (`WindowAlphaCapture`) at 1920x1080@60.
///   3. Sends each frame to a DeckLink playback device — e.g. the ATEM Mini
///      Extreme ISO G2 over Thunderbolt — in external-key mode, so the
///      graphics land in the ATEM's DSK as a keyed overlay over program.
///
/// Requires the Blackmagic Desktop Video driver and the Screen Recording
/// permission. All failure paths degrade to a status message; there are no
/// retries — the operator re-enables after fixing the cause.
@Observable
final class DeckLinkOutputManager {

    // MARK: - Output format

    static let outputWidth = 1920
    static let outputHeight = 1080
    static let outputFPS = 60

    private static let deviceIDDefaultsKey = "decklinkDevicePersistentID"

    // MARK: - Observable state

    /// Output is live (capture running, frames flowing to the device).
    private(set) var isRunning = false
    /// Between enable and the async ScreenCaptureKit start completing.
    private(set) var isStarting = false
    private(set) var isDriverInstalled = false
    private(set) var devices: [DeckLinkDevice] = []
    private(set) var sentFrames = 0
    private(set) var droppedFrames = 0
    private(set) var lastError: String?

    /// Persistent ID of the selected DeckLink device. 0 = first available.
    var selectedDeviceID: Int64 {
        didSet {
            UserDefaults.standard.set(Int(selectedDeviceID), forKey: Self.deviceIDDefaultsKey)
        }
    }

    var isEnabled: Bool { isRunning || isStarting }

    // Wired from ArcStageTimerApp at launch
    var displayState: StageDisplayState?
    var confidenceState: ConfidenceMonitorState?

    // MARK: - Private

    private var output: DeckLinkFillKeyOutput?
    private var capture: WindowAlphaCapture?
    private var overlayWindow: NSWindow?
    private var statsTimer: Timer?

    init() {
        selectedDeviceID = Int64(UserDefaults.standard.integer(forKey: Self.deviceIDDefaultsKey))
        refreshDevices()
    }

    deinit {
        statsTimer?.invalidate()
        output?.stop()
    }

    // MARK: - Device Discovery

    func refreshDevices() {
        isDriverInstalled = DeckLinkFillKeyOutput.isDriverInstalled
        devices = isDriverInstalled ? DeckLinkFillKeyOutput.devices() : []
    }

    /// Display name for the currently selected device.
    var selectedDeviceName: String {
        if selectedDeviceID == 0 { return "First Available" }
        return devices.first(where: { $0.persistentID == selectedDeviceID })?.name
            ?? "Device \(selectedDeviceID) (not connected)"
    }

    // MARK: - Enable / Disable

    func toggle() {
        if isEnabled { stop() } else { start() }
    }

    func start() {
        guard !isEnabled else { return }
        lastError = nil
        refreshDevices()

        guard isDriverInstalled else {
            lastError = "Blackmagic Desktop Video driver is not installed."
            return
        }
        guard !devices.isEmpty else {
            lastError = "No DeckLink output device found. Check the Thunderbolt connection to the ATEM."
            return
        }
        guard let displayState, let confidenceState else {
            lastError = "DeckLink output is not wired to display state."
            return
        }

        // 1. Transparent overlay window — must be on screen for ScreenCaptureKit
        //    (occluded is fine, so it sits behind everything else).
        let window = makeOverlayWindow(displayState: displayState, confidenceState: confidenceState)
        window.orderBack(nil)
        overlayWindow = window

        // 2. DeckLink playout in external-key mode (fill + key to ATEM DSK).
        let out = DeckLinkFillKeyOutput()
        do {
            try out.start(devicePersistentID: selectedDeviceID,
                          width: Self.outputWidth,
                          height: Self.outputHeight,
                          fps: Double(Self.outputFPS),
                          keyer: .externalKey)
        } catch {
            teardown()
            lastError = "DeckLink start failed: \(error.localizedDescription)"
            return
        }
        output = out

        // 3. Capture the window with alpha and forward frames as fill.
        //    The frame's own alpha channel becomes the key.
        let cap = WindowAlphaCapture(windowNumber: window.windowNumber,
                                     outputWidth: Self.outputWidth,
                                     outputHeight: Self.outputHeight,
                                     fps: Self.outputFPS)
        cap.onFrame = { [weak out] buffer in
            out?.send(fill: buffer)
        }
        cap.onStopped = { [weak self] error in
            DispatchQueue.main.async {
                self?.captureStopped(error)
            }
        }
        capture = cap
        isStarting = true

        Task { @MainActor [weak self] in
            do {
                try await cap.start()
                guard let self, self.isStarting else { return }
                self.isStarting = false
                self.isRunning = true
                self.startStatsTimer()
            } catch {
                guard let self else { return }
                self.teardown()
                self.lastError = "Window capture failed: \(error.localizedDescription) "
                    + "Check Screen Recording permission in System Settings › Privacy & Security."
            }
        }
    }

    func stop() {
        guard isEnabled else { return }
        teardown()
    }

    /// Capture stream ended on its own (permission revoked, window closed, …).
    /// No automatic restart — surface the error and shut down cleanly.
    private func captureStopped(_ error: Error?) {
        guard isEnabled else { return }
        teardown()
        lastError = error.map { "Capture stopped: \($0.localizedDescription)" }
            ?? "Capture stopped."
    }

    private func teardown() {
        isStarting = false
        isRunning = false
        statsTimer?.invalidate()
        statsTimer = nil
        if let cap = capture {
            capture = nil
            cap.onFrame = nil
            cap.onStopped = nil
            Task { await cap.stop() }
        }
        output?.stop()
        output = nil
        overlayWindow?.orderOut(nil)
        overlayWindow?.close()
        overlayWindow = nil
    }

    // MARK: - Frame Counters

    private func startStatsTimer() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let output = self.output else { return }
            self.sentFrames = output.sentFrames
            self.droppedFrames = output.droppedFrames
        }
    }

    // MARK: - Overlay Window

    /// Borderless, transparent, mouse-transparent window rendering the overlay
    /// content. Kept at the back of the app's window stack; its title stays
    /// empty so OutputRoutingManager's window lookups never match it.
    private func makeOverlayWindow(displayState: StageDisplayState,
                                   confidenceState: ConfidenceMonitorState) -> NSWindow {
        // 16:9 at up to 1920x1080 points, clamped to fit the main screen so
        // the whole window stays on screen for capture.
        let target = NSSize(width: CGFloat(Self.outputWidth), height: CGFloat(Self.outputHeight))
        let screenFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: target.width, height: target.height)
        let scale = min(1, min(screenFrame.width / target.width, screenFrame.height / target.height))
        let size = NSSize(width: floor(target.width * scale), height: floor(target.height * scale))
        let origin = NSPoint(x: screenFrame.midX - size.width / 2,
                             y: screenFrame.midY - size.height / 2)

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true

        let root = DeckLinkOverlayRootView(displayState: displayState,
                                           confidenceState: confidenceState)
        window.contentView = NSHostingView(rootView: root)
        return window
    }
}

// MARK: - Overlay Root View

/// Root view for the DeckLink overlay window: the existing confidence-overlay
/// layout rendered with NO opaque backdrop, so window transparency becomes the
/// key alpha. PIP (opaque surround) layouts are coerced to an overlay layout —
/// fill+key output is always a floating overlay.
private struct DeckLinkOverlayRootView: View {
    let displayState: StageDisplayState
    let confidenceState: ConfidenceMonitorState

    var body: some View {
        StageDisplayView(confidenceConfig: overlayConfig, transparentBackground: true)
            .environment(displayState)
            .preferredColorScheme(.dark)
    }

    private var overlayConfig: ConfidenceMonitorConfig {
        var config = confidenceState.config
        config.isEnabled = true
        config.mode = .overlay
        if !config.layout.isOverlayLayout {
            config.layout = .cornerBrackets
        }
        return config
    }
}
#endif
