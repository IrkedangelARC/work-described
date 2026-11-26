//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Rolling text log in ~/Library/Logs/ARC Grab/grab.log (5 MB, one rotation).
/// What a tech sends back when a grab fails on a fleet laptop.
enum GrabLog {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ARC Grab")
    static let file = dir.appendingPathComponent("grab.log")
    private static let queue = DispatchQueue(label: "com.example.arc.ArcGrab.log")
    private static let limit = 5 * 1024 * 1024
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    static func log(_ tag: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) [\(tag)] \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: file.path)[.size] as? Int, size > limit {
                let old = dir.appendingPathComponent("grab.1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: file, to: old)
            }
            if let h = FileHandle(forWritingAtPath: file.path) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? line.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }
}
