//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import ApplicationServices
import Observation

/// One place that says whether the show is healthy (stability plan 3.2/3.3):
/// the chips on the operator footer and `/state.health` read the same struct.
/// A 1 s heartbeat on the main run loop measures its own lateness, which is
/// the main-thread lag the outputs and the clicker would feel.
@MainActor
@Observable
final class HealthMonitor {
    enum Level: String { case ok, warn, bad, off }
    struct Chip: Identifiable {
        let id: String
        let label: String
        let level: Level
        /// One line: `/state.health` and the log.
        let detail: String
        /// The hover: what the chip watches, what it says now, what to do about it.
        var help: String = ""
        /// The footer's plain words (2026-09-19: "make this section more intuitive and clear"):
        /// a full name over a state word. `label` stays the three letters the API and the log use.
        var name: String = ""
        var state: String = ""
    }

    nonisolated static let names: [String: String] = [
        "pgm": "PROGRAM", "mon": "MONITOR", "sdi": "SDI", "ppt": "POWERPOINT", "ptr": "POINTER",
        "clk": "CLICKER", "disk": "DISK", "lag": "LAG", "err": "ERROR", "zoom": "ZOOM",
    ]

    /// The state word for a chip, from what it already knows. Pure, tested.
    nonisolated static func stateWord(id: String, level: Level, detail: String, lagMs: Int = 0) -> String {
        let d = detail.lowercased()
        switch id {
        case "pgm", "mon": return [.ok: "OPEN", .bad: "HIDDEN", .warn: "NOT OPEN", .off: "NOT SET"][level] ?? ""
        case "sdi": return [.ok: "SENDING", .warn: "STALLED", .bad: "FAILED", .off: "OFF"][level] ?? ""
        case "ppt":
            switch level {
            case .off: return "NONE"
            case .bad: return "FAILED"
            case .ok: return d.contains("live") ? "LIVE" : "READY"
            case .warn: return d.contains("opening") || d.contains("open") && !d.contains("problem") ? "OPENING" : (d.contains("no fresh") ? "STALE" : "PROBLEM")
            }
        case "ptr": return "LOCKED"
        case "clk": return [.ok: "OK", .warn: "RESTART", .bad: "NO ACCESS", .off: "OFF"][level] ?? ""
        case "disk": return detail.replacingOccurrences(of: " free", with: "")
        case "lag": return "\(lagMs) MS"
        case "err": return "ERROR"
        default: return level.rawValue.uppercased()
        }
    }

    /// One tile for the app itself on the footer: the last error, else the lag, else a locked pointer, else OK.
    /// Folding the three that come and go into one that is always there keeps STATUS one width.
    var appChip: Chip {
        if let e = chips.first(where: { $0.id == "err" }) { return Chip(id: "app", label: "APP", level: .bad, detail: e.detail, help: e.help, name: "APP", state: "ERROR") }
        if let d = chips.first(where: { $0.id == "disk" }), d.level != .ok { return Chip(id: "app", label: "APP", level: d.level, detail: d.detail, help: d.help, name: "APP", state: d.level == .bad ? "DISK FULL" : "DISK LOW") }
        // Short words: the footer has no width to spare (a wider STATUS squeezed NAVIGATE and OUTPUTS, 2026-09-19); the numbers are on hover and in the window.
        if let l = chips.first(where: { $0.id == "lag" }) { return Chip(id: "app", label: "APP", level: l.level, detail: l.detail, help: l.help, name: "APP", state: "SLOW") }
        if let p = chips.first(where: { $0.id == "ptr" }) { return Chip(id: "app", label: "APP", level: .warn, detail: p.detail, help: p.help, name: "APP", state: "POINTER") }
        return Chip(id: "app", label: "APP", level: .ok, detail: "main thread on time (worst \(maxLagMs) ms this run), \(String(format: "%.0f", diskFreeGB)) GB free, no error in the last 2 min",
                    help: "APP: the app and this Mac. OK = the main thread is on time, the disk has room and nothing was logged as an error in the last two minutes. Amber for lag, a low disk or a locked pointer; red for an error or a full disk. The STATUS window has every line.",
                    name: "APP", state: "OK")
    }

    private(set) var chips: [Chip] = []
    private(set) var mainThreadLagMs = 0
    private(set) var maxLagMs = 0
    private(set) var diskFreeGB: Double = 0
    let startedAt = Date()
    var uptime: TimeInterval { Date().timeIntervalSince(startedAt) }

    /// Set by the app delegate: is the global clicker tap alive?
    @ObservationIgnored var clickerTapHealthy: () -> Bool = { false }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastBeat = Date()
    @ObservationIgnored private var lagAlarmed = false
    @ObservationIgnored private var lastDiskCheck = Date.distantPast

    func start() {
        lastBeat = Date()
        // A first figure at once from the CHEAP key (no purgeable sums), so DISK never reads 0 GB while the real one is fetched.
        if let v = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityKey]), let free = v.volumeAvailableCapacity {
            diskFreeGB = Double(free) / 1_000_000_000
        }
        timer = Timer.commonModes(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.beat() }
        }
        refresh()
    }

    private func beat() {
        let now = Date()
        let lag = max(0, Int((now.timeIntervalSince(lastBeat) - 1.0) * 1000))
        lastBeat = now
        mainThreadLagMs = lag
        maxLagMs = max(maxLagMs, lag)
        if lag >= 500, !lagAlarmed { lagAlarmed = true; ShowLog.error("main thread lag \(lag) ms") }
        if lag < 100 { lagAlarmed = false }
        refresh()
    }

    // MARK: Rules (pure, tested)

    nonisolated static func diskLevel(freeGB: Double) -> Level { freeGB >= 10 ? .ok : (freeGB >= 2 ? .warn : .bad) }
    nonisolated static func lagLevel(ms: Int) -> Level { ms < 100 ? .ok : (ms < 500 ? .warn : .bad) }
    nonisolated static func clickerLevel(accessibility: Bool, tapAlive: Bool) -> Level {
        !accessibility ? .bad : (tapAlive ? .ok : .warn)
    }

    // MARK: Refresh

    func refresh() {
        let disp = ArcPresenterApp.sharedDisplayManager
        let dl = ArcPresenterApp.sharedDeckLink
        let ppt = ArcPresenterApp.sharedPowerPoint
        let sw = ArcPresenterApp.sharedSwitchEngine
        let cap = ArcPresenterApp.sharedWindowCapture

        var list: [Chip] = []
        func outputChip(_ id: String, _ label: String, output: OutputType, assigned: ScreenIdentity?, connected: Bool) {
            let visible = NSApp.windows.contains { $0.title == output.windowTitle && $0.isVisible }
            if connected, visible, let s = assigned {
                list.append(Chip(id: id, label: label, level: .ok, detail: "\(label) on \(s.localizedName) \(s.resolution)"))
            } else if connected {
                list.append(Chip(id: id, label: label, level: .bad, detail: "\(label) reports open but its window is not visible"))
            } else if let s = assigned {
                list.append(Chip(id: id, label: label, level: .warn, detail: "\(label) assigned to \(s.localizedName) but not open (GO LIVE)"))
            } else {
                list.append(Chip(id: id, label: label, level: .off, detail: "\(label) not assigned"))
            }
        }
        outputChip("pgm", "PGM", output: .program, assigned: disp.programScreen, connected: disp.isProgramConnected)
        let dlk = ArcPresenterApp.sharedDeckLink
        CrashGuard.reconcile(programConnected: disp.isProgramConnected, displayID: disp.programScreenID,
                             sdi: dlk.isRunning ? dlk.activeDevice?.persistentID : nil, fps: dlk.fps)
        outputChip("mon", "MON", output: .confidence, assigned: disp.confidenceScreen, connected: disp.isConfidenceConnected)

        if dl.isRunning {
            list.append(Chip(id: "sdi", label: "SDI", level: dl.isStalled ? .warn : .ok,
                             detail: dl.isStalled ? (dl.status ?? "stalled") : "\(dl.activeDevice?.name ?? "SDI") sending, \(dl.sentFrames) frames, \(dl.droppedFrames) dropped"))
        } else if let st = dl.status {
            list.append(Chip(id: "sdi", label: "SDI", level: .bad, detail: st))
        } else {
            list.append(Chip(id: "sdi", label: "SDI", level: .off, detail: "SDI off"))
        }

        // ZOOM (PLAN_zoom_source build B): meeting, dual monitors, share, and FROZEN said out loud.
        let z = ArcPresenterApp.sharedZoom.chip
        list.append(Chip(id: "zoom", label: "ZOOM", level: z.level, detail: z.detail,
                         help: "Zoom beside Presenter: the meeting window, dual monitors, the share of the program picture, and whether the picked window is still rendering. " + z.detail,
                         name: "ZOOM", state: z.state))

        let pptRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: PowerPointSource.bundleID).isEmpty
        switch ppt.phase {
        case .idle:
            list.append(Chip(id: "ppt", label: "PPT", level: .off, detail: pptRunning ? "PowerPoint running, nothing parked" : "no PowerPoint parked"))
        case .opening, .starting:
            list.append(Chip(id: "ppt", label: "PPT", level: .warn, detail: ppt.progress ?? "opening in PowerPoint"))
        case .failed:
            list.append(Chip(id: "ppt", label: "PPT", level: .bad, detail: ppt.error ?? "failed"))
        case .parked:
            if sw.isPowerPointLive {
                let alive = cap.isRunning && (cap.lastFrameAt.map { Date().timeIntervalSince($0) < 5 } ?? cap.seeded)
                list.append(Chip(id: "ppt", label: "PPT", level: alive ? .ok : .warn,
                                 detail: alive ? "PowerPoint LIVE on the program output" : "PowerPoint live but no fresh picture from its window"))
            } else if ppt.isReady {
                list.append(Chip(id: "ppt", label: "PPT", level: .ok, detail: "parked and ready: \(ppt.file?.lastPathComponent ?? "")"))
            } else {
                list.append(Chip(id: "ppt", label: "PPT", level: .warn, detail: ppt.problems.first ?? "parked with a problem"))
            }
        }

        if disp.isPointerLocked {
            list.append(Chip(id: "ptr", label: "PTR", level: .warn, detail: DisplayManager.pointerLockHint))
        }

        let ax = AXIsProcessTrusted()
        let tap = clickerTapHealthy()
        let clk = Self.clickerLevel(accessibility: ax, tapAlive: tap)
        if !ArcPresenterApp.sharedSourceRouter.globalClickerOn {
            // Operator's choice (step 1b): the tile says OFF, plainly, until they turn it back on.
            list.append(Chip(id: "clk", label: "CLK", level: .off,
                             detail: "clicker OFF by the operator: the global tap drops next / previous; keys with Presenter frontmost still work. Click the tile, Cmd Opt Shift K, or POST /clicker?on=1",
                             name: "CLICKER", state: "OFF"))
        } else {
            list.append(Chip(id: "clk", label: "CLK", level: clk,
                             detail: clk == .ok ? "clicker tap live (Accessibility granted)" : (ax ? "Accessibility granted but the clicker tap is not running (re-created within 30 s)" : "Accessibility NOT granted: the clicker only works while ARC Presenter is frontmost")))
        }

        // Free space is asked for OFF the main thread, twice a minute. `volumeAvailableCapacityForImportantUsage`
        // has the system work out what it could purge (the cache_delete daemon): asked on the main actor once a
        // SECOND it held the main thread 70 to 95 ms about every other second, clicks or no clicks (measured
        // 2026-09-17: 49 of 576 /state replies over 60 ms in a minute with nobody touching it, 3,600
        // cache_delete log lines in 75 s). A clip's frames are committed on the main thread: that is a stutter.
        if Date().timeIntervalSince(lastDiskCheck) >= 30 {
            lastDiskCheck = Date()
            Task.detached(priority: .utility) { [weak self] in
                guard let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
                      let free = values.volumeAvailableCapacityForImportantUsage else { return }
                await MainActor.run { self?.diskFreeGB = Double(free) / 1_000_000_000 }
            }
        }
        list.append(Chip(id: "disk", label: "DISK", level: Self.diskLevel(freeGB: diskFreeGB), detail: String(format: "%.0f GB free", diskFreeGB)))

        let lagLevel = Self.lagLevel(ms: mainThreadLagMs)
        if lagLevel != .ok {
            list.append(Chip(id: "lag", label: "LAG", level: lagLevel, detail: "main thread late by \(mainThreadLagMs) ms (max \(maxLagMs) ms this run)"))
        }
        if let err = ShowLog.lastError, Date().timeIntervalSince(err.at) < 120 {
            list.append(Chip(id: "err", label: "ERR", level: .bad, detail: err.text))
        }
        chips = list.map { chip in
            var c = chip
            let about = Self.about[chip.id] ?? ""
            c.help = chip.id == "err" ? (Self.errorHelp(lines: ShowLog.tail(400), now: Date(), maxLagMs: maxLagMs) ?? chip.detail)
                                      : [chip.detail, about].filter { !$0.isEmpty }.joined(separator: "\n\n")
            c.name = Self.names[chip.id] ?? chip.label
            c.state = Self.stateWord(id: chip.id, level: chip.level, detail: chip.detail, lagMs: mainThreadLagMs)
            return c
        }
    }

    // MARK: Hover text (2026-09-17: "what is this error? add more info on mouse hover")

    nonisolated static let about: [String: String] = [
        "pgm": "PGM: the program output, what the room sees. Green = its window is open on its display.",
        "mon": "MON: the confidence monitor for the presenter. Green = its window is open on its display.",
        "sdi": "SDI: the program picture out of the Blackmagic device. Amber = frames are not reaching it.",
        "ppt": "PPT: PowerPoint as a live source for the switch. Grey = nothing parked (normal for an arcdeck show). Amber = opening, or parked with a problem. Red = it failed to open.",
        "clk": "CLK: the clicker and keyboard tap that drives the live deck from any app. Red = macOS Accessibility is not granted (System Settings > Privacy & Security > Accessibility). Amber = the tap is being re-created (within 30 s).",
        "disk": "DISK: free space on the system volume. Amber under 10 GB, red under 2 GB (the show state and the log stop saving when it is full).",
        "lag": "LAG: how late the app's main thread is RIGHT NOW. Over 100 ms clicks feel slow; over 500 ms it is logged as an error.",
        "ptr": "PTR: the pointer is locked to the program display.",
    ]

    /// What a kind of error MEANS for the show, by how its text starts.
    nonisolated static func meaning(of error: String) -> String {
        let e = error.lowercased()
        if e.hasPrefix("main thread lag") { return "The app stopped responding for that long. Clicks and keys WAIT and then land, the clock and this window freeze, the program output holds its last picture and SDI keeps sending it. Nothing is lost." }
        if e.hasPrefix("clip error") { return "A clip would not load or play. That slide shows its still instead of the clip; its tab carries a film marker." }
        if e.contains("session save failed") { return "The show state could not be written. A crash now would come back on older positions. Check the DISK chip and the show folder." }
        if e.hasPrefix("show:") || e.hasPrefix("open show") { return "The show folder reported a problem: a deck would not open or show.json could not be read. The decks already open are not affected." }
        if e.hasPrefix("deck ") { return "A deck loaded with something missing. It plays without the part that is named." }
        return "Logged as an error by the app. The line says what failed; the log has what led to it."
    }

    /// The ERR chip's hover, from the log's own lines (so it is tested
    /// without an app): the last error, when, how many this run, what it
    /// means, and what the app was doing just before and just after.
    nonisolated static func errorHelp(lines: [String], now: Date, maxLagMs: Int) -> String? {
        struct Line { let time: String; let text: String; let isError: Bool }
        let parsed: [Line] = lines.compactMap { l in
            let parts = l.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, parts[1].count >= 8 else { return nil }
            let text = String(parts[2])
            return Line(time: String(parts[1].prefix(8)), text: text.hasPrefix("ERROR ") ? String(text.dropFirst(6)) : text, isError: text.hasPrefix("ERROR "))
        }
        let errors = parsed.indices.filter { parsed[$0].isError }
        guard let last = errors.last else { return nil }
        // The burst the last error belongs to: errors with nothing but errors between them.
        var first = last
        while first > 0, parsed[first - 1].isError { first -= 1 }
        let before = parsed[..<first].suffix(2).map { "  \($0.time)  \($0.text)" }
        let after = parsed[(last + 1)...].filter { !$0.isError }.prefix(3).map { "  \($0.time)  \($0.text)" }
        let burst = last - first + 1
        var out = ["LAST ERROR \(parsed[last].time): \(parsed[last].text)"]
        out.append("\(errors.count) error\(errors.count == 1 ? "" : "s") this run" + (burst > 1 ? ", \(burst) in this burst from \(parsed[first].time)" : "")
                   + (maxLagMs >= 500 ? ". Worst main thread lag this run: \(maxLagMs) ms" : "") + ".")
        out.append("")
        out.append("MEANS: " + meaning(of: parsed[last].text))
        if !before.isEmpty { out.append(""); out.append("JUST BEFORE:"); out.append(contentsOf: before) }
        if !after.isEmpty {
            out.append("THEN:"); out.append(contentsOf: after)
            let text = after.joined(separator: " ").lowercased()
            if parsed[last].text.lowercased().hasPrefix("main thread lag"), text.contains("decklink") || text.contains("pgm open") || text.contains("mon open") {
                out.append(""); out.append("It happened while SDI and the outputs were starting: bring them up before doors, not during a talk.")
            }
        }
        out.append("")
        out.append("This chip clears 2 minutes after the last error. Full log: ~/Library/Logs/ARC Presenter/show.log, or GET /log.")
        return out.joined(separator: "\n")
    }

    var json: String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let rows = chips.map { "\"\($0.id)\":{\"level\":\"\($0.level.rawValue)\",\"detail\":\"\(esc($0.detail))\"}" }.joined(separator: ",")
        let err = ShowLog.lastError.map { "{\"text\":\"\(esc($0.text))\",\"at\":\"\(ISO8601DateFormatter().string(from: $0.at))\"}" } ?? "null"
        return "{\"uptime\":\(Int(uptime)),\"mainThreadLagMs\":\(mainThreadLagMs),\"maxLagMs\":\(maxLagMs),\"diskFreeGB\":\(String(format: "%.1f", diskFreeGB)),\"lastError\":\(err),\"chips\":{\(rows)}}"
    }
}
