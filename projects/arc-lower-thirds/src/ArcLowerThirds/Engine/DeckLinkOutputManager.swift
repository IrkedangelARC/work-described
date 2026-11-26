//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import ARCDeckLink
import Foundation

/// Third output path: DeckLink Fill+Key over Thunderbolt to an ATEM
/// (e.g. ATEM Mini Extreme ISO G2), alongside the two HDMI modes.
///
/// When enabled, the Stage Output window's backdrop goes TRANSPARENT
/// (window `isOpaque = false`, `.clear` background, and StageOutputView
/// skips its black fill). The window is captured with alpha via
/// ScreenCaptureKit (`WindowAlphaCapture`) and played out as fill+key in
/// external-key mode — one Thunderbolt cable to the ATEM replaces both
/// HDMI key feeds, freeing both HDMI inputs.
///
/// The HDMI paths (`.lumaKey` / `.fillAndKey` windows) keep working: this
/// manager only touches the Stage Output window's backdrop while active,
/// and restores it on stop.
@Observable
final class DeckLinkOutputManager {

    // MARK: - Output Format

    static let outputWidth = 1920
    static let outputHeight = 1080
    static let outputFPS = 60.0

    private static let deviceDefaultsKey = "deckLinkDevicePersistentID"

    // MARK: - Observable State

    /// User intent — mirrors the enable toggle.
    private(set) var isEnabled = false

    /// True while the window is being captured and frames flow to the device.
    /// StageOutputView renders a clear backdrop instead of black while active.
    private(set) var isActive = false

    /// Operator-facing status line (progress / failure reason).
    private(set) var statusMessage: String?

    /// Frame counters, mirrored from the output on a short timer.
    private(set) var sentFrames = 0
    private(set) var droppedFrames = 0
    private(set) var lastError: String?

    /// Playback-capable DeckLink devices (refreshed on demand).
    private(set) var devices: [DeckLinkDevice] = []

    /// Persisted device selection. 0 = first available device.
    private(set) var selectedDeviceID: Int64

    /// True when the Blackmagic Desktop Video driver is installed.
    var isDriverInstalled: Bool {
        DeckLinkFillKeyOutput.isDriverInstalled
    }

    // MARK: - Private

    private var output: DeckLinkFillKeyOutput?
    private var capture: WindowAlphaCapture?
    private var statsTimer: Timer?

    /// Window whose backdrop we made transparent, and its prior appearance.
    private weak var capturedWindow: NSWindow?
    private var previousIsOpaque = true
    private var previousBackgroundColor: NSColor?
    private var previousContentAspectRatio: NSSize = .zero
    private var previousFrame: NSRect?

    init() {
        selectedDeviceID = (UserDefaults.standard.object(forKey: Self.deviceDefaultsKey) as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Device Selection

    func selectDevice(_ persistentID: Int64) {
        selectedDeviceID = persistentID
        UserDefaults.standard.set(NSNumber(value: persistentID), forKey: Self.deviceDefaultsKey)
    }

    func refreshDevices() {
        guard isDriverInstalled else {
            devices = []
            return
        }
        devices = DeckLinkFillKeyOutput.devices()
    }

    // MARK: - Enable / Disable

    func enable() {
        guard !isEnabled else { return }

        guard isDriverInstalled else {
            statusMessage = "Desktop Video driver not installed — install Blackmagic Desktop Video"
            return
        }
        refreshDevices()
        guard !devices.isEmpty else {
            statusMessage = "No DeckLink output device — check the Thunderbolt cable to the ATEM"
            return
        }

        isEnabled = true
        lastError = nil
        statusMessage = "Starting DeckLink output…"

        // The fill window must exist on screen to be captured.
        if findStageWindow() != nil {
            startOutput()
        } else {
            NotificationCenter.default.post(name: .openStageWindow, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.startOutput()
            }
        }
    }

    func disable() {
        guard isEnabled else { return }
        teardown(message: nil)
    }

    // MARK: - Pipeline

    private func startOutput() {
        guard isEnabled, !isActive else { return }

        guard let window = findStageWindow() else {
            teardown(message: "Stage Output window not found — open it (Output ▸ Open Fill Window) and re-enable")
            return
        }

        prepareWindowForCapture(window)
        isActive = true  // StageOutputView swaps its backdrop to clear

        let output = DeckLinkFillKeyOutput()
        do {
            try output.start(devicePersistentID: selectedDeviceID,
                             width: Self.outputWidth,
                             height: Self.outputHeight,
                             fps: Self.outputFPS,
                             keyer: .externalKey)
        } catch {
            teardown(message: "DeckLink start failed: \(error.localizedDescription)")
            return
        }
        self.output = output

        let capture = WindowAlphaCapture(windowNumber: window.windowNumber,
                                         outputWidth: Self.outputWidth,
                                         outputHeight: Self.outputHeight,
                                         fps: Int(Self.outputFPS))
        capture.onFrame = { [weak output] buffer in
            output?.send(fill: buffer)  // alpha rides along; ATEM keys externally
        }
        capture.onStopped = { [weak self] error in
            DispatchQueue.main.async {
                self?.captureDidStop(error)
            }
        }
        self.capture = capture

        Task { @MainActor [weak self] in
            do {
                try await capture.start()
                // Disabled while starting? Stop the stream we just opened.
                guard let self, self.isEnabled, self.capture === capture else {
                    await capture.stop()
                    return
                }
                self.statusMessage = nil
                self.startStatsTimer()
            } catch let error as WindowAlphaCapture.CaptureError {
                self?.teardown(message: error.localizedDescription)
            } catch {
                self?.teardown(message: "Window capture failed: \(error.localizedDescription) — check System Settings ▸ Privacy & Security ▸ Screen Recording")
            }
        }
    }

    /// Capture stream ended on its own (window closed, permission revoked, …).
    /// No auto-retry: surface the reason and let the operator re-enable.
    private func captureDidStop(_ error: Error?) {
        guard isEnabled else { return }  // we initiated the stop
        let reason = error.map { ": \($0.localizedDescription)" } ?? ""
        teardown(message: "Window capture stopped\(reason) — keep the Stage Output window on screen (not minimized) and re-enable")
    }

    private func teardown(message: String?) {
        statsTimer?.invalidate()
        statsTimer = nil
        if let capture {
            self.capture = nil
            Task { await capture.stop() }
        }
        output?.stop()
        output = nil
        restoreWindow()
        isActive = false
        isEnabled = false
        statusMessage = message
    }

    // MARK: - Stats

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let output = self.output else { return }
            self.sentFrames = output.sentFrames
            self.droppedFrames = output.droppedFrames
            self.lastError = output.lastErrorMessage
        }
    }

    // MARK: - Window Handling

    private func findStageWindow() -> NSWindow? {
        NSApplication.shared.windows.first { $0.title.contains("Stage Output") && $0.isVisible }
    }

    /// Make the fill window's backdrop transparent so window alpha becomes
    /// the key signal, and hold a stable 16:9 raster for capture (SCK scales
    /// the content to 1920x1080).
    private func prepareWindowForCapture(_ window: NSWindow) {
        capturedWindow = window
        previousIsOpaque = window.isOpaque
        previousBackgroundColor = window.backgroundColor
        previousContentAspectRatio = window.contentAspectRatio
        previousFrame = window.frame
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        if let contentSize = window.contentView?.frame.size,
           contentSize.width > 0, contentSize.height > 0,
           abs(contentSize.width / contentSize.height - 16.0 / 9.0) > 0.01 {
            window.setContentSize(NSSize(width: contentSize.width,
                                         height: (contentSize.width * 9.0 / 16.0).rounded()))
        }
    }

    private func restoreWindow() {
        guard let window = capturedWindow else { return }
        window.isOpaque = previousIsOpaque
        window.backgroundColor = previousBackgroundColor ?? .black
        window.contentAspectRatio = previousContentAspectRatio
        // Undo the 16:9 snap only if the operator hasn't since parked the
        // window fullscreen on a display (don't yank a live HDMI feed).
        let isParkedFullscreen = window.screen.map { window.frame == $0.frame } ?? false
        if let frame = previousFrame, window.frame.size != frame.size, !isParkedFullscreen {
            window.setFrame(frame, display: true)
        }
        previousFrame = nil
        capturedWindow = nil
    }
}
