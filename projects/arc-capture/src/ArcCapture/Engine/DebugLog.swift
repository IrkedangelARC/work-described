//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ARCShowFormat

/// File-based debug logger (macOS unified log redacts NSLog as <private>),
/// backed by ARCShowFormat.ShowLogCore since V3 so Capture and Presenter write
/// the same line format. ~/Library/Logs/ARC Capture/arc-capture.log, the
/// previous five launches kept as arc-capture.1.log … .5.log;
/// /tmp/arc-capture.log stays a symlink to the live file for `tail -f`.
/// Running under XCTest. The unit suite used to write its shows' lines into the REAL log (a TD reading
/// "PREFLIGHT FAIL ... 1.01 A.pdf" after a test run) and to rewrite the remembered show (2026-09-17).
enum AppEnvironment {
    static let isTestHost = NSClassFromString("XCTestCase") != nil
}

enum DebugLog {
    static let core = ShowLogCore(
        appName: "ARC Capture",
        directory: AppEnvironment.isTestHost
            ? FileManager.default.temporaryDirectory.appendingPathComponent("arc-capture-test-logs")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ARC Capture"),
        fileName: "arc-capture.log", keep: 6)

    /// New file at app launch; the previous five launches stay as .1 … .5.
    static func clear() {
        core.launch(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        guard !AppEnvironment.isTestHost else { return }       // /tmp/arc-capture.log keeps pointing at the app's log
        let link = URL(fileURLWithPath: "/tmp/arc-capture.log")
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: core.url)
    }

    /// Write a timestamped line to the log file (and the monitor's log tail).
    static func log(_ tag: String, _ message: String) {
        Task { @MainActor in CaptureMonitor.shared.log(tag, message) }
        core.log("[\(tag)] \(message)")
    }

    static func error(_ tag: String, _ message: String) {
        Task { @MainActor in CaptureMonitor.shared.log(tag, "ERROR: " + message) }
        core.error("[\(tag)] \(message)")
    }

    static func tail(_ lines: Int) -> [String] { core.tail(lines) }
}
