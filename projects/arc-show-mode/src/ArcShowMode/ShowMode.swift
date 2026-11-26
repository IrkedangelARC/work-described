import AppKit

/// What Show Mode changed, kept on disk so a crash or a reboot mid-show can neither drop
/// the protection nor forget what to put back.
struct ShowSession: Codable, Equatable {
    var startedAt: Date
    /// Apps that were running at engage and were closed; relaunched (hidden) at release.
    var closedBundleIDs: [String]
    /// Alert volume before Show Mode zeroed it; nil if it could not be read.
    var priorAlertVolume: Int?

    private static let key = "activeSession"

    static func load(_ defaults: UserDefaults = .standard) -> ShowSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ShowSession.self, from: data)
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

/// The engine. Engage closes the interrupting apps, sets Do Not Disturb, mutes alert
/// sounds and holds the Mac awake; while engaged it re-closes any of those apps that
/// relaunch. Release puts everything back.
final class ShowMode {

    struct Check {
        let ok: Bool
        let text: String
    }

    private(set) var session: ShowSession?
    private(set) var checks: [Check] = []
    private(set) var busy = false
    var onChange: (() -> Void)?

    var isEngaged: Bool { session != nil }

    private let sleepGuard = SleepGuard()
    private var launchObserver: NSObjectProtocol?
    private let work = DispatchQueue(label: "com.example.arc.ArcShowMode.focus", qos: .userInitiated)

    /// A session on disk means the app went down while engaged: re-arm, keep the
    /// original restore data.
    func resumeIfNeeded() {
        guard let saved = ShowSession.load() else { return }
        let age = Date().timeIntervalSince(saved.startedAt)
        if age > Self.staleAfter {
            // Shut down without Release, then booted days later: put things back, do not re-arm.
            Log.warn("found a session from \(Int(age / 3600))h ago on disk; too old to be a live show, releasing it instead of resuming")
            session = saved
            releaseForQuit()
            return
        }
        session = saved
        Log.warn("resumed a session that was still on disk at launch (started \(saved.startedAt)): the app went down while engaged")
        arm()
    }

    /// No show runs this long. A session older than this at launch is leftover, not live.
    static let staleAfter: TimeInterval = 18 * 3600

    func engage() {
        guard !isEngaged, !busy else { return }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let toClose = QuitPolicy.toClose(running: running, extra: QuitPolicy.userExtra, keep: QuitPolicy.userKeep)
        let prior = AlertVolume.current()
        session = ShowSession(startedAt: Date(), closedBundleIDs: toClose, priorAlertVolume: prior)
        session?.save()
        Log.info("ENGAGE closing=[\(toClose.joined(separator: ","))] priorAlertVolume=\(prior.map(String.init) ?? "unknown")")
        arm()
    }

    func release() {
        guard let ended = session, !busy else { return }
        Log.info("RELEASE after \(Int(Date().timeIntervalSince(ended.startedAt)))s, relaunching=[\(ended.closedBundleIDs.joined(separator: ","))]")
        stopEnforcing()
        sleepGuard.release()
        if let prior = ended.priorAlertVolume { AlertVolume.set(prior) } else { AlertVolume.set(100); Log.warn("prior alert volume unknown, set to 100") }
        relaunchHidden(ended.closedBundleIDs)
        session = nil
        ShowSession.clear()
        checks = []
        busy = true
        onChange?()
        work.async { [weak self] in
            let focus = Focus.set(false)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if !focus.ok {
                    Log.warn("focus off failed: \(focus.message)")
                    self.checks = [Check(ok: false, text: "Focus: \(focus.message)")]
                }
                self.onChange?()
            }
        }
    }

    /// Synchronous release for app quit: the run loop is going away.
    func releaseForQuit() {
        guard let ended = session else { return }
        Log.info("RELEASE on quit after \(Int(Date().timeIntervalSince(ended.startedAt)))s")
        stopEnforcing()
        sleepGuard.release()
        if let prior = ended.priorAlertVolume { AlertVolume.set(prior) }
        relaunchHidden(ended.closedBundleIDs)
        ShowSession.clear()
        session = nil
        _ = Focus.set(false)
    }

    // MARK: - Arm

    private func arm() {
        startEnforcing()
        closeTargetsRunningNow()
        sleepGuard.hold()
        let muted = AlertVolume.set(0)
        busy = true
        checks = [Check(ok: true, text: "Applying…")]
        onChange?()

        work.async { [weak self] in
            let haveShortcuts = Focus.installed()
            let focus = haveShortcuts ? Focus.set(true)
                                      : Focus.Result(ok: false, message: "not set up. Use Set Up Do Not Disturb…")
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                // A polite quit takes a few seconds to land; the first pass reports
                // "Closing", only the pass after the straggler sweep reports "Still open".
                self.refreshChecks(focus: focus, muted: muted, final: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    self?.finishStragglers(focus: focus, muted: muted)
                }
            }
        }
    }

    private func refreshChecks(focus: Focus.Result, muted: Bool, final: Bool = true) {
        guard isEngaged else { return }
        let targets = QuitPolicy.targets(extra: QuitPolicy.userExtra, keep: QuitPolicy.userKeep)
        let stillOpen = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier.map(targets.contains) ?? false }
            .map { $0.localizedName ?? $0.bundleIdentifier ?? "?" }
        let closedNames = (session?.closedBundleIDs ?? []).map(Self.displayName)

        var list: [Check] = []
        list.append(Check(ok: focus.ok, text: "Focus: \(focus.message)"))
        if stillOpen.isEmpty {
            list.append(Check(ok: true, text: closedNames.isEmpty ? "Apps: nothing to close"
                                                                  : "Closed: \(closedNames.joined(separator: ", "))"))
        } else if !final {
            list.append(Check(ok: true, text: "Closing: \(stillOpen.joined(separator: ", "))…"))
        } else {
            list.append(Check(ok: false, text: "Still open: \(stillOpen.joined(separator: ", "))"))
        }
        list.append(Check(ok: true, text: "Watching: relaunches are closed again"))
        list.append(Check(ok: sleepGuard.isHeld, text: sleepGuard.isHeld ? "Display sleep blocked" : "Sleep block FAILED"))
        list.append(Check(ok: muted, text: muted ? "Alert sounds muted" : "Alert sounds NOT muted"))
        checks = list
        for check in list where !check.ok { Log.warn(check.text) }
        onChange?()
    }

    private func finishStragglers(focus: Focus.Result, muted: Bool) {
        guard isEngaged else { return }
        let targets = QuitPolicy.targets(extra: QuitPolicy.userExtra, keep: QuitPolicy.userKeep)
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, targets.contains(id), QuitPolicy.isForce(id) else { continue }
            app.forceTerminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshChecks(focus: focus, muted: muted)
        }
    }

    // MARK: - Closing apps

    private func closeTargetsRunningNow() {
        let targets = QuitPolicy.targets(extra: QuitPolicy.userExtra, keep: QuitPolicy.userKeep)
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, targets.contains(id) else { continue }
            close(app)
        }
    }

    /// An app still finishing its launch ignores terminate() (measured: TextEdit relaunched
    /// mid-show stayed up), so keep asking until it is gone or Show Mode is released.
    private func close(_ app: NSRunningApplication, attempt: Int = 0) {
        guard let id = app.bundleIdentifier, !app.isTerminated, isEngaged else { return }
        if attempt == 0 { Log.info("close \(id) (\(QuitPolicy.isForce(id) ? "force" : "quit"))") }
        if attempt == 10 { Log.warn("\(id) is still running after 10 close attempts") }
        if QuitPolicy.isForce(id) { app.forceTerminate() } else { app.terminate() }
        guard attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.close(app, attempt: attempt + 1)
        }
    }

    private func startEnforcing() {
        guard launchObserver == nil else { return }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, self.isEngaged,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let id = app.bundleIdentifier,
                      QuitPolicy.targets(extra: QuitPolicy.userExtra, keep: QuitPolicy.userKeep).contains(id)
                else { return }
                self.close(app)
        }
    }

    private func stopEnforcing() {
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
    }

    /// Hidden and in the background: a release during a show must not throw Mail's
    /// window onto the projector.
    private func relaunchHidden(_ ids: [String]) {
        for id in ids {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }

    static func displayName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
