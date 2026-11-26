//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// The show log both apps write: one timestamped line per event, rotated at
/// launch (five kept), a ring for an API tail, an error channel. Presenter's
/// `ShowLog` and Capture's log are thin wrappers so a show week's logs from
/// both apps read as one record.
public final class ShowLogCore: @unchecked Sendable {
    public let appName: String
    public let directory: URL
    public let url: URL
    public let keep: Int
    public let ringCapacity: Int

    private let queue: DispatchQueue
    private var ring: [String] = []
    private let lock = NSLock()
    private var _lastError: (text: String, at: Date)?
    /// When true nothing is written (the unit-test host).
    public var disabled = false
    /// Mirror lines here too (NSLog in the apps).
    public var mirror: ((String) -> Void)?

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()

    public init(appName: String, directory: URL, fileName: String = "show.log", keep: Int = 5, ringCapacity: Int = 500) {
        self.appName = appName
        self.directory = directory
        self.url = directory.appendingPathComponent(fileName)
        self.keep = keep
        self.ringCapacity = ringCapacity
        self.queue = DispatchQueue(label: "arc.showlog.\(appName.lowercased().replacingOccurrences(of: " ", with: "-"))")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var lastError: (text: String, at: Date)? {
        lock.lock(); defer { lock.unlock() }
        return _lastError
    }

    /// show.log -> show.1.log -> … -> show.<keep-1>.log. Pure on `dir`.
    public static func rotate(at dir: URL, fileName: String = "show.log", keep: Int = 5) {
        let fm = FileManager.default
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        let current = dir.appendingPathComponent(fileName)
        guard fm.fileExists(atPath: current.path) else { return }
        func numbered(_ n: Int) -> URL { dir.appendingPathComponent("\(base).\(n).\(ext)") }
        try? fm.removeItem(at: numbered(keep - 1))
        for n in stride(from: keep - 2, through: 1, by: -1) {
            let from = numbered(n)
            if fm.fileExists(atPath: from.path) { try? fm.moveItem(at: from, to: numbered(n + 1)) }
        }
        try? fm.moveItem(at: current, to: numbered(1))
    }

    /// Rotate and write the launch header. Call once.
    public func launch(version: String) {
        guard !disabled else { return }
        queue.sync {
            Self.rotate(at: directory, fileName: url.lastPathComponent, keep: keep)
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            let host = Host.current().localizedName ?? "?"
            let line = "\(Self.stamp.string(from: Date())) \(appName) \(version) launched on \(host), \(os), pid \(ProcessInfo.processInfo.processIdentifier)"
            ring.append(line)
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public func log(_ message: String) {
        mirror?(message)
        guard !disabled else { return }
        let line = "\(Self.stamp.string(from: Date())) \(message)"
        queue.async { [self] in
            ring.append(line)
            if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(Data((line + "\n").utf8)); try? handle.close()
            } else {
                try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    public func error(_ message: String) {
        lock.lock(); _lastError = (message, Date()); lock.unlock()
        log("ERROR \(message)")
    }

    public func tail(_ lines: Int) -> [String] {
        queue.sync { Array(ring.suffix(lines)) }
    }

    /// Copy the current file into a show folder's logs/ (at quit, at rotation).
    public func copy(into logsFolder: URL, as name: String? = nil) {
        queue.sync {
            let fm = FileManager.default
            try? fm.createDirectory(at: logsFolder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let dest = logsFolder.appendingPathComponent(name ?? "\(appName.lowercased().replacingOccurrences(of: " ", with: "-")).\(stamp).log")
            try? fm.copyItem(at: url, to: dest)
        }
    }
}
