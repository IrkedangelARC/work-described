import Foundation
import os

/// One line per event, to the unified log and to
/// ~/Library/Logs/ARC Show Mode/showmode.log, so "why did Show Mode drop?" on a
/// fleet Mac is answered by reading a file, not by guessing.
enum Log {
    private static let logger = Logger(subsystem: "com.example.arc.ArcShowMode", category: "showmode")
    private static let queue = DispatchQueue(label: "com.example.arc.ArcShowMode.log", qos: .utility)
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ARC Show Mode", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("showmode.log")
    }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("INFO  \(message)")
    }

    static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        append("WARN  \(message)")
    }

    private static func append(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            let url = fileURL
            rotateIfLarge(url)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Keeps one previous log. 1 MB is months of shows.
    private static func rotateIfLarge(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 1_000_000 else { return }
        let old = url.deletingPathExtension().appendingPathExtension("previous.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}
