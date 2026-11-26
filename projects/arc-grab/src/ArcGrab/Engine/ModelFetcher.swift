//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Whisper models are not in the app (574 MB would triple the zip); they are
/// fetched once into ~/Library/Application Support/ARC Grab/models on the
/// first transcript and kept. Download goes to a .part file next to the
/// target and is moved into place only when the byte count matches, so a
/// dropped connection leaves nothing half-written under the real name.
enum ModelFetcher {
    struct Model: Equatable, Sendable {
        let file: String
        let repo: String
        /// Refuse anything smaller: Hugging Face answers a missing file with a
        /// 15-byte "Entry not found" body and HTTP 200-ish semantics on some
        /// paths, and a truncated download is not a model either.
        let minBytes: Int64
        var url: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")! }
    }

    /// large-v3-turbo, 5-bit: near large-v3 accuracy at a fraction of the
    /// decode cost, ~1 GB resident on Metal, fine on a 16 GB laptop.
    static let whisper = Model(file: "ggml-large-v3-turbo-q5_0.bin", repo: "ggerganov/whisper.cpp", minBytes: 500_000_000)
    /// Silero VAD lives in its own repo, not next to the whisper weights.
    static let vad = Model(file: "ggml-silero-v5.1.2.bin", repo: "ggml-org/whisper-vad", minBytes: 500_000)
    static let all = [whisper, vad]

    enum FetchError: Error, LocalizedError {
        case http(Int), short(String, Int64), cancelled, io(String)
        var errorDescription: String? {
            switch self {
            case .http(let c): return "model download failed: HTTP \(c)"
            case .short(let f, let n): return "\(f) came back short (\(n / 1_048_576) MB)"
            case .cancelled: return "model download cancelled"
            case .io(let m): return "model install failed: \(m)"
            }
        }
    }

    static func path(_ m: Model, in dir: URL = Toolchain.modelsDir) -> URL { dir.appendingPathComponent(m.file) }

    static func isPresent(_ m: Model, in dir: URL = Toolchain.modelsDir) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path(m, in: dir).path)[.size] as? Int64 else { return false }
        return size >= m.minBytes
    }

    static func allPresent(in dir: URL = Toolchain.modelsDir) -> Bool { all.allSatisfy { isPresent($0, in: dir) } }

    /// Downloads every missing model. `progress(label, fraction)` is called
    /// per chunk; fraction is nil until the server states a length.
    static func ensure(in dir: URL = Toolchain.modelsDir,
                       progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for m in all where !isPresent(m, in: dir) {
            try await fetch(m, in: dir, progress: progress)
        }
    }

    static func fetch(_ m: Model, in dir: URL, progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        let fm = FileManager.default
        let dst = path(m, in: dir)
        let part = dst.appendingPathExtension("part")
        try? fm.removeItem(at: part)
        guard fm.createFile(atPath: part.path, contents: nil) else { throw FetchError.io("cannot create \(part.lastPathComponent)") }
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close(); try? fm.removeItem(at: part) }

        var req = URLRequest(url: m.url)
        req.setValue("ARC-Grab", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 60
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let code = (resp as? HTTPURLResponse)?.statusCode, code == 200 else {
            throw FetchError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let expected = resp.expectedContentLength
        let label = m == whisper ? "WHISPER MODEL" : "VAD MODEL"
        var written: Int64 = 0
        var chunk = Data(); chunk.reserveCapacity(1 << 20)
        var lastReport = Date.distantPast
        progress(label, expected > 0 ? 0 : nil)
        for try await b in bytes {
            chunk.append(b)
            if chunk.count >= 1 << 20 {
                if Task.isCancelled { throw FetchError.cancelled }
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                chunk.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastReport) > 0.25 {
                    lastReport = Date()
                    progress(label, expected > 0 ? Double(written) / Double(expected) : nil)
                }
            }
        }
        if !chunk.isEmpty { try handle.write(contentsOf: chunk); written += Int64(chunk.count) }
        try handle.close()
        guard written >= m.minBytes, expected <= 0 || written == expected else { throw FetchError.short(m.file, written) }
        do {
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: part, to: dst)
        } catch { throw FetchError.io(error.localizedDescription) }
        GrabLog.log("model", "fetched \(m.file) (\(written / 1_048_576) MB)")
        progress(label, 1)
    }
}
