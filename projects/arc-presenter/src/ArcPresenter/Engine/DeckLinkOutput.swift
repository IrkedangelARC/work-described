//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import ARCDeckLink
import CoreVideo

/// V4.2 (2026-09-16): PROGRAM out over a Blackmagic DeckLink / UltraStudio
/// (Express Monitor 3G, Monitor 3G, the office workstation's UltraStudio) as SDI / HDMI.
///
/// The device is not a macOS display, so nothing is "assigned" to it. Presenter
/// keeps drawing its program window exactly as it does for a display, this
/// captures that window with ScreenCaptureKit and pushes the frames through the
/// shared ARCDeckLink package. Whatever the program window shows goes out,
/// including a taken PowerPoint (the V4 composite lives in that window).
///
/// When no PROGRAM display is assigned the program window is opened "headless":
/// a small window on the operator's screen behind the operator window, on
/// screen (SCK needs that; occluded is fine) but out of the way. That is how a
/// one-external-display laptop (13" M1) gets PROGRAM on SDI and the confidence
/// monitor on its only port.
///
/// A fixed 1080p output is its own EDID lock: the room never renegotiates with
/// the Mac, so the display re-park problem does not exist on this path.
@MainActor
@Observable
final class DeckLinkOutput {
    static let width = 1920
    static let height = 1080
    private static let deviceKey = "decklinkDevicePersistentID"
    private static let fpsKey = "decklinkFPS"
    static let fpsChoices: [Double] = [59.94, 60, 50, 29.97, 30, 25]

    private(set) var devices: [DeckLinkDevice] = []
    private(set) var isRunning = false
    private(set) var activeDevice: DeckLinkDevice?
    /// Last problem, or nil. Shown next to the SDI chip and on GET /decklink.
    private(set) var status: String?
    private(set) var sentFrames = 0
    private(set) var droppedFrames = 0
    /// True while the program window exists only for this output.
    private(set) var headlessProgramWindow = false

    @ObservationIgnored private var output: DeckLinkFillKeyOutput?
    @ObservationIgnored private var capture: WindowAlphaCapture?
    @ObservationIgnored private var statsTimer: Timer?
    @ObservationIgnored private var resizeObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSentSeen = 0
    @ObservationIgnored private var lastDroppedSeen = 0
    @ObservationIgnored private var staleTicks = 0
    private static let stalledStatusPrefix = "no frames are reaching "
    /// Frames are being dropped and none sent: the device stopped taking them
    /// (unplugged, lost power). The dot goes amber and `status` says so.
    var isStalled: Bool { isRunning && (status?.hasPrefix(Self.stalledStatusPrefix) ?? false) }

    static var driverInstalled: Bool { DeckLinkFillKeyOutput.isDriverInstalled }

    var fps: Double {
        get {
            let v = UserDefaults.standard.double(forKey: Self.fpsKey)
            return Self.fpsChoices.contains(v) ? v : 59.94
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.fpsKey) }
    }

    /// The device used last time, so the SDI chip can offer it first.
    var rememberedDeviceID: Int64? {
        let v = UserDefaults.standard.object(forKey: Self.deviceKey) as? NSNumber
        return v?.int64Value
    }

    func refreshDevices() {
        let t0 = Date()
        devices = Self.driverInstalled ? DeckLinkFillKeyOutput.devices().filter(\.supportsPlayback) : []
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if ms >= 100 { ShowLog.log("DeckLink device list took \(ms) ms on the main thread") }   // 50 to 80 ms warm (measured 2026-09-17); the first call loads the driver
    }

    /// Match a device by persistent id, exact or substring name (case-insensitive),
    /// or 1-based index; "0" or "first" = the first device. Pure, for tests and
    /// the control API.
    nonisolated static func match(_ key: String, in devices: [DeckLinkDevice]) -> DeckLinkDevice? {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !devices.isEmpty else { return nil }
        if k.isEmpty || k == "0" || k.caseInsensitiveCompare("first") == .orderedSame { return devices[0] }
        if let n = Int64(k) {
            // A number is an id or a 1-based index, never a substring ("3" must not hit "Monitor 3G").
            if let d = devices.first(where: { $0.persistentID == n }) { return d }
            if n >= 1, n <= Int64(devices.count) { return devices[Int(n) - 1] }
            return nil
        }
        if let d = devices.first(where: { $0.name.caseInsensitiveCompare(k) == .orderedSame }) { return d }
        return devices.first { $0.name.range(of: k, options: .caseInsensitive) != nil }
    }

    // MARK: - Start / stop

    func start(device: DeckLinkDevice) async {
        stop()
        guard WindowCapture.hasPermission else {
            status = "Screen Recording permission is needed to send the program window to \(device.name). Allow it in System Settings, then relaunch ARC Presenter"
            WindowCapture.requestPermission()
            return
        }
        guard let (window, headless) = await Self.programWindow() else {
            status = "the program window did not open"
            return
        }
        headlessProgramWindow = headless
        let t0 = Date()
        let out = DeckLinkFillKeyOutput()
        // The SDK's start is synchronous and takes seconds (it opens the device
        // and enables its output). On the main thread that froze the console:
        // "main thread lag 5632 ms" every time the outputs came up (three of
        // three on 2026-09-17), with clicks and keys held until it returned.
        nonisolated(unsafe) let device_out = out
        let id = device.persistentID, w = Self.width, h = Self.height, rate = fps
        // A Guard from the run that died may be holding this device with the last frame
        // (crash cover): ask it to let go, then give it a moment.
        if let pidText = try? String(contentsOf: RunMarker.url.deletingLastPathComponent().appendingPathComponent("guard.pid"), encoding: .utf8),
           let gpid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), kill(gpid, 0) == 0 {
            kill(gpid, SIGUSR1)
            ShowLog.log("DeckLink: asked the crash guard (pid \(gpid)) to release \(device.name)")
            try? await Task.sleep(for: .milliseconds(250))
        }
        let failure: (any Error)? = await Task.detached(priority: .userInitiated) {
            do { try device_out.start(devicePersistentID: id, width: w, height: h, fps: rate, keyer: .none); return nil } catch { return error }
        }.value
        let deviceMs = Int(Date().timeIntervalSince(t0) * 1000)
        do {
            if let failure { throw failure }
        } catch {
            status = "\(device.name): \(error.localizedDescription)"
            ShowLog.error("DeckLink start failed: \(device.name): \(error.localizedDescription)")
            return
        }
        let cap = WindowAlphaCapture(windowNumber: window.windowNumber, outputWidth: Self.width, outputHeight: Self.height, fps: Int(fps.rounded()))
        // Send the centred 16:9 of the window, not the whole window: on a
        // 16:10 program display the slide sits between bars, and fitting the
        // whole window into 1080p pillarboxed it as well (2026-09-16).
        cap.sourceRect = Self.centered16x9(in: window.frame.size)
        cap.onFrame = { [out] buffer in out.send(fill: buffer) }
        cap.onStopped = { [weak self] error in
            Task { @MainActor in self?.captureStopped(error) }
        }
        do {
            try await cap.start()
        } catch {
            out.stop()
            status = "capture of the program window failed: \(error.localizedDescription)"
            ShowLog.error("DeckLink capture failed: \(error.localizedDescription)")
            return
        }
        output = out
        capture = cap
        activeDevice = device
        isRunning = true
        status = nil
        sentFrames = 0
        droppedFrames = 0
        UserDefaults.standard.set(NSNumber(value: device.persistentID), forKey: Self.deviceKey)
        ShowLog.log("DeckLink start took \(Int(Date().timeIntervalSince(t0) * 1000)) ms (device \(deviceMs) ms, off the main thread)")
        ShowLog.log("DeckLink out: \(device.name) \(Self.width)x\(Self.height) @ \(fps) window \(window.windowNumber) \(Int(window.frame.width))x\(Int(window.frame.height)) crop \(Self.describe(cap.sourceRect)) headless=\(headlessProgramWindow)")
        // PROGRAM assigned (or moved) while SDI runs: the same window changes
        // size, so re-crop, and it is no longer headless.
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, let cap = self.capture else { return }
                let rect = Self.centered16x9(in: window.frame.size)
                self.headlessProgramWindow = !ArcPresenterApp.sharedDisplayManager.isProgramConnected
                ShowLog.log("DeckLink program window now \(Int(window.frame.width))x\(Int(window.frame.height)), crop \(Self.describe(rect)) headless=\(self.headlessProgramWindow)")
                await cap.update(sourceRect: rect)
            }
        }
        lastSentSeen = 0; lastDroppedSeen = 0; staleTicks = 0
        statsTimer = Timer.commonModes(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let out = self.output else { return }
                self.sentFrames = out.sentFrames
                self.droppedFrames = out.droppedFrames
                // Truth about the device (audit R6): drops with no sends for
                // two ticks means nothing is leaving the box.
                if self.sentFrames == self.lastSentSeen, self.droppedFrames > self.lastDroppedSeen {
                    self.staleTicks += 1
                    if self.staleTicks == 2 {
                        self.status = Self.stalledStatusPrefix + "\(self.activeDevice?.name ?? "the device") (unplugged, or lost power?)"
                        ShowLog.error("DeckLink stalled: \(self.status ?? "")")
                    }
                } else if self.sentFrames > self.lastSentSeen {
                    if self.isStalled { self.status = nil; ShowLog.log("DeckLink frames flowing again") }
                    self.staleTicks = 0
                }
                self.lastSentSeen = self.sentFrames
                self.lastDroppedSeen = self.droppedFrames
            }
        }
    }

    func stop() {
        statsTimer?.invalidate(); statsTimer = nil
        if let obs = resizeObserver { NotificationCenter.default.removeObserver(obs); resizeObserver = nil }
        if let cap = capture { Task { await cap.stop() } }
        capture = nil
        output?.stop()
        output = nil
        if isRunning { ShowLog.log("DeckLink out stopped (\(activeDevice?.name ?? "?")): sent \(sentFrames) dropped \(droppedFrames)") }
        isRunning = false
        activeDevice = nil
        if headlessProgramWindow {
            // The window existed only for this output; put it away. Never
            // when PROGRAM has since been assigned: that is the room's picture.
            if !ArcPresenterApp.sharedDisplayManager.isProgramConnected {
                NSApp.windows.first { $0.title == OutputType.program.windowTitle }?.orderOut(nil)
            }
            headlessProgramWindow = false
        }
    }

    /// The largest 16:9 rectangle centred in `size` (window points): the
    /// program window draws its picture aspect-fit and centred, so this is
    /// the picture without the window's bars. Pure, for tests.
    nonisolated static func centered16x9(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let target = CGFloat(width) / CGFloat(height)
        if size.width / size.height > target {
            let w = (size.height * target).rounded()
            return CGRect(x: ((size.width - w) / 2).rounded(), y: 0, width: w, height: size.height)
        } else {
            let h = (size.width / target).rounded()
            return CGRect(x: 0, y: ((size.height - h) / 2).rounded(), width: size.width, height: h)
        }
    }

    nonisolated private static func describe(_ r: CGRect?) -> String {
        guard let r else { return "none" }
        return "\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))x\(Int(r.height))"
    }

    private func captureStopped(_ error: Error?) {
        guard isRunning else { return }
        status = "program window capture stopped\(error.map { ": \($0.localizedDescription)" } ?? "") (was it closed?)"
        ShowLog.error("DeckLink capture stopped: \(error?.localizedDescription ?? "no error")")
        stop()
    }

    /// The on-screen program window, opened if needed. Never routes it to a
    /// display: that is DisplayManager's job and only when PROGRAM is assigned.
    private static func programWindow() async -> (NSWindow, Bool)? {
        let title = OutputType.program.windowTitle
        let dm = ArcPresenterApp.sharedDisplayManager
        if let w = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) {
            return (w, !dm.isProgramConnected)
        }
        NotificationCenter.default.post(name: .openProgramWindowOnly, object: nil)
        var window: NSWindow?
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let w = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) { window = w; break }
        }
        guard let window else { return nil }
        if dm.isProgramConnected { return (window, false) }
        // Headless: 16:9, small, bottom-right of the OPERATOR's screen, behind the operator window (HeadlessWindow).
        guard HeadlessWindow.place(window, size: NSSize(width: 640, height: 360), corner: .bottomRight) else { return nil }
        return (window, true)
    }

    // MARK: - Control API

    var json: String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let list = devices.map { "{\"id\":\($0.persistentID),\"name\":\"\(esc($0.name))\"}" }.joined(separator: ",")
        let dev = activeDevice.map { "\"\(esc($0.name))\"" } ?? "null"
        let st = status.map { "\"\(esc($0))\"" } ?? "null"
        return "{\"driver\":\(Self.driverInstalled),\"running\":\(isRunning),\"device\":\(dev),\"fps\":\(fps),\"sent\":\(sentFrames),\"dropped\":\(droppedFrames),\"headlessProgramWindow\":\(headlessProgramWindow),\"status\":\(st),\"devices\":[\(list)]}"
    }
}

extension Notification.Name {
    /// Open the program window without routing it to a display (DeckLink-only program).
    static let openProgramWindowOnly = Notification.Name("ARCPresenter.openProgramWindowOnly")
}
