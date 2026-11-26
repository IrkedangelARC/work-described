//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Did the last run end cleanly? A marker file lives for the life of the
/// process: present at launch means the previous run crashed, was force-quit,
/// or the Mac died. The show log gets a line, `/state` gets `unclean`, and
/// the session restore that follows is the recovery (audit 2026-09-16, 0.9).
enum RunMarker {
    static let url: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ARC Presenter Arcdeck Player", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("running.marker")
    }()

    /// True for this whole run when the previous run did not exit cleanly.
    private(set) static var uncleanExit = false
    private(set) static var previousRun: String?

    /// The unit-test host runs the app delegate too and is killed by
    /// xcodebuild, never quit: it must not leave a marker that makes the next
    /// real launch report an unclean exit (seen 2026-09-16).
    static func launch() {
        if AppEnvironment.isTestHost { return }
        if let previous = try? String(contentsOf: url, encoding: .utf8) {
            uncleanExit = true
            previousRun = previous.trimmingCharacters(in: .whitespacesAndNewlines)
            ShowLog.log("DID NOT EXIT CLEANLY last time (\(previousRun ?? "?")); restoring the session")
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? "pid \(ProcessInfo.processInfo.processIdentifier) started \(stamp) version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"
            .write(to: url, atomically: true, encoding: .utf8)
    }

    static func cleanExit() {
        try? FileManager.default.removeItem(at: url)
    }
}
