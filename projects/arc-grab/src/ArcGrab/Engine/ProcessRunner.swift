//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Darwin

/// One child process, streamed line by line (stdout and stderr merged).
final class ProcessRunner: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private var buffer = Data()
    private let lock = NSLock()
    private(set) var terminated = false
    var pid: pid_t { process.processIdentifier }

    init(_ exe: String, _ args: [String], env: [String: String], cwd: String? = nil) {
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.environment = env
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
    }

    /// Runs to completion, calling `onLine` for every line. Returns the exit status.
    func run(onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { [weak self] fh in
                guard let self else { return }
                let chunk = fh.availableData
                if chunk.isEmpty { return }
                self.lock.lock()
                self.buffer.append(chunk)
                var lines: [String] = []
                while let nl = self.buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let lineData = self.buffer.subdata(in: self.buffer.startIndex..<nl)
                    self.buffer.removeSubrange(self.buffer.startIndex...nl)
                    if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { lines.append(s) }
                }
                self.lock.unlock()
                lines.forEach(onLine)
            }
            process.terminationHandler = { [weak self] p in
                handle.readabilityHandler = nil
                if let self {
                    self.lock.lock()
                    let rest = self.buffer
                    self.buffer.removeAll()
                    self.lock.unlock()
                    let tail = handle.readDataToEndOfFile()
                    var data = rest; data.append(tail)
                    if let s = String(data: data, encoding: .utf8) {
                        for line in s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) where !line.isEmpty {
                            onLine(String(line))
                        }
                    }
                    self.terminated = true
                }
                cont.resume(returning: p.terminationStatus)
            }
            do { try process.run() } catch {
                handle.readabilityHandler = nil
                cont.resume(throwing: error)
            }
        }
    }

    /// Stops the child AND everything it started: yt-dlp runs ffmpeg for merges and section downloads, and a
    /// SIGTERM to yt-dlp alone can leave that ffmpeg writing (and holding the pipe open). Leaves first.
    func cancel() {
        guard process.isRunning else { return }
        let root = process.processIdentifier
        let tree = ProcessRunner.descendants(of: root) + [root]
        for pid in tree { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            for pid in tree where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    /// Every live descendant of `pid`, deepest first.
    static func descendants(of pid: pid_t) -> [pid_t] {
        var buf = [pid_t](repeating: 0, count: 256)
        let n = Int(proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size)))
        guard n > 0 else { return [] }
        let children = buf.prefix(min(n, buf.count)).filter { $0 > 0 }
        return children.flatMap { descendants(of: $0) + [$0] }
    }

    /// Synchronous capture for short commands (version strings, ffprobe).
    static func capture(_ exe: String, _ args: [String], env: [String: String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
