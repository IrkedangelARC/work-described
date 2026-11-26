//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AppKit
import UserNotifications

/// The queue: analysis on add, then sequential (or 2-3 wide) download + conform.
@Observable @MainActor
final class GrabQueue {
    var jobs: [GrabJob] = []
    var toolchain = Toolchain()
    var engineChecked = false      // false while discovery + health check run
    var engineBusy = false
    var engineMessage = ""
    var updateAvailable: String?   // newer yt-dlp tag seen on GitHub
    var concurrency = 1
    /// Command-line run (HeadlessGrab): no chime, no notification.
    var headless = false
    /// `run` calls still executing. A cancelled job flips its status at once but cleans up afterwards;
    /// whoever exits (headless) waits for this to reach zero.
    private(set) var inFlight = 0

    static let minFreeBytes: Int64 = 2 * 1024 * 1024 * 1024

    @ObservationIgnored private var runners: [UUID: ProcessRunner] = [:]
    @ObservationIgnored private var analyzeTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var modelTasks: [UUID: Task<Void, Error>] = [:]
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?
    @ObservationIgnored private var doneSinceIdle = 0

    /// `startEngine: false` for a queue that will never run (the app's window queue in a headless launch):
    /// two discoveries at once would race on seeding the managed yt-dlp.
    init(startEngine: Bool = true) {
        if startEngine { refreshToolchain() }
    }

    /// Discovery is fast (paths + stamps) so the UI can queue at once; the
    /// health check that actually runs yt-dlp follows and may take ~8 s on
    /// a fresh copy. Jobs wait for it (pump gates on engineChecked).
    func refreshToolchain() {
        engineChecked = false
        Task.detached(priority: .userInitiated) { [weak self] in
            let t = Toolchain.discover()
            await MainActor.run { self?.toolchain = t }
            let checked = Toolchain.healthCheck(t)
            await MainActor.run {
                guard let self else { return }
                self.toolchain = checked
                self.engineChecked = true
                self.pump()
            }
            await self?.checkForEngineUpdate()
        }
    }

    /// Quiet GitHub lookup; only sets a badge, never installs on its own.
    func checkForEngineUpdate() async {
        guard toolchain.ytdlpSource == .managed || toolchain.ytdlpSource == .bundled else { return }
        guard let tag = try? await EngineUpdater.latestTag() else { return }
        if EngineUpdater.isNewer(tag, than: toolchain.ytdlpVersion) {
            updateAvailable = tag
            engineMessage = "UPDATE AVAILABLE \(tag)"
            GrabLog.log("engine", "update available: \(tag) (have \(toolchain.ytdlpVersion))")
        } else {
            updateAvailable = nil
        }
    }

    var activeCount: Int { jobs.filter { $0.status.isActive }.count }
    var doneCount: Int { jobs.filter { $0.status == .done }.count }
    var hasUnfinished: Bool { jobs.contains { !$0.status.isFinished } }

    // MARK: Adding

    /// Splits pasted text into URLs, one job each; playlists expand after analysis.
    @discardableResult
    func add(text: String, options: GrabOptions) -> Int {
        let urls = text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'")) }
            .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
        for u in urls {
            let job = GrabJob(sourceURL: u, options: options)
            jobs.append(job)
            GrabLog.log("add", "\(u) → \(options.targetLabel)")
            analyze(job)
        }
        return urls.count
    }

    private func analyze(_ job: GrabJob) {
        guard let ytdlp = toolchain.ytdlp else {
            job.status = .failed("yt-dlp not found")
            return
        }
        let env = toolchain.environment()
        let args = CommandBuilder.analyzeArgs(url: job.sourceURL, options: job.options)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let runner = ProcessRunner(ytdlp, args, env: env)
            let box = LineBox()
            let status = try? await runner.run { line in box.append(line) }
            let parsed = try? MediaInfo.parse(Data(box.jsonLines.utf8), sourceURL: job.sourceURL)
            let errLine = box.error
            await MainActor.run {
                guard let self, self.jobs.contains(where: { $0.id == job.id }) else { return }
                self.analyzeTasks[job.id] = nil
                guard job.status == .analyzing else { return }   // cancelled meanwhile
                guard let parsed else {
                    let failure = ErrorMapper.map(errLine ?? "analysis failed (exit \(status ?? -1))")
                    job.failureHint = failure.hint
                    job.status = .failed(failure.line)
                    GrabLog.log("analyze", "FAILED \(job.sourceURL): \(errLine ?? "exit \(status ?? -1)")")
                    return
                }
                switch parsed {
                case .single(let info):
                    job.info = info
                    if self.isDuplicate(job) {
                        job.status = .cancelled
                        job.phase = "DUPLICATE · ALREADY IN QUEUE"
                    } else {
                        job.status = .ready
                    }
                case .playlist(let pl):
                    guard let idx = self.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                    let expanded = pl.entries.map { GrabJob(sourceURL: $0.url, options: job.options, info: $0) }
                    self.jobs.replaceSubrange(idx...idx, with: expanded)
                    GrabLog.log("analyze", "playlist \(pl.title): \(expanded.count) entries")
                    if expanded.isEmpty { job.status = .failed("playlist has no entries") }
                    for j in expanded where self.isDuplicate(j) {
                        j.status = .cancelled; j.phase = "DUPLICATE · ALREADY IN QUEUE"
                    }
                }
                self.pump()
            }
        }
        analyzeTasks[job.id] = task
    }

    /// Same video (same site, same id), same target, already queued/running/done in this session.
    private func isDuplicate(_ job: GrabJob) -> Bool {
        guard let key = job.info?.duplicateKey else { return false }
        return jobs.contains { other in
            other !== job && other.info?.duplicateKey == key && other.options == job.options
                && (other.status == .ready || other.status.isActive || other.status == .done)
        }
    }

    // MARK: Running

    /// Claims the job synchronously (status flips before the task starts) so
    /// the loop cannot pick the same job twice or spin.
    func pump() {
        while engineChecked, activeCount < concurrency, let next = jobs.first(where: { $0.status == .ready }) {
            next.status = .downloading
            next.phase = "STARTING"
            Task { await run(next) }
        }
        updateSleepGuard()
        if activeCount == 0 && !jobs.contains(where: { $0.status == .ready || $0.status == .analyzing }) {
            queueDrained()
        }
    }

    private func run(_ job: GrabJob) async {
        guard job.status == .downloading else { return }
        inFlight += 1
        defer { inFlight -= 1 }
        job.startedAt = Date()
        guard toolchain.isComplete, let ytdlp = toolchain.ytdlp, let ffmpegDir = toolchain.ffmpegDir else {
            job.status = .failed("engine missing: yt-dlp / ffmpeg")
            pump(); return
        }
        let dest = job.options.destination
        do {
            try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        } catch {
            job.status = .failed("cannot create destination: \(error.localizedDescription)")
            pump(); return
        }
        if let free = freeBytes(at: dest), free < GrabQueue.minFreeBytes {
            job.status = .failed("destination has \(free / 1_048_576) MB free, need 2 GB")
            pump(); return
        }
        job.phase = "DOWNLOAD"
        job.fraction = job.options.hasSection ? nil : 0
        GrabLog.log("run", "\(job.title) → \(job.options.targetLabel) in \(dest)")

        let args = CommandBuilder.downloadArgs(url: job.sourceURL, options: job.options, ffmpegDir: ffmpegDir)
        let runner = ProcessRunner(ytdlp, args, env: toolchain.environment())
        runners[job.id] = runner
        job.appendLog("$ yt-dlp " + args.joined(separator: " "))

        let expected = Double(CommandBuilder.expectedStreams(job.options, info: job.info))
        var finishedStreams = 0.0
        // The final path and the error are read the moment the process exits, so they are collected on the
        // reader thread, not through main-actor hops that may still be queued then.
        let result = DownloadResult()

        let status = try? await runner.run { line in
            result.take(line)
            Task { @MainActor in
                if let p = ProgressParser.parseDownload(line) {
                    if p.status == "finished" {
                        finishedStreams = min(expected, finishedStreams + 1)
                        job.fraction = finishedStreams / expected
                        job.speedBytesPerSec = nil
                        job.etaSeconds = nil
                    } else if let f = p.fraction {
                        job.fraction = min(1, (finishedStreams + f) / expected)
                        job.speedBytesPerSec = p.speed
                        job.etaSeconds = p.eta
                    }
                    job.phase = finishedStreams < 1 && expected > 1 ? "VIDEO" : (expected > 1 ? "AUDIO" : "DOWNLOAD")
                    return
                }
                job.appendLog(line)
            }
        }
        runners[job.id] = nil
        await Task.yield()

        if job.status == .cancelled { cleanupPartials(job); pump(); return }
        guard status == 0, let downloaded = result.finalPath, isNonEmptyFile(downloaded) else {
            let raw = result.error ?? (result.finalPath != nil ? "output file missing or empty" : "yt-dlp exited \(status ?? -1)")
            let failure = ErrorMapper.map(raw)
            job.failureHint = failure.hint
            job.status = .failed(failure.line)
            GrabLog.log("run", "FAILED \(job.title): \(raw)")
            cleanupPartials(job)
            pump(); return
        }
        job.outputPath = downloaded
        job.speedBytesPerSec = nil
        job.etaSeconds = nil

        // Conform
        let probe = ProbeResult.probe(downloaded, toolchain: toolchain)
        job.appendLog("probe: v=\(probe.videoCodec ?? "-") a=\(probe.audioCodec ?? "-") \(probe.width ?? 0)x\(probe.height ?? 0) \(probe.duration.map { ProgressParser.formatClock($0) } ?? "?")")
        if ProbeResult.needsConform(probe, options: job.options) {
            let ok = await conform(job, input: downloaded, duration: probe.duration)
            if !ok { pump(); return }
        }
        if job.options.transcript, let delivered = job.outputPath {
            let ok = await transcribe(job, input: delivered, duration: probe.duration)
            if !ok { pump(); return }
        }
        job.fraction = 1
        job.status = .done
        job.phase = "DONE"
        doneSinceIdle += 1
        GrabLog.log("run", "DONE \(job.outputPath ?? "")")
        pump()
    }

    /// ffmpeg pass into a sibling file with the target extension; the source
    /// is removed afterwards unless KEEP SOURCE is on.
    private func conform(_ job: GrabJob, input: String, duration: Double?) async -> Bool {
        guard let ffmpeg = toolchain.ffmpeg else { job.status = .failed("ffmpeg missing"); return false }
        let o = job.options
        let inURL = URL(fileURLWithPath: input)
        let base = inURL.deletingPathExtension()
        var outURL = base.appendingPathExtension(o.finalExtension)
        let sameName = outURL.path == inURL.path
        if sameName { outURL = base.appendingPathExtension("conform." + o.finalExtension) }

        job.status = .conforming
        job.phase = o.mode == .video ? o.videoFormat.label : o.audioFormat.label
        job.fraction = duration == nil ? nil : 0

        let status = await runFFmpeg(ffmpeg, CommandBuilder.conformArgs(input: input, output: outURL.path, options: o),
                                     job: job, duration: duration)
        if job.status == .cancelled {
            try? FileManager.default.removeItem(at: outURL)
            return false
        }
        guard status == 0, isNonEmptyFile(outURL.path) else {
            try? FileManager.default.removeItem(at: outURL)
            job.status = .failed("ffmpeg exited \(status ?? -1)")
            GrabLog.log("conform", "FAILED \(job.title): exit \(status ?? -1)")
            return false
        }
        if !o.keepSource {
            try? FileManager.default.removeItem(at: inURL)
            if sameName {
                let finalURL = base.appendingPathExtension(o.finalExtension)
                try? FileManager.default.moveItem(at: outURL, to: finalURL)
                outURL = finalURL
            }
        }
        job.outputPath = outURL.path
        return true
    }

    /// One ffmpeg pass with `-progress pipe:1`: the job's bar follows out_time against `duration`, anything
    /// that is not a progress key (or says error) goes to the job log. Registered as the job's runner so
    /// CANCEL reaches it. Returns the exit status, nil when ffmpeg could not start.
    private func runFFmpeg(_ ffmpeg: String, _ args: [String], job: GrabJob, duration: Double?) async -> Int32? {
        job.appendLog("$ ffmpeg " + args.joined(separator: " "))
        let runner = ProcessRunner(ffmpeg, args, env: toolchain.environment())
        runners[job.id] = runner
        let status = try? await runner.run { line in
            Task { @MainActor in
                if let s = ProgressParser.parseFFmpegSeconds(line) {
                    if let d = duration, d > 0 { job.fraction = min(1, s / d) }
                } else if !line.contains("=") || line.lowercased().contains("error") {
                    job.appendLog(line)
                }
            }
        }
        runners[job.id] = nil
        await Task.yield()
        return status
    }

    /// whisper.cpp pass: models fetched on first use, ffmpeg makes a 16 kHz
    /// mono WAV in TMPDIR, whisper-cli writes <delivered>.srt, Transcript
    /// paragraphs it into <delivered>.txt. The delivered media file is
    /// already in place, so a failure here leaves the grab usable and the
    /// row FAILED with the reason; RETRY redoes the whole job.
    private func transcribe(_ job: GrabJob, input: String, duration: Double?) async -> Bool {
        guard let whisper = toolchain.whisper, let ffmpeg = toolchain.ffmpeg else {
            job.status = .failed("whisper-cli missing · reinstall ARC Grab")
            return false
        }
        job.status = .transcribing
        job.phase = "MODEL"
        job.fraction = nil
        job.speedBytesPerSec = nil
        job.etaSeconds = nil

        if !ModelFetcher.allPresent() {
            job.appendLog("fetching whisper models into \(Toolchain.modelsDir.path)")
            let task = Task<Void, Error> {
                try await ModelFetcher.ensure { label, f in
                    Task { @MainActor in job.phase = label; job.fraction = f }
                }
            }
            modelTasks[job.id] = task
            do { try await task.value } catch {
                modelTasks[job.id] = nil
                if job.status == .cancelled { return false }
                job.status = .failed(error.localizedDescription)
                GrabLog.log("transcript", "FAILED \(job.title): \(error.localizedDescription)")
                return false
            }
            modelTasks[job.id] = nil
            if job.status == .cancelled { return false }
        }

        let wav = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("arcgrab-\(job.id.uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        job.phase = "AUDIO"
        job.fraction = duration == nil ? nil : 0
        let wavStatus = await runFFmpeg(ffmpeg, CommandBuilder.whisperWavArgs(input: input, output: wav.path),
                                        job: job, duration: duration)
        if job.status == .cancelled { return false }
        guard wavStatus == 0, isNonEmptyFile(wav.path) else {
            job.status = .failed("audio extract for whisper exited \(wavStatus ?? -1)")
            return false
        }

        let base = URL(fileURLWithPath: input).deletingPathExtension()
        let srt = base.appendingPathExtension("srt")
        let txt = base.appendingPathExtension("txt")
        job.phase = "WHISPER"
        job.fraction = 0
        let threads = min(8, max(4, ProcessInfo.processInfo.activeProcessorCount))
        let args = CommandBuilder.whisperArgs(model: ModelFetcher.path(ModelFetcher.whisper).path,
                                              vadModel: ModelFetcher.path(ModelFetcher.vad).path,
                                              input: wav.path, outputBase: base.path, threads: threads)
        job.appendLog("$ whisper-cli " + args.joined(separator: " "))
        let runner = ProcessRunner(whisper, args, env: toolchain.environment())
        runners[job.id] = runner
        let started = Date()
        let status = try? await runner.run { line in
            Task { @MainActor in
                if let f = ProgressParser.parseWhisperProgress(line) { job.fraction = f; return }
                if line.hasPrefix("[") || line.contains("error") || line.contains("fail") { job.appendLog(line) }
            }
        }
        runners[job.id] = nil
        await Task.yield()
        if job.status == .cancelled {
            try? FileManager.default.removeItem(at: srt)
            return false
        }
        guard status == 0, isNonEmptyFile(srt.path) else {
            try? FileManager.default.removeItem(at: srt)
            job.status = .failed("whisper-cli exited \(status ?? -1)")
            GrabLog.log("transcript", "FAILED \(job.title): whisper exit \(status ?? -1)")
            return false
        }
        do {
            try Transcript.writeText(srt: srt, txt: txt)
        } catch {
            job.status = .failed("transcript text: \(error.localizedDescription)")
            return false
        }
        job.transcriptPath = txt.path
        let secs = Int(Date().timeIntervalSince(started))
        job.appendLog("transcript → \(txt.lastPathComponent) (+ .srt) in \(secs) s")
        GrabLog.log("transcript", "\(job.title): \(txt.path) in \(secs) s")
        return true
    }

    // MARK: Housekeeping

    private func isNonEmptyFile(_ path: String) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 else { return false }
        return size > 0
    }

    private func freeBytes(at path: String) -> Int64? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// yt-dlp leaves "Title [id].f137.mp4.part" style files behind on cancel or failure, and a SECTION
    /// download writes straight to the final name, so a cancelled trim left a truncated "Title [id].mp4" that
    /// looked finished (2026-09-26). Goes: anything carrying this job's id that is temp-style, or that was
    /// created after this job started and is not another job's delivery.
    func cleanupPartials(_ job: GrabJob) {
        guard let id = job.info?.id else { return }
        let fm = FileManager.default
        let dir = job.options.destination
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let others = Set(jobs.filter { $0 !== job }.compactMap(\.outputPath))
        for n in names where n.contains("[\(id)]") {
            let path = (dir as NSString).appendingPathComponent(n)
            if others.contains(path) { continue }
            if CommandBuilder.isTempName(n) || Self.created(path, since: job.startedAt) {
                try? fm.removeItem(atPath: path)
                GrabLog.log("cleanup", n)
            }
        }
    }

    private static func created(_ path: String, since start: Date?) -> Bool {
        guard let start, let c = try? FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date else { return false }
        return c >= start.addingTimeInterval(-1)
    }

    /// No idle sleep while a download or conform is running: a laptop on
    /// battery that dozes mid-grab loses the job.
    private func updateSleepGuard() {
        if activeCount > 0, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated], reason: "ARC Grab downloading")
        } else if activeCount == 0, let a = sleepActivity {
            ProcessInfo.processInfo.endActivity(a)
            sleepActivity = nil
        }
    }

    private func queueDrained() {
        guard doneSinceIdle > 0, !headless else { return }
        let n = doneSinceIdle
        doneSinceIdle = 0
        NSSound(named: "Glass")?.play()
        // UNUserNotificationCenter aborts the process outside a real app
        // bundle (xctest host), so only the app posts.
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.example.arc.ArcGrab") == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "ARC Grab"
        content.body = n == 1 ? "1 grab finished" : "\(n) grabs finished"
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: Controls

    func cancel(_ job: GrabJob) {
        if job.status == .analyzing {
            analyzeTasks[job.id]?.cancel()
            analyzeTasks[job.id] = nil
        }
        if let r = runners[job.id] {
            job.status = .cancelled
            job.phase = "CANCELLED"
            r.cancel()
        } else if let t = modelTasks[job.id] {
            job.status = .cancelled
            job.phase = "CANCELLED"
            t.cancel()
        } else if job.status == .ready || job.status == .analyzing {
            job.status = .cancelled
        }
        GrabLog.log("cancel", job.title)
        pump()
    }

    func cancelAll() {
        for j in jobs where !j.status.isFinished { cancel(j) }
    }

    /// App quit: stop every child so no orphan yt-dlp/ffmpeg keeps writing.
    func shutdown() {
        for r in runners.values { r.cancel() }
        runners.removeAll()
        for t in modelTasks.values { t.cancel() }
        modelTasks.removeAll()
        updateSleepGuard()
    }

    func retry(_ job: GrabJob) {
        guard job.status.isFinished else { return }
        job.resetForRetry()
        if job.info == nil { job.status = .analyzing; analyze(job) } else { pump() }
    }

    func remove(_ job: GrabJob) {
        if job.status.isActive { cancel(job) }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
    }

    func openTranscript(_ job: GrabJob) {
        if let p = job.transcriptPath, FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        }
    }

    func reveal(_ job: GrabJob) {
        if let p = job.outputPath, FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: job.options.destination))
        }
    }

    // MARK: Engine update / repair

    func updateEngine() {
        guard !engineBusy else { return }
        switch toolchain.ytdlpSource {
        case .managed, .bundled:
            engineBusy = true
            engineMessage = "CHECKING…"
            let env = toolchain.environment()
            let current = toolchain.ytdlpVersion
            Task { [weak self] in
                do {
                    let tag = try await EngineUpdater.latestTag()
                    guard EngineUpdater.isNewer(tag, than: current) else {
                        await MainActor.run { self?.engineBusy = false; self?.engineMessage = "ENGINE CURRENT (\(current))" }
                        return
                    }
                    let v = try await EngineUpdater.install(tag: tag, env: env) { msg in
                        Task { @MainActor in self?.engineMessage = msg }
                    }
                    await MainActor.run {
                        self?.engineBusy = false
                        self?.engineMessage = "ENGINE UPDATED TO \(v)"
                        self?.updateAvailable = nil
                        self?.refreshToolchain()
                    }
                } catch {
                    await MainActor.run {
                        self?.engineBusy = false
                        self?.engineMessage = "UPDATE FAILED · \(error.localizedDescription.uppercased())"
                    }
                    GrabLog.log("engine", "update failed: \(error.localizedDescription)")
                }
            }
        case .system:
            guard let cmd = toolchain.systemUpdateCommand() else { return }
            engineBusy = true
            engineMessage = "UPDATING…"
            let env = toolchain.environment()
            GrabLog.log("engine", "update: \(cmd.exe) \(cmd.args.joined(separator: " "))")
            Task.detached { [weak self] in
                let runner = ProcessRunner(cmd.exe, cmd.args, env: env)
                let box = LineBox()
                let status = try? await runner.run { box.append($0) }
                let last = box.lastLine
                await MainActor.run {
                    guard let self else { return }
                    self.engineBusy = false
                    self.engineMessage = status == 0 ? "ENGINE UPDATED" : "UPDATE FAILED"
                    GrabLog.log("engine", "update exit \(status ?? -1): \(last)")
                    self.refreshToolchain()
                }
            }
        case .missing:
            return
        }
    }

    /// Puts the bundled yt-dlp back as the managed copy.
    func repairEngine() {
        guard !engineBusy else { return }
        engineBusy = true
        engineMessage = "REPAIRING…"
        Task.detached { [weak self] in
            let ok = Toolchain.repairManaged()
            await MainActor.run {
                guard let self else { return }
                self.engineBusy = false
                self.engineMessage = ok ? "ENGINE RESEEDED FROM APP" : "NO BUNDLED ENGINE"
                self.refreshToolchain()
            }
        }
    }
}

/// What a yt-dlp run reports that matters after it exits: the delivered path and the last error line.
final class DownloadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var path: String?
    private var err: String?
    func take(_ line: String) {
        if let p = ProgressParser.parseFinalPath(line) { lock.lock(); path = p; lock.unlock() }
        else if let e = ProgressParser.parseError(line) { lock.lock(); err = e; lock.unlock() }
    }
    var finalPath: String? { lock.lock(); defer { lock.unlock() }; return path }
    var error: String? { lock.lock(); defer { lock.unlock() }; return err }
}

/// Thread-safe collector for a child's output lines.
final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ l: String) { lock.lock(); lines.append(l); lock.unlock() }
    var jsonLines: String {
        lock.lock(); defer { lock.unlock() }
        return lines.filter { $0.hasPrefix("{") }.joined(separator: "\n")
    }
    var error: String? {
        lock.lock(); defer { lock.unlock() }
        return lines.compactMap(ProgressParser.parseError).last
    }
    var lastLine: String {
        lock.lock(); defer { lock.unlock() }
        return lines.last ?? ""
    }
}
