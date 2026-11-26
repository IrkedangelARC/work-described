//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Locates the engine binaries.
///
/// Production order (fleet): ffmpeg/ffprobe from the app bundle (static,
/// pinned at build time); yt-dlp from the managed directory in Application
/// Support, seeded from the bundle's onedir copy and replaced in place by
/// EngineUpdater, so a YouTube change is fixed by UPDATE ENGINE and not by
/// a rebuild. Dev fallback: Homebrew / pip installs, for test bundles and
/// builds that carry no engine. The app is launched from Finder with a bare
/// PATH, so every path is explicit; nothing here relies on the login shell.
struct Toolchain: Equatable {
    enum Source: String { case managed = "MANAGED", bundled = "BUNDLED", system = "SYSTEM", missing = "MISSING" }

    var ytdlp: String?
    var ffmpeg: String?
    var ffprobe: String?
    var whisper: String?
    var ytdlpSource: Source = .missing
    var ffmpegSource: Source = .missing
    var whisperSource: Source = .missing
    var ytdlpVersion: String = "?"
    var ffmpegVersion: String = "?"

    var isComplete: Bool { ytdlp != nil && ffmpeg != nil && ffprobe != nil }
    var ffmpegDir: String? { ffmpeg.map { ($0 as NSString).deletingLastPathComponent } }

    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let appSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ARC Grab")
    static let managedDir = appSupport.appendingPathComponent("engine")
    /// Whisper + VAD models, fetched on the first transcript (ModelFetcher).
    static let modelsDir = appSupport.appendingPathComponent("models")
    static let whisperExe = "whisper-cli"
    static let ytdlpExe = "yt-dlp_macos"
    static let versionFile = "VERSION"

    /// ffmpeg/ffprobe sit next to the main executable; the yt-dlp onedir is
    /// in Contents/Resources/yt-dlp (tools/ship.sh puts it there and signs
    /// every Mach-O inside; Contents/Helpers would demand proper bundles).
    static var bundledExeDir: URL? { Bundle.main.executableURL?.deletingLastPathComponent() }
    static var bundledYtdlpDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("yt-dlp")
    }

    static func bundled(_ name: String) -> String? {
        guard let p = bundledExeDir?.appendingPathComponent(name).path,
              FileManager.default.isExecutableFile(atPath: p) else { return nil }
        return p
    }

    /// Reads the VERSION stamp a yt-dlp directory carries (build or updater writes it).
    static func dirVersion(_ dir: URL) -> String? {
        (try? String(contentsOf: dir.appendingPathComponent(versionFile), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isYtdlpDir(_ dir: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent(ytdlpExe).path)
    }

    static func systemCandidates(_ name: String) -> [String] {
        var list: [String] = []
        let pyRoot = "\(home)/Library/Python"
        if let vers = try? FileManager.default.contentsOfDirectory(atPath: pyRoot) {
            for v in vers.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                list.append("\(pyRoot)/\(v)/bin/\(name)")
            }
        }
        list += ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)"]
        return list
    }

    static func system(_ name: String) -> String? {
        systemCandidates(name).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Copies the bundled yt-dlp directory into the managed dir when there is
    /// none, or when the bundle carries a newer version than the managed copy
    /// (a new app release must never leave an older binary in place, and must
    /// never downgrade one the updater took past it). Returns the managed dir.
    @discardableResult
    static func seedManagedYtdlp(bundledDir: URL, managedRoot: URL = Toolchain.managedDir) -> URL? {
        let fm = FileManager.default
        let dst = managedRoot.appendingPathComponent("yt-dlp")
        let bundledVersion = dirVersion(bundledDir) ?? "0"
        let managedVersion = dirVersion(dst)
        let needs = !isYtdlpDir(dst) || managedVersion == nil || managedVersion! < bundledVersion
        guard needs else { return dst }
        do {
            try fm.createDirectory(at: managedRoot, withIntermediateDirectories: true)
            let staging = managedRoot.appendingPathComponent("yt-dlp.seeding")
            try? fm.removeItem(at: staging)
            try fm.copyItem(at: bundledDir, to: staging)
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: staging, to: dst)
            GrabLog.log("engine", "seeded managed yt-dlp \(bundledVersion) (was \(managedVersion ?? "none"))")
            return dst
        } catch {
            GrabLog.log("engine", "seed failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fast: paths and version stamps only. `healthCheck` runs the binaries.
    static func discover() -> Toolchain {
        var t = Toolchain()
        if let f = bundled("ffmpeg"), let p = bundled("ffprobe") {
            t.ffmpeg = f; t.ffprobe = p; t.ffmpegSource = .bundled
        } else if let f = system("ffmpeg"), let p = system("ffprobe") {
            t.ffmpeg = f; t.ffprobe = p; t.ffmpegSource = .system
        }
        if let w = bundled(whisperExe) {
            t.whisper = w; t.whisperSource = .bundled
        } else if let w = system(whisperExe) {
            t.whisper = w; t.whisperSource = .system
        }
        if let b = bundledYtdlpDir, isYtdlpDir(b) {
            if let m = seedManagedYtdlp(bundledDir: b) {
                t.ytdlp = m.appendingPathComponent(ytdlpExe).path; t.ytdlpSource = .managed
                t.ytdlpVersion = dirVersion(m) ?? "?"
            } else {
                t.ytdlp = b.appendingPathComponent(ytdlpExe).path; t.ytdlpSource = .bundled
                t.ytdlpVersion = dirVersion(b) ?? "?"
            }
        } else if isYtdlpDir(managedDir.appendingPathComponent("yt-dlp")) {
            let m = managedDir.appendingPathComponent("yt-dlp")
            t.ytdlp = m.appendingPathComponent(ytdlpExe).path; t.ytdlpSource = .managed
            t.ytdlpVersion = dirVersion(m) ?? "?"
        } else if let y = system("yt-dlp") {
            t.ytdlp = y; t.ytdlpSource = .system
        }
        if let f = t.ffmpeg, let out = try? ProcessRunner.capture(f, ["-version"], env: t.environment()),
           let first = out.split(separator: "\n").first {
            t.ffmpegVersion = first.split(separator: " ").dropFirst(2).first.map(String.init) ?? "?"
        } else if t.ffmpeg != nil {
            t.ffmpeg = nil; t.ffprobe = nil; t.ffmpegSource = .missing
        }
        GrabLog.log("engine", "yt-dlp \(t.ytdlpVersion) [\(t.ytdlpSource.rawValue)] \(t.ytdlp ?? "-") · ffmpeg \(t.ffmpegVersion) [\(t.ffmpegSource.rawValue)] \(t.ffmpeg ?? "-") · whisper [\(t.whisperSource.rawValue)] \(t.whisper ?? "-") · models \(ModelFetcher.allPresent() ? "ready" : "not fetched")")
        return t
    }

    /// Runs yt-dlp --version. Slow on the first run of a fresh copy (macOS
    /// scans ~100 new Mach-O files once, ~8 s), 0.2 s after that. A binary
    /// that cannot report a version is dropped so the UI says MISSING.
    static func healthCheck(_ t: Toolchain) -> Toolchain {
        var t = t
        if let y = t.ytdlp {
            if let v = version(of: y, env: t.environment()) {
                t.ytdlpVersion = v
            } else {
                GrabLog.log("engine", "yt-dlp health check FAILED at \(y)")
                t.ytdlp = nil; t.ytdlpSource = .missing; t.ytdlpVersion = "?"
            }
        }
        return t
    }

    static func version(of ytdlp: String, env: [String: String]) -> String? {
        guard let out = try? ProcessRunner.capture(ytdlp, ["--version"], env: env) else { return nil }
        let v = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// Environment for child processes: HOME (yt-dlp cache), TMPDIR and a
    /// PATH that includes ffmpeg's directory and, for a pip install, the
    /// Python that owns the script.
    func environment() -> [String: String] {
        var path = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let d = ffmpegDir { path.insert(d, at: 0) }
        if let py = pythonForYtdlp() { path.insert((py as NSString).deletingLastPathComponent, at: 0) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path.joined(separator: ":")
        env["HOME"] = Toolchain.home
        env["TMPDIR"] = env["TMPDIR"] ?? NSTemporaryDirectory()
        env["LC_ALL"] = "en_US.UTF-8"
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }

    /// The interpreter named in the yt-dlp script's shebang, when it is a pip install.
    func pythonForYtdlp() -> String? {
        guard ytdlpSource == .system, let y = ytdlp, let fh = FileHandle(forReadingAtPath: y) else { return nil }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 200)
        guard let line = String(data: head, encoding: .utf8)?.split(separator: "\n").first,
              line.hasPrefix("#!") else { return nil }
        let interp = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        let parts = interp.split(separator: " ")
        if parts.first?.hasSuffix("/env") == true { return nil }
        return parts.first.map(String.init)
    }

    /// System-install upgrade command (dev machines). Managed copies go
    /// through EngineUpdater instead.
    func systemUpdateCommand() -> (exe: String, args: [String])? {
        guard ytdlpSource == .system, let y = ytdlp else { return nil }
        if y.hasPrefix("/opt/homebrew/") || y.hasPrefix("/usr/local/Cellar") {
            let brew = y.hasPrefix("/opt/homebrew/") ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
            return (brew, ["upgrade", "yt-dlp"])
        }
        if let py = pythonForYtdlp() {
            return (py, ["-m", "pip", "install", "--user", "--upgrade", "yt-dlp"])
        }
        return (y, ["-U"])
    }

    /// Puts the bundled yt-dlp back as the managed copy (REPAIR after a bad update).
    static func repairManaged() -> Bool {
        guard let b = bundledYtdlpDir, isYtdlpDir(b) else { return false }
        try? FileManager.default.removeItem(at: managedDir.appendingPathComponent("yt-dlp"))
        return seedManagedYtdlp(bundledDir: b) != nil
    }
}
