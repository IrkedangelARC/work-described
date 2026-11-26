//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AppKit

/// ARC Grab from the command line, for the other ARC apps and for Claude Code (2026-09-19: "any link
/// to a YouTube video should use ARC Grab to download and convert the video and then play it locally";
/// 2026-09-26: "add all controls to the headless mode for use by claude code").
///
/// Grabs run through the SAME GrabQueue the window uses, so every OUTPUT control behaves identically:
/// analysis, playlists, duplicate check, 2 GB free-space gate, conform, KEEP SOURCE, transcript, partial
/// cleanup. See `usage` for the flags. Output on stdout, one line per event, stable prefixes:
///
///     GRABBED <path>          delivered media (ARC Capture reads the LAST of these)
///     TRANSCRIPT <path.txt>   paragraphed transcript, with
///     SRT <path.srt>          the timed subtitles beside it
///     FAILED <why>            one per failed job; exit 1
///     ENGINE / MODELS / UPDATE lines for --status and the engine verbs
///
/// Progress goes to stderr as `STATUS <label> <phase> <pct> <title>` on every change, so stdout stays parseable.
/// Defaults match the 1.5.0 contract ARC Capture relies on: MP4 H.264, 1080, no chapters.
enum HeadlessGrab {
    static let verbs = ["--grab", "--status", "--update-engine", "--repair-engine", "--fetch-models", "--help-grab"]
    static var isRequested: Bool { CommandLine.arguments.contains { verbs.contains($0) } }

    static let usage = """
    ARC Grab headless
      --grab URL [--grab URL ...] --into DIR     download (URLs may also follow as bare words)
        --quality best|2160|1440|1080|720        video height cap (default 1080)
        --format mp4|original|prores422|proreshq|dnxhr   video delivery (default mp4)
        --audio wav|m4a|mp3                      audio only instead of video
        --transcript                             whisper.cpp: <name>.srt + <name>.txt beside the file
        --subtitles --thumbnail --chapters       extras (all off by default)
        --keep-source                            keep the download when a conform runs
        --in TIME --out TIME                     section trim (m:ss, h:mm:ss or seconds)
        --cookies chrome|safari|firefox|brave    log-in cookies from a browser
        --referer URL                            page a domain-locked player lives on
        --password PW                            Vimeo review link / Zoom recording password
        --parallel 1|2|3                         jobs at once (default 1)
        --name STEM                              rename the delivered file (single video only)
      --status                                   engine versions, models, update check
      --update-engine                            pull the newest yt-dlp (UPDATE ENGINE)
      --repair-engine                            reseed yt-dlp from the app (REPAIR)
      --fetch-models                             download the whisper + VAD models now
      --help-grab                                this text
    """

    struct UsageError: Error { let message: String }

    /// Pure flag parser (tested): options, URLs, and the verb the arguments ask for.
    struct Request: Equatable {
        enum Verb: Equatable { case grab, status, updateEngine, repairEngine, fetchModels, help }
        var verb: Verb = .grab
        var urls: [String] = []
        var options = HeadlessGrab.defaultOptions
        var parallel = 1
        var name: String?
    }

    static var defaultOptions: GrabOptions {
        var o = GrabOptions()
        o.mode = .video; o.videoFormat = .mp4; o.quality = .p1080
        o.chapters = false; o.thumbnail = false; o.subtitles = false; o.transcript = false; o.keepSource = false
        o.cookies = .none; o.referer = ""; o.videoPassword = ""; o.sectionIn = ""; o.sectionOut = ""
        o.destination = ""
        return o
    }

    static func parse(_ args: [String]) throws -> Request {
        var r = Request()
        var o = r.options
        var i = 0
        func next(_ flag: String) throws -> String {
            i += 1
            guard i < args.count, !args[i].hasPrefix("--") || flag == "--password" else { throw UsageError(message: "\(flag) needs a value") }
            return args[i]
        }
        func pick<T>(_ flag: String, _ table: [String: T]) throws -> T {
            let v = try next(flag).lowercased()
            guard let t = table[v] else { throw UsageError(message: "\(flag) \(v): expected \(table.keys.sorted().joined(separator: "|"))") }
            return t
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--grab":           r.urls.append(try next(a))
            case "--into":           o.destination = (try next(a) as NSString).expandingTildeInPath
            case "--quality":        o.quality = try pick(a, ["best": .best, "2160": .p2160, "1440": .p1440, "1080": .p1080, "720": .p720])
            case "--format":         o.mode = .video
                                     o.videoFormat = try pick(a, ["mp4": .mp4, "original": .original, "prores422": .prores422,
                                                                  "proreshq": .prores422HQ, "prores422hq": .prores422HQ,
                                                                  "dnxhr": .dnxhrHQ, "dnxhrhq": .dnxhrHQ])
            case "--audio":          o.mode = .audio
                                     o.audioFormat = try pick(a, ["wav": .wav48, "wav48": .wav48, "m4a": .m4a, "mp3": .mp3])
            case "--transcript":     o.transcript = true
            case "--subtitles":      o.subtitles = true
            case "--thumbnail":      o.thumbnail = true
            case "--chapters":       o.chapters = true
            case "--keep-source":    o.keepSource = true
            case "--in":             o.sectionIn = try next(a)
            case "--out":            o.sectionOut = try next(a)
            case "--cookies":        o.cookies = try pick(a, ["none": .none, "chrome": .chrome, "safari": .safari, "firefox": .firefox, "brave": .brave])
            case "--referer":        o.referer = try next(a)
            case "--password":       o.videoPassword = try next(a)
            case "--parallel":       r.parallel = try pick(a, ["1": 1, "2": 2, "3": 3])
            case "--name":           r.name = try next(a)
            case "--status":         r.verb = .status
            case "--update-engine":  r.verb = .updateEngine
            case "--repair-engine":  r.verb = .repairEngine
            case "--fetch-models":   r.verb = .fetchModels
            case "--help-grab":      r.verb = .help
            case _ where a.hasPrefix("http://") || a.hasPrefix("https://"): r.urls.append(a)
            case _ where a.hasPrefix("-NS") || a.hasPrefix("-Apple"):     i += 1   // AppKit launch args
            default: throw UsageError(message: "unknown argument \(a)")
            }
            i += 1
        }
        r.options = o
        guard r.verb == .grab else { return r }
        if r.urls.isEmpty { throw UsageError(message: "--grab needs a URL") }
        if o.destination.isEmpty { throw UsageError(message: "--grab needs --into DIR") }
        if r.name != nil && r.urls.count > 1 { throw UsageError(message: "--name works with one URL only") }
        return r
    }

    @MainActor
    static func run() async -> Int32 {
        let request: Request
        do { request = try parse(Array(CommandLine.arguments.dropFirst())) } catch let e as UsageError {
            print("FAILED usage: \(e.message)"); FileHandle.standardError.write(Data((usage + "\n").utf8)); return 2
        } catch { print("FAILED usage: \(error)"); return 2 }

        let queue = GrabQueue()
        queue.headless = true
        while !queue.engineChecked { try? await Task.sleep(nanoseconds: 100_000_000) }

        switch request.verb {
        case .help:
            print(usage); return 0
        case .status:
            printEngine(queue.toolchain)
            await queue.checkForEngineUpdate()
            print("UPDATE \(queue.updateAvailable ?? "none")")
            return queue.toolchain.isComplete ? 0 : 1
        case .updateEngine, .repairEngine:
            request.verb == .updateEngine ? queue.updateEngine() : queue.repairEngine()
            while queue.engineBusy || !queue.engineChecked { try? await Task.sleep(nanoseconds: 200_000_000) }
            print("ENGINE \(queue.engineMessage)")
            printEngine(queue.toolchain)
            return queue.engineMessage.contains("FAILED") || queue.engineMessage.contains("NO BUNDLED") ? 1 : 0
        case .fetchModels:
            do {
                try await ModelFetcher.ensure { label, f in
                    FileHandle.standardError.write(Data("STATUS MODELS \(label) \(f.map { "\(Int($0 * 100))%" } ?? "-")\n".utf8))
                }
            } catch { print("FAILED models: \(error.localizedDescription)"); return 1 }
            print("MODELS ready \(Toolchain.modelsDir.path)"); return 0
        case .grab:
            return await grab(request, queue: queue)
        }
    }

    @MainActor
    private static func grab(_ r: Request, queue: GrabQueue) async -> Int32 {
        guard queue.toolchain.isComplete else { print("FAILED engine missing: yt-dlp / ffmpeg · run --repair-engine"); return 1 }
        do { try FileManager.default.createDirectory(atPath: r.options.destination, withIntermediateDirectories: true) } catch {
            print("FAILED cannot create \(r.options.destination): \(error.localizedDescription)"); return 1
        }
        GrabLog.log("headless", "\(r.urls.joined(separator: " ")) -> \(r.options.destination) \(r.options.targetLabel)")
        queue.concurrency = r.parallel
        queue.add(text: r.urls.joined(separator: "\n"), options: r.options)

        // Ctrl-C / a caller's timeout: cancel through the queue so children stop and partial files go, instead
        // of dying mid-write and leaving a truncated file under the final name.
        var interrupted: Int32 = 0
        let signals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { MainActor.assumeIsolated { interrupted = sig; queue.cancelAll() } }
            src.resume()
            return src
        }
        defer { signals.forEach { $0.cancel() } }

        var seen: [UUID: String] = [:]
        while queue.jobs.isEmpty || queue.jobs.contains(where: { !$0.status.isFinished }) || queue.inFlight > 0 {
            for j in queue.jobs {
                let pct = j.fraction.map { "\(Int($0 * 100))%" } ?? "-"
                let line = "STATUS \(j.status.label) \(j.phase.isEmpty ? "-" : j.phase.replacingOccurrences(of: " ", with: "_")) \(pct) \(j.title)"
                if seen[j.id] != line { seen[j.id] = line; FileHandle.standardError.write(Data((line + "\n").utf8)) }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        var failed = 0
        for j in queue.jobs {
            switch j.status {
            case .done:
                guard var path = j.outputPath else { continue }
                var transcript = j.transcriptPath
                if let name = r.name { (path, transcript) = rename(path, transcript: transcript, to: name) }
                print("GRABBED \(path)")
                if let t = transcript {
                    print("TRANSCRIPT \(t)")
                    print("SRT \((t as NSString).deletingPathExtension + ".srt")")
                }
                GrabLog.log("headless", "GRABBED \(path)")
            case .failed(let why):
                failed += 1
                print("FAILED \(why) · \(j.sourceURL)")
                GrabLog.log("headless", "FAILED \(j.sourceURL): \(why)")
            case .cancelled:
                print("SKIPPED \(j.phase.isEmpty ? "cancelled" : j.phase) · \(j.sourceURL)")
            default: break
            }
        }
        if interrupted != 0 { print("FAILED interrupted (signal \(interrupted)), partial files removed"); return 128 + interrupted }
        return failed == 0 && queue.jobs.contains(where: { $0.status == .done }) ? 0 : 1
    }

    /// --name: the delivered file keeps its extension; a transcript pair follows it.
    private static func rename(_ path: String, transcript: String?, to stem: String) -> (String, String?) {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        let ext = (path as NSString).pathExtension
        let bare = ext.isEmpty ? stem : (stem.hasSuffix("." + ext) ? String(stem.dropLast(ext.count + 1)) : stem)
        func move(_ from: String, _ newExt: String) -> String {
            let to = (dir as NSString).appendingPathComponent(bare + "." + newExt)
            guard from != to else { return from }
            try? fm.removeItem(atPath: to)
            return (try? fm.moveItem(atPath: from, toPath: to)) != nil ? to : from
        }
        let media = move(path, ext)
        guard let t = transcript else { return (media, nil) }
        let srt = (t as NSString).deletingPathExtension + ".srt"
        if fm.fileExists(atPath: srt) { _ = move(srt, "srt") }
        return (media, move(t, "txt"))
    }

    private static func printEngine(_ t: Toolchain) {
        print("ENGINE yt-dlp \(t.ytdlpVersion) \(t.ytdlpSource.rawValue) \(t.ytdlp ?? "-")")
        print("ENGINE ffmpeg \(t.ffmpegVersion) \(t.ffmpegSource.rawValue) \(t.ffmpeg ?? "-")")
        print("ENGINE whisper-cli \(t.whisperSource.rawValue) \(t.whisper ?? "-")")
        print("MODELS \(ModelFetcher.allPresent() ? "ready" : "missing (fetched on first transcript, or --fetch-models)") \(Toolchain.modelsDir.path)")
    }
}
