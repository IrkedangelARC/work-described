//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ARCShowFormat

/// The show log (stability plan 3.1), backed by ARCShowFormat.ShowLogCore so
/// Presenter and Capture write the same format. `~/Library/Logs/ARC Presenter/
/// show.log`, rotated at launch (five kept), a 500-line ring for `GET /log`,
/// `error(_:)` feeds the health strip. (Was V4Log.)
enum ShowLog {
    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ARC Presenter", isDirectory: true)
    static let core: ShowLogCore = {
        let c = ShowLogCore(appName: "ARC Presenter", directory: directory)
        c.disabled = AppEnvironment.isTestHost
        c.mirror = { NSLog("ARC Presenter: %@", $0) }
        return c
    }()
    static var url: URL { core.url }
    static let keep = 5

    static func rotate(at dir: URL = directory, keep: Int = keep) { ShowLogCore.rotate(at: dir, keep: keep) }

    static func launch() {
        core.launch(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
    }

    static func log(_ message: String) { core.log(message) }
    static func error(_ message: String) { core.error(message) }
    static func tail(_ lines: Int) -> [String] { core.tail(lines) }
    static var lastError: (text: String, at: Date)? { core.lastError }
}

/// The 4.x name, kept for call sites and docs.
typealias V4Log = ShowLog
