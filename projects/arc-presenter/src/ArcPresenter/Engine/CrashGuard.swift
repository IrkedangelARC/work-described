//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import Foundation

/// Presenter's side of the crash cover (design §3): the Guard agent, bundled at
/// `Contents/Library/ARC Presenter Guard.app`, runs while a program output is
/// open. It is told the program display so it can black it out the instant
/// Presenter dies, relaunch Presenter (the session restore does the rest), and
/// drop the black when `/state.health.chips.pgm` reads ok. A clean quit sends it
/// SIGTERM first. Never started by the test host.
@MainActor
enum CrashGuard {
    static let enabledKey = "crashGuardEnabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private(set) static var process: Process?
    private(set) static var displayID: CGDirectDisplayID?
    private(set) static var sdiDevice: Int64?
    private(set) static var startedAt: Date?
    private(set) static var lastError: String?

    static var isRunning: Bool { process?.isRunning == true }

    static var executableURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/ARC Presenter Guard.app/Contents/MacOS/ARC Presenter Guard")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The argument list, pure, for the test.
    static func arguments(parent: Int32, display: CGDirectDisplayID?, app: URL, apiPort: Int, sdi: Int64? = nil, fps: Double = 59.94) -> [String] {
        var a = ["--parent", String(parent), "--app", app.path, "--api", String(apiPort)]
        if let display { a += ["--display", String(display)] }
        if let sdi { a += ["--sdi", String(sdi), "--fps", String(fps)] }
        return a
    }

    /// Called from the 1 s health tick: start while a program output is open,
    /// restart if the display changed or the agent died, stop when it closes.
    static func reconcile(programConnected: Bool, displayID id: CGDirectDisplayID?, sdi: Int64? = nil, fps: Double = 59.94, apiPort: Int = 8760) {
        guard !AppEnvironment.isTestHost, isEnabled else { return }
        let wanted = programConnected && id != nil
        if !wanted { if process != nil { stop(reason: "program output closed") }; return }
        if isRunning, displayID == id, sdiDevice == sdi { return }
        if process != nil { stop(reason: !isRunning ? "the agent had died" : (displayID != id ? "program display changed" : "SDI changed")) }
        start(displayID: id!, sdi: sdi, fps: fps, apiPort: apiPort)
    }

    static func start(displayID id: CGDirectDisplayID, sdi: Int64? = nil, fps: Double = 59.94, apiPort: Int) {
        guard let exe = executableURL else {
            if lastError == nil { lastError = "Guard agent not in the bundle"; ShowLog.error("crash guard: agent not found in the bundle (Contents/Library/ARC Presenter Guard.app)") }
            return
        }
        let p = Process()
        p.executableURL = exe
        p.arguments = arguments(parent: ProcessInfo.processInfo.processIdentifier, display: id, app: Bundle.main.bundleURL, apiPort: apiPort, sdi: sdi, fps: fps)
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            process = p; displayID = id; sdiDevice = sdi; startedAt = Date(); lastError = nil
            ShowLog.log("crash guard started (pid \(p.processIdentifier)) for display \(id)\(sdi.map { ", SDI device \($0)" } ?? "")")
        } catch {
            lastError = error.localizedDescription
            ShowLog.error("crash guard could not start: \(error.localizedDescription)")
        }
    }

    /// SIGTERM: the Guard takes it as a clean quit and exits without doing anything.
    static func stop(reason: String) {
        guard let p = process else { return }
        if p.isRunning { p.terminate() }
        ShowLog.log("crash guard stopped (\(reason))")
        process = nil; displayID = nil; sdiDevice = nil; startedAt = nil
    }

    static var json: String {
        let err = lastError.map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" } ?? "null"
        return "{\"enabled\":\(isEnabled),\"running\":\(isRunning),\"pid\":\(process?.processIdentifier ?? 0),\"display\":\(displayID ?? 0),\"sdi\":\(sdiDevice ?? 0),\"bundled\":\(executableURL != nil),\"error\":\(err)}"
    }
}
