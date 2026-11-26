//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Replaces the managed yt-dlp directory with the latest GitHub release
/// (the same yt-dlp_macos.zip the build uses). Download to a staging dir,
/// verify it runs, then swap, so a failed update leaves the old copy intact.
enum EngineUpdater {
    static let latestAPI = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
    static func zipURL(_ tag: String) -> URL {
        URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/\(tag)/yt-dlp_macos.zip")!
    }

    enum UpdateError: Error, LocalizedError {
        case api(String), download(String), layout, verify, swap(String)
        var errorDescription: String? {
            switch self {
            case .api(let m): return "release lookup failed: \(m)"
            case .download(let m): return "download failed: \(m)"
            case .layout: return "unexpected zip layout"
            case .verify: return "new yt-dlp does not run"
            case .swap(let m): return "install failed: \(m)"
            }
        }
    }

    /// Newest release tag, e.g. "2026.08.19".
    static func latestTag() async throws -> String {
        var req = URLRequest(url: latestAPI)
        req.setValue("ARC-Grab", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            throw UpdateError.api("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return tag
    }

    /// yt-dlp tags are dotted dates; a plain string compare orders them.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        tag.trimmingCharacters(in: .whitespaces) > current.trimmingCharacters(in: .whitespaces)
    }

    /// Downloads and installs `tag` into managedRoot/yt-dlp. Returns the installed version.
    static func install(tag: String, managedRoot: URL = Toolchain.managedDir,
                        env: [String: String], progress: @escaping @Sendable (String) -> Void) async throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let staging = managedRoot.appendingPathComponent("yt-dlp.update")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        progress("DOWNLOADING \(tag)…")
        var req = URLRequest(url: zipURL(tag))
        req.setValue("ARC-Grab", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 120
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.download("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let zip = staging.appendingPathComponent("yt-dlp_macos.zip")
        try fm.moveItem(at: tmp, to: zip)

        progress("UNPACKING…")
        let unpack = staging.appendingPathComponent("unpacked")
        try fm.createDirectory(at: unpack, withIntermediateDirectories: true)
        let dittoStatus = try await ProcessRunner("/usr/bin/ditto", ["-x", "-k", zip.path, unpack.path], env: env).run { _ in }
        guard dittoStatus == 0 else { throw UpdateError.download("unzip exit \(dittoStatus)") }
        let exe = unpack.appendingPathComponent(Toolchain.ytdlpExe)
        let internalDir = unpack.appendingPathComponent("_internal")
        guard fm.fileExists(atPath: exe.path), fm.fileExists(atPath: internalDir.path) else { throw UpdateError.layout }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        try? fm.removeItem(at: unpack.appendingPathComponent("yt-dlp_macos.zip"))
        try tag.write(to: unpack.appendingPathComponent(Toolchain.versionFile), atomically: true, encoding: .utf8)

        progress("VERIFYING (first run is slow)…")
        guard let v = Toolchain.version(of: exe.path, env: env), !v.isEmpty else { throw UpdateError.verify }

        progress("INSTALLING…")
        let dst = managedRoot.appendingPathComponent("yt-dlp")
        let old = managedRoot.appendingPathComponent("yt-dlp.old")
        do {
            try? fm.removeItem(at: old)
            if fm.fileExists(atPath: dst.path) { try fm.moveItem(at: dst, to: old) }
            try fm.moveItem(at: unpack, to: dst)
            try? fm.removeItem(at: old)
        } catch {
            if !fm.fileExists(atPath: dst.path), fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: dst) }
            throw UpdateError.swap(error.localizedDescription)
        }
        GrabLog.log("engine", "updated managed yt-dlp to \(v)")
        return v
    }
}
