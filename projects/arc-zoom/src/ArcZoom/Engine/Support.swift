//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

extension Timer {
    /// ALWAYS `.common`. A timer on the default run loop mode stops during a gesture drag, which in
    /// ARC Presenter froze a stage clock while an operator dragged a boundary (2026-09-17). Frames and
    /// clocks in this app use this one.
    @discardableResult
    static func common(every interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { body() }
        }
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}

/// The show log: one line per thing that happened, on disk for after the show and in a ring for
/// `GET /log`. Deliberately small; ARC Presenter's is the same idea backed by the show-format package.
enum ShowLog {
    /// Under XCTest the log goes to a temp folder: the test host used to rotate the REAL show log on every
    /// run, pushing a running app's lines out of it (2026-09-24, a sign-in outcome lost mid-diagnosis).
    static let directory = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        ? FileManager.default.temporaryDirectory.appendingPathComponent("ARC Zoom test logs", isDirectory: true)
        : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ARC Zoom", isDirectory: true)
    static let url = directory.appendingPathComponent("zoom.log")

    private static let queue = DispatchQueue(label: "com.example.arc.arczoom.log")
    nonisolated(unsafe) private static var ring: [String] = []
    private static let ringMax = 500

    static func start() {
        queue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // One rotation at launch, five kept, so a show's log is never mixed with the last one's.
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                for i in stride(from: 4, through: 1, by: -1) {
                    let from = directory.appendingPathComponent("zoom.\(i).log")
                    let to = directory.appendingPathComponent("zoom.\(i + 1).log")
                    if fm.fileExists(atPath: from.path) { try? fm.removeItem(at: to); try? fm.moveItem(at: from, to: to) }
                }
                let first = directory.appendingPathComponent("zoom.1.log")
                try? fm.removeItem(at: first); try? fm.moveItem(at: url, to: first)
            }
        }
    }

    static func log(_ message: String) { write(message) }
    static func error(_ message: String) { write("ERROR " + message) }

    private static func write(_ message: String) {
        let stamp = Self.formatter.string(from: Date())
        let line = "\(stamp) \(message)"
        NSLog("ARC Zoom: %@", message)
        queue.async {
            ring.append(line)
            if ring.count > ringMax { ring.removeFirst(ring.count - ringMax) }
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func recent(_ n: Int = 100) -> [String] {
        queue.sync { Array(ring.suffix(max(0, min(n, ringMax)))) }   // a negative n trapped the app (audit P0)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}

/// JSON string escaping, used everywhere the control API answers. Every control character is covered,
/// not only the four common ones: a participant can name themselves anything.
func jsonEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.utf8.count + 8)
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if scalar.value < 0x20 || scalar.value == 0x7F { out += String(format: "\\u%04X", scalar.value) }
            else { out.unicodeScalars.append(scalar) }
        }
    }
    return out
}

/// A float the control API can print: JSON has no NaN or infinity, so those become null.
func jsonNumber(_ v: Double) -> String { v.isFinite ? String(v) : "null" }
func jsonNumber(_ v: Float) -> String { jsonNumber(Double(v)) }
