//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

/// Google Slides through a dedicated Chrome and its DevTools protocol.
/// Measured 2026-09-11 on a client deck: DevTools
/// `Input.dispatchKeyEvent` ArrowRight advances the show (skipping skipped
/// slides) and `location.href` carries `slide=id.<objectId>`, both with no
/// focus change. Chrome must be launched with its own user-data-dir for
/// remote debugging; that profile is signed in once as the house account and stays
/// signed in.
///
/// 2026-09-15: the deck's facts now come out of the present page's own model
/// (`SlidesViewerData`) over that same DevTools connection, not from the
/// Slides/Drive API. The API needed a restricted OAuth scope Google hard-
/// blocks for unverified clients, which made Google Slides capture impossible
/// on any crew laptop. There is now no token, no OAuth and no Python
/// anywhere in this path — a fresh Mac needs only Chrome signed in once.
final class GoogleSlidesDriver: PresentationDriver {
    let bundleIdentifier = "com.google.Chrome"
    let displayName = "Google Slides (Chrome)"
    let windowTitleHint = "Google Slides"

    static let chromeBinary = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    static let profileDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ARC Capture/chrome-profile")

    /// Launch the capture profile on Google's sign-in page so a tech signs in
    /// as the house account ONCE on a fresh Mac; the session then persists in the
    /// profile and captures run unattended. (Readiness > CHROME PROFILE > OPEN)
    ///
    /// This is the ONLY Google sign-in ARC Capture does, and it is an ordinary
    /// browser sign-in, not OAuth: the app asks for no scopes and holds no
    /// token, so there is nothing for Google to block. `--disable-extensions`
    /// is deliberately NOT passed — the sign-in window should behave like any
    /// other Chrome window.
    static func openProfileForSignIn() {
        guard FileManager.default.isExecutableFile(atPath: chromeBinary) else { NSSound.beep(); return }
        try? FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: chromeBinary)
        p.arguments = ["--user-data-dir=\(profileDir.path)", "--profile-directory=Default",
                       "--no-first-run", "--no-default-browser-check",
                       "https://accounts.google.com/ServiceLogin?continue=https://docs.google.com/presentation/"]
        try? p.run()
    }

    /// True once the capture profile has a signed-in Google session on disk.
    /// Readiness shows this; it is a file check, not a network call.
    static var profileIsSignedIn: Bool {
        FileManager.default.fileExists(atPath: profileDir.appendingPathComponent("Default/Cookies").path)
    }

    private var chrome: Process?
    private let port = Int.random(in: 9400...9499)
    private var order: [String] = []          // objectId per 1-based slide index
    private var cdp: DevToolsClient?
    private(set) var deckTitle: String?
    private var deck: SlidesInfo?
    /// The page model the last analysis read (per-slide hashes for the show ledger).
    var slidesInfo: SlidesInfo? { deck }
    private var linkWarnings: [String] = []
    private var animationLoops: [Int: AnimatedImages.Loop] = [:]
    private var presentURL: String?

    // MARK: analysis

    func analyze(_ url: URL) -> PPTXAnalysis? {
        // Reading the page is async (launch, DevTools, evaluate); the driver
        // contract is sync and is called off the main thread by the session,
        // so block here for it.
        let box = SyncBox<Result<SlidesInfo, Error>>()
        let arg = url.isFileURL ? (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent) : url.absoluteString
        Task.detached { box.deliver(await Task { try await self.readDeck(arg) }.result) }
        let info: SlidesInfo
        switch box.wait(timeout: 90) {
        case .success(let i): info = i
        case .failure(let e):
            return PPTXAnalysis(slideCount: 0, hiddenSlides: [], videoSlides: [], autoPlaySlides: [], clickCounts: [:], autoAdvanceSlides: [:], loopingSlides: [], slideDurations: [:],
                                warnings: ["Google Slides lookup failed: \(e.localizedDescription)"])
        case .none:
            return PPTXAnalysis(slideCount: 0, hiddenSlides: [], videoSlides: [], autoPlaySlides: [], clickCounts: [:], autoAdvanceSlides: [:], loopingSlides: [], slideDurations: [:],
                                warnings: ["Google Slides lookup timed out (90 s)"])
        }
        order = info.slides.map(\.objectId)
        deck = info
        deckTitle = info.title
        presentURL = info.presentURL
        // clickCounts stays EMPTY, as it was on the API path. `docData[1][i][7]`
        // is animation data and its first element's count LOOKS like a click
        // count, but that was an inference and it is wrong: MEASURED on
        // a client deck 2026-09-15, slides 18 and 36 had the value 1 and the click
        // correctly started the movie, while slides 23 and 30 had the same
        // value 1 and the click ADVANCED THE SHOW — both slides were lost from
        // the capture (34 of 36). Same number, different meaning. Do not wire
        // this up again without measuring what [7] actually encodes.
        // A slide whose animation we measured is treated exactly like a
        // "Loop until Stopped" movie: it counts as a media slide, its hold is
        // one full loop, and the manifest entry loops until the operator
        // clicks. Recording ONE period loops seamlessly from any starting
        // phase, because a GIF is periodic.
        var videoSlides = info.videoSlides
        var durations = info.slideDurations
        var looping = Set<Int>()
        for (slide, loop) in animationLoops {
            videoSlides.insert(slide)
            looping.insert(slide)
            durations[slide] = max(durations[slide] ?? 0, loop.seconds)
        }
        var a = PPTXAnalysis(slideCount: order.count, hiddenSlides: info.hidden, videoSlides: videoSlides, autoPlaySlides: info.autoPlaySlides,
                             clickCounts: [:], autoAdvanceSlides: [:], loopingSlides: looping, slideDurations: durations, warnings: [])
        a.title = deckTitle
        a.warnings += linkWarnings
        // Lengths are not in the page model; each one is read off its own
        // slide when the show gets there (`liveVideoDuration`), so nothing is
        // "unknown" up front and there is no 30 s cap to warn about.
        return a
    }

    /// Open the deck in the capture Chrome and read the present page's own
    /// model. Leaves Chrome up and attached so `openFile` reuses it.
    private func readDeck(_ arg: String) async throws -> SlidesInfo {
        let id = try SlidesInfo.deckID(arg)
        let present = "https://docs.google.com/presentation/d/\(id)/present"
        try launchChrome(on: present)
        let client = try await attachToPresentTab()
        // Pull only what the analysis needs. Field 10 (whole-page renders) is
        // dropped; field 13, the element -> image URL map, is KEPT because it is
        // how an animated GIF is found without the Slides API — the GIF's own
        // bytes are served from that URL (measured on a client deck's slide 34: 36.6 MB,
        // 228 frames, 45.6 s loop, identical to the PPTX export's copy).
        let js = """
        (() => {
          const v = window.viewerData;
          if (!v || !v.docData || !v.docData[1]) return "";
          const rows = v.docData[1].map(r => r.map((f, j) => (j === 10) ? [] : f));
          return JSON.stringify({ slidePageCount: v.slidePageCount, title: v.title, docId: v.docId, slides: rows });
        })()
        """
        // The tab exists as soon as Chrome opens it, but present mode builds
        // viewerData a beat later, so poll for it rather than reading once.
        var raw = ""
        for _ in 0..<60 {
            raw = (try? await client.evaluateString(js)) ?? ""
            if !raw.isEmpty { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriverError.lookupFailed("the Google Slides present page exposed no deck model after 30 s (is this profile signed out, or is the deck not shared with it?)")
        }
        let info = try SlidesViewerData.parse(obj)
        DebugLog.log("Driver", "viewerData: \(info.slides.count) slides, skipped \(info.hidden.sorted()), video on \(info.videoSlides.sorted())")
        // Ask YouTube whether the deck's links are still alive, now rather than
        // on show day. A removed video plays as a static error card that
        // capture cannot tell from a silent one (a client deck's slide 9, ten minutes of
        // dead air with a clean report, 2026-09-15).
        linkWarnings = await YouTubeAvailability.deadLinkWarnings(in: info)
        for w in linkWarnings { DebugLog.log("Driver", w) }
        // An animated GIF is an IMAGE to Slides, so nothing above calls it
        // media. Measure the loop now so the slide can be recorded as one pass
        // and looped, instead of being cut short by the settle.
        animationLoops = await AnimatedImages.loopsBySlide(in: info)
        return info
    }

    // MARK: open / start

    func openFile(_ url: URL) async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.chromeBinary) else { throw DriverError.applicationNotFound("Google Chrome") }
        if order.isEmpty { _ = analyze(url) }
        guard let presentURL else {
            throw DriverError.lookupFailed("no Google Slides deck resolved from \(url.absoluteString) — the analysis above says why")
        }
        // analyze() already launched this deck in the capture Chrome; reuse it.
        if let chrome, chrome.isRunning { return }
        try launchChrome(on: presentURL)
    }

    /// Launch the capture Chrome on `target`, or do nothing if it is already
    /// up. The show window is a plain Chrome app window on a display other
    /// than the menu-bar one, like the PowerPoint show window.
    private func launchChrome(on target: String) throws {
        if let chrome, chrome.isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: Self.chromeBinary) else { throw DriverError.applicationNotFound("Google Chrome") }
        try? FileManager.default.createDirectory(at: Self.profileDir, withIntermediateDirectories: true)
        let presentURL = target
        // Kiosk window on a display other than the menu-bar one, like the
        // PowerPoint show window; the whole display, no banner, no toolbar.
        var position = "--window-position=0,0"
        var size = "--window-size=1600,900"
        let screens = NSScreen.screens
        if screens.count > 1, let main = screens.first, let showScreen = screens.first(where: { $0 != main }) {
            let f = showScreen.frame
            // 16:9 content under the app window's title bar, centred on the
            // display, like PowerPoint's show window: a display-sized window
            // letterboxed the slides (gs1 pages 90% filled, 2026-09-12).
            let w = min(1920.0, f.width), h = (w * 9 / 16).rounded() + 28
            position = "--window-position=\(Int(f.minX + (f.width - w) / 2)),\(Int(main.frame.height - f.maxY + (f.height - h) / 2))"
            size = "--window-size=\(Int(w)),\(Int(h))"
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.chromeBinary)
        p.arguments = ["--user-data-dir=\(Self.profileDir.path)", "--profile-directory=Default",
                       "--remote-debugging-port=\(port)", "--remote-allow-origins=*",
                       "--no-first-run", "--no-default-browser-check", "--disable-session-crashed-bubble", "--disable-infobars",
                       // Chrome sync pulled the Acrobat extension into the kiosk profile and its
                       // welcome tab took the whole display (2026-09-11). No extensions in the
                       // SHOW window. This is about a clean show window only — the app no longer
                       // does OAuth anywhere, so this flag cannot affect any sign-in (the 9/15
                       // field spec blamed it for the "app is blocked" page; the block was the
                       // restricted-scope client, and it reproduced in a normal Chrome).
                       "--disable-extensions", "--disable-component-extensions-with-background-pages",
                       position, size]
        // Window mode: "app" = a plain Chrome app window (no tabs, no
        // omnibox) showing /present; "kiosk" = fullscreen kiosk. Chosen by
        // ARC_CAPTURE_CHROME_MODE, default app.
        let mode = ProcessInfo.processInfo.environment["ARC_CAPTURE_CHROME_MODE"] ?? "app"
        if mode == "kiosk" { p.arguments! += ["--kiosk", presentURL] } else { p.arguments! += ["--app=\(presentURL)"] }
        DebugLog.log("Driver", "Chrome window mode: \(mode)")
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        chrome = p
        DebugLog.log("Driver", "Chrome kiosk launched (pid \(p.processIdentifier), port \(port)) on \(presentURL)")
    }

    func startSlideshow() async throws {
        _ = try await attachToPresentTab()
        try await Task.sleep(for: .milliseconds(1500))    // first slide paints, show window settles
    }

    /// Attach DevTools to the present-mode tab, or return the attachment that
    /// `analyze` already made. A redirect to accounts.google.com means the
    /// capture profile is not signed in as the house account — the one thing a fresh
    /// Mac still has to be told to do once.
    @discardableResult
    private func attachToPresentTab() async throws -> DevToolsClient {
        if let cdp { return cdp }
        let client = DevToolsClient(port: port)
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(500))
            guard let tabs = try? await client.pages() else { continue }
            if let t = tabs.first(where: { $0.url.contains("/present") }) {
                try await client.attach(to: t)
                cdp = client
                DebugLog.log("Driver", "present tab ready: \(t.title)")
                return client
            }
            if tabs.contains(where: { $0.url.contains("accounts.google.com") }) {
                throw DriverError.lookupFailed("Google Slides asked for a sign-in: open READY? › CHROME PROFILE › OPEN and sign in once with the Google account the deck is shared to")
            }
        }
        throw DriverError.slideshowNotRunning
    }

    /// The length of the video on the slide the show is on, read off the
    /// slide itself, with the element's trim applied.
    ///
    /// A DRIVE-hosted video renders in a `youtube.googleapis.com` embed whose
    /// src carries `length_seconds`. MEASURED 2026-09-15: 5.769 there against
    /// Drive's own `durationMillis` 5769 for the same file — exact. It also
    /// answers for videos the Drive API refuses with a 404 because the file
    /// itself was never shared with us (a client deck's slides 23/30/36: 29.999, 68.956
    /// and 166.599 s, where the API path had nothing and capped at 30 s).
    ///
    /// A real YOUTUBE video renders in a `www.youtube.com/embed/<id>` iframe
    /// that carries no length. It is unmeasurable here, exactly as it was
    /// unmeasurable through the Drive API, so this returns nil and the
    /// session's stop rule ends the clip when picture and sound stop.
    ///
    /// The TRIM is not in the embed URL — Slides applies it inside the player —
    /// so it comes from the deck model read at analysis time.
    func liveVideoDuration(onSlide slide: Int) async -> TimeInterval? {
        guard let cdp else { return nil }
        let js = """
        (() => {
          const s = [...document.querySelectorAll('iframe')].map(f => f.src || '')
                      .find(u => u.includes('length_seconds'));
          return s || "";
        })()
        """
        // Only a Drive-hosted video can be measured. Checking the deck model
        // first means a YouTube slide costs nothing instead of polling for an
        // embed that will never carry a length.
        guard let video = deck?.slides.first(where: { $0.index == slide })?.videos.first(where: \.isMeasurable) else {
            DebugLog.log("Driver", "slide \(slide): no Drive-hosted video here; length unmeasurable (a YouTube embed carries none)")
            return nil
        }
        // The slide paints before its embed is in the DOM — measured at 8-12 s
        // on a cold deck — and triggerVideo asks the moment the show arrives.
        // Reading once returned nil every time and cost a whole capture run
        // (2026-09-15: slide 18 fell back to the 600 s unknown-length hold).
        var src = ""
        for _ in 0..<40 {
            src = (try? await cdp.evaluateString(js)) ?? ""
            if !src.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let full = Self.fullLengthFromEmbedURL(src) else {
            DebugLog.log("Driver", "slide \(slide): '\(video.name)' is Drive-hosted but no embed length appeared in 20 s")
            return nil
        }
        let seconds = SlidesInfo.trimmed(full: full, start: video.start, end: video.end)
        if video.start > 0 || video.end > 0 {
            DebugLog.log("Driver", "slide \(slide): embed says \(full) s, trimmed to \(seconds) s (in \(video.start), out \(video.end))")
        } else {
            DebugLog.log("Driver", "slide \(slide): live video length \(seconds) s from the embed")
        }
        return seconds > 0 ? seconds : nil
    }

    /// The UNTRIMMED length a Slides video embed advertises, from the iframe's
    /// own src. Split out so it can be tested against a real captured URL.
    /// Trim is applied by the caller; it is not in this URL.
    static func fullLengthFromEmbedURL(_ src: String) -> TimeInterval? {
        guard let comps = URLComponents(string: src),
              let full = comps.queryItems?.first(where: { $0.name == "length_seconds" })?.value.flatMap(Double.init),
              full > 0 else { return nil }
        return full
    }

    // MARK: control

    private func key(_ name: String, _ code: Int) async throws {
        guard let cdp else { throw DriverError.slideshowNotRunning }
        for type in ["keyDown", "keyUp"] {
            _ = try await cdp.call("Input.dispatchKeyEvent", ["type": type, "key": name, "code": name, "windowsVirtualKeyCode": code, "nativeVirtualKeyCode": code])
        }
    }

    func advanceSlide() async throws { try await key("ArrowRight", 39) }
    func sendNextClick() async throws { try await key("ArrowRight", 39) }
    func playCurrentSlideMedia() async throws -> Int { 0 }

    func currentSlideNumber() async throws -> Int {
        guard let cdp else { return 0 }
        let r = try await cdp.call("Runtime.evaluate", ["expression": "location.href", "returnByValue": true])
        guard let result = (r["result"] as? [String: Any])?["result"] as? [String: Any], let href = result["value"] as? String else { return 0 }
        guard let m = href.range(of: #"slide=id\.([A-Za-z0-9_]+)"#, options: .regularExpression) else { return 0 }
        let id = String(href[m]).replacingOccurrences(of: "slide=id.", with: "")
        return (order.firstIndex(of: id) ?? -1) + 1
    }

    func slideCount() async throws -> Int { order.count }

    func stopSlideshow() async throws { /* the kiosk window is the show; closeFile ends it */ }

    func closeFile(_ url: URL) async throws {
        terminateChrome()
    }

    /// Shut the capture Chrome down without needing an await, so a caller that
    /// is blocking its thread (the --analyze path) can still clean up: a Task
    /// there never gets scheduled and the browser is left holding the profile
    /// lock, which makes the NEXT launch silently join the old instance with no
    /// debugging port (2026-09-15).
    func terminateChrome() {
        cdp?.close(); cdp = nil
        if let chrome, chrome.isRunning {
            chrome.terminate()
            for _ in 0..<40 { if !chrome.isRunning { break }; usleep(250_000) }
            DebugLog.log("Driver", "capture Chrome closed (still running: \(chrome.isRunning))")
        }
        chrome = nil
    }
}

/// Minimal Chrome DevTools Protocol client over URLSessionWebSocketTask.
final class DevToolsClient {
    struct Page { let id: String; let title: String; let url: String; let wsURL: String }
    private let port: Int
    private var task: URLSessionWebSocketTask?
    private var nextID = 0
    init(port: Int) { self.port = port }

    func pages() async throws -> [Page] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/json")!)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { t in
            guard (t["type"] as? String) == "page", let id = t["id"] as? String, let url = t["url"] as? String, let ws = t["webSocketDebuggerUrl"] as? String else { return nil }
            return Page(id: id, title: (t["title"] as? String) ?? "", url: url, wsURL: ws)
        }
    }

    func attach(to page: Page) async throws {
        var req = URLRequest(url: URL(string: page.wsURL)!)
        req.setValue(nil, forHTTPHeaderField: "Origin")   // Chrome rejects a browser-style Origin
        let t = URLSession.shared.webSocketTask(with: req)
        t.resume()
        task = t
        _ = try await call("Runtime.evaluate", ["expression": "1"])   // handshake check
    }

    /// Send one command and wait for its reply (replies carry our id; events do not).
    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard let task else { throw DriverError.slideshowNotRunning }
        nextID += 1
        let id = nextID
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        try await task.send(.string(String(data: body, encoding: .utf8)!))
        for _ in 0..<200 {
            let msg = try await task.receive()
            guard case .string(let s) = msg, let d = s.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if (j["id"] as? Int) == id {
                if let e = j["error"] as? [String: Any] { throw DriverError.lookupFailed("DevTools \(method): \((e["message"] as? String) ?? "error")") }
                return j
            }
        }
        throw DriverError.lookupFailed("DevTools \(method): no reply")
    }

    /// Evaluate an expression that returns a String, and hand back its value.
    /// Returns "" when the page returns nothing (a deck still loading).
    func evaluateString(_ expression: String) async throws -> String {
        let r = try await call("Runtime.evaluate", ["expression": expression, "returnByValue": true, "awaitPromise": false])
        guard let result = (r["result"] as? [String: Any])?["result"] as? [String: Any] else { return "" }
        if let details = (r["result"] as? [String: Any])?["exceptionDetails"] as? [String: Any] {
            throw DriverError.lookupFailed("page script failed: \((details["text"] as? String) ?? "error")")
        }
        return result["value"] as? String ?? ""
    }

    func close() { task?.cancel(with: .normalClosure, reason: nil); task = nil }
}


/// Blocking mailbox for a sync caller awaiting one async result.
final class SyncBox<T>: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0); private var value: T?
    func deliver(_ v: T) { value = v; sem.signal() }
    func wait(timeout: TimeInterval) -> T? { sem.wait(timeout: .now() + timeout) == .success ? value : nil }
}
