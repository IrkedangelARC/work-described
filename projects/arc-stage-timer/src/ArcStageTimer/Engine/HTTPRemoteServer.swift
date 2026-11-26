//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Network
import SwiftUI

/// Lightweight HTTP server using Network.framework for remote control
/// via StreamDeck / Bitfocus Companion. All routes are GET for simplicity.
/// Also serves SSE stream for iPad stage displays.
@Observable
final class HTTPRemoteServer {

    // MARK: - Published State

    private(set) var isRunning = false
    private(set) var port: UInt16 = 8080

    // MARK: - Engine References (set by app on appear)

    #if os(macOS)

    /// Where the windows go. Set by the app so the API can move them on a headless Mac.

    var placement: DisplayPlacement?

    #endif

    weak var engine: TimerEngine?
    weak var stageDirector: StageDirector?
    var displayState: StageDisplayState?

    // MARK: - SSE Broadcaster

    let broadcaster = SSEBroadcaster()
    private var broadcastTimer: DispatchSourceTimer?

    /// Number of connected SSE display clients
    var connectedDisplayCount: Int { broadcaster.clientCount }

    // MARK: - Private

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.example.arc.httpserver", qos: .userInitiated)

    // MARK: - Lifecycle

    func start(port: UInt16 = 8080) {
        guard !isRunning else { return }
        self.port = port
        do {
            let params = NWParameters.tcp
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            listener = try NWListener(using: params, on: nwPort)
            listener?.service = NWListener.Service(name: "ARC Stage Timer", type: "_arcstage._tcp")

            listener?.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                    case .failed, .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener?.start(queue: queue)
        } catch {
            isRunning = false
        }
    }

    func stop() {
        stopBroadcastTimer()
        broadcaster.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            let request = String(data: data, encoding: .utf8) ?? ""
            let (path, query) = self.parseRequest(request)

            // SSE stream — keep connection alive, hand off to broadcaster
            if path == "/api/stream" {
                self.broadcaster.addClient(connection)
                // Send initial state immediately
                DispatchQueue.main.async {
                    let state = self.fullStateJSON()
                    self.broadcaster.broadcast(event: "state", json: state)
                }
                self.startBroadcastTimerIfNeeded()
                return
            }

            // Web stage display static files
            if path == "/stage" || path == "/stage/" {
                self.sendStaticFile(connection: connection, resource: "stage", ext: "html", contentType: "text/html")
                return
            }
            if path == "/stage.css" {
                self.sendStaticFile(connection: connection, resource: "stage", ext: "css", contentType: "text/css")
                return
            }
            if path == "/stage.js" {
                self.sendStaticFile(connection: connection, resource: "stage", ext: "js", contentType: "application/javascript")
                return
            }

            DispatchQueue.main.async {
                let response = self.route(path: path, query: query)
                self.sendResponse(connection: connection, json: response)
            }
        }
    }

    // MARK: - SSE Broadcast Timer

    private func startBroadcastTimerIfNeeded() {
        guard broadcastTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.broadcaster.clientCount > 0 else { return }
                // Sync display state from engine
                if let engine = self.engine, let director = self.stageDirector {
                    self.displayState?.syncFromLocal(engine: engine, director: director)
                }
                let json = self.fullStateJSON()
                self.broadcaster.broadcast(event: "state", json: json)
            }
        }
        timer.resume()
        broadcastTimer = timer
    }

    private func stopBroadcastTimer() {
        broadcastTimer?.cancel()
        broadcastTimer = nil
    }

    private func parseRequest(_ raw: String) -> (path: String, query: [String: String]) {
        // Parse "GET /api/status?key=val HTTP/1.1\r\n..."
        let firstLine = raw.components(separatedBy: "\r\n").first ?? raw
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return ("/", [:]) }

        let fullPath = String(parts[1])
        let components = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(components[0])
        var query: [String: String] = [:]
        if components.count > 1 {
            let pairs = components[1].split(separator: "&")
            for pair in pairs {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let key = String(kv[0])
                    let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                    query[key] = value
                }
            }
        }
        return (path, query)
    }

    // MARK: - Route Dispatch

    private func route(path: String, query: [String: String]) -> [String: Any] {
        #if os(macOS)
        // Windows and displays: answered before the engine check, because placing a window is worth doing on a
        // headless Mac that has no show loaded yet (2026-09-17: "operate it headless and put the control
        // and output on the 2nd and 3rd monitor leaving Ghostty on the primary").
        switch path {
        case "/api/displays":
            var out = displaysJSON(); out["console"] = ConsoleSnapshot.shared.mode; out["half"] = ConsoleSnapshot.shared.half
            return out
        case "/api/console":
            // PROGRAM or OPERATE, and which half of its display the console takes.
            let mode = query["mode"].flatMap { ConsoleMode(rawValue: $0.lowercased()) }
            let half = query["half"].flatMap { ConsoleHalf(rawValue: $0.lowercased()) }
            guard mode != nil || half != nil else { return ["ok": false, "error": "console needs ?mode=program|operate and/or ?half=left|right"] }
            Task { @MainActor [placement] in
                let console = ConsoleModeController.shared
                if let half { console.half = half }
                if let mode { console.set(mode) } else { placement?.restoreAssignments() }
            }
            var out = displaysJSON(); out["ok"] = true; out["pending"] = true
            out["detail"] = "console " + [mode.map { $0.label }, half.map { "on the \($0.rawValue) half" }].compactMap { $0 }.joined(separator: ", ")
            return out
        case "/api/place":
            guard let ref = query["display"] else { return ["ok": false, "error": "place needs ?display=<uuid|name|index|primary|secondary> and ?window=control|stage|confidence (stage = CONFIDENCE MONITOR, alias confidence-monitor; confidence = KEY OVERLAY, alias key-overlay)"] }
            guard let window = StageWindow(apiName: query["window"] ?? "control") else {
                return ["ok": false, "error": "window must be control, stage (confidence-monitor) or confidence (key-overlay)"]
            }
            if KeyOverlaySetting.refuses(window) { return ["ok": false, "error": KeyOverlaySetting.disabledError] }
            let full = query["full"].map { $0 == "1" || $0.lowercased() == "true" }
            let half = query["half"].flatMap { ConsoleHalf(rawValue: $0.lowercased()) }
            // Windows move on the main actor; the reply says it was accepted, and /api/displays says where things ended up.
            Task { @MainActor [placement] in placement?.place(window, onRef: ref, fullScreen: full, half: half) }
            var out = displaysJSON(); out["ok"] = true; out["pending"] = true
            out["detail"] = "moving the \(window.rawValue) window to \(ref); GET /api/displays to see where it landed"
            return out
        case "/api/assign":
            // The OUTPUTS chips over HTTP: ?window=stage|confidence|control&display=<uuid|name|index|primary|none>.
            // Records the assignment (by display identity, persisted); an output already on screen moves.
            if KeyOverlaySetting.refuses(StageWindow(apiName: query["window"] ?? "")) {
                return ["ok": false, "error": KeyOverlaySetting.disabledError]
            }
            guard let window = StageWindow(apiName: query["window"] ?? ""), StageWindow.assignable.contains(window),
                  let ref = query["display"] else {
                return ["ok": false, "error": "assign needs ?window=stage|confidence|control (or confidence-monitor|key-overlay) and ?display=<uuid|name|index|none>"]
            }
            Task { @MainActor [placement] in
                guard let placement else { return }
                if ref.lowercased() == "none" { placement.assign(window, to: nil); return }
                guard let d = DisplayPlacement.resolve(ref), let info = placement.connected.first(where: { $0.id == d.id }) else {
                    StageLog.log("assign: no display matches \"\(ref)\""); return
                }
                placement.assign(window, to: info)
            }
            var out = displaysJSON(); out["pending"] = true
            out["detail"] = "assigning \(window.rawValue) to \(ref); GET /api/displays for outputs and warnings"
            return out
        #if DEBUG
        case "/api/debug/key", "/api/debug/focus-message", "/api/debug/field", "/api/debug/cue-editor", "/api/debug/snapshot", "/api/debug/stage-shot", "/api/debug/console-shot", "/api/debug/edit-show":
            // DEBUG ONLY: real key events through NSApp.sendEvent (the path a keypress takes, menu key
            // equivalents included), to prove bare-key shortcuts never act while a text field is being edited.
            let q = query
            let work: () -> [String: Any] = {
                MainActor.assumeIsolated { DebugKeys.handle(path: path, query: q) }
            }
            return Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
        #endif
        case "/api/look":
            // The CONFIDENCE MONITOR's look: ?layout=arc|classic|bigNumber|split|clockAndTimer and/or
            // ?theme=arcDefault|highContrast|broadcast|warmAmber|daylight|paper. No query = what is set.
            let layout = query["layout"].flatMap { q in StageLayout.allCases.first { $0.rawValue.lowercased() == q.lowercased() } }
            let theme = query["theme"].flatMap { q in DisplayColorScheme.allCases.first { $0.rawValue.lowercased() == q.lowercased() } }
            if query["layout"] != nil && layout == nil || query["theme"] != nil && theme == nil {
                return ["ok": false, "error": "unknown layout or theme",
                        "layouts": StageLayout.allCases.map(\.rawValue), "themes": DisplayColorScheme.allCases.map(\.rawValue)]
            }
            let work: () -> [String: Any] = {
                MainActor.assumeIsolated {
                    guard let state = self.displayState else { return ["ok": false, "error": "no display"] }
                    if let layout { state.stageLayout = layout }
                    if let theme { state.colorScheme = theme }
                    if layout != nil || theme != nil { StageLog.log("look: \(state.stageLayout.rawValue) / \(state.colorScheme.rawValue)") }
                    return ["ok": true, "layout": state.stageLayout.rawValue, "theme": state.colorScheme.rawValue,
                            "layouts": StageLayout.allCases.map(\.rawValue), "themes": DisplayColorScheme.allCases.map(\.rawValue)]
                }
            }
            return Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
        case "/api/layout":
            // The run screen's LAYOUT chip: ?name=run|deck|widget (widget = the OPERATE console mode).
            guard let name = query["name"]?.lowercased(), let layout = RunLayout(rawValue: name) else {
                return ["ok": false, "error": "layout needs ?name=run|deck|widget"]
            }
            Task { @MainActor in
                if layout == .widget { ConsoleModeController.shared.set(.operate) }
                else {
                    if ConsoleModeController.shared.mode == .operate { ConsoleModeController.shared.set(.program) }
                    UserDefaults.standard.set(layout.rawValue, forKey: RunLayout.defaultsKey)
                }
            }
            return ["ok": true, "pending": true, "layout": layout.rawValue]
        case "/api/settings":
            // ?keyOverlay=1|0: the KEY OVERLAY (ATEM) setting. The reply carries its state either way.
            if let v = query["keyOverlay"] {
                let on = v == "1" || v.lowercased() == "true"
                Task { @MainActor [placement] in placement?.keyOverlayEnabled = on }
                var out = displaysJSON(); out["keyOverlayEnabled"] = on; out["pending"] = true
                return out
            }
            return displaysJSON()
        case "/api/golive":
            // The header GO LIVE button: ?on=1 puts STAGE and CONFIDENCE up on their displays (fallback for
            // an unassigned one), ?on=0 takes both off the air, no ?on toggles. CONTROL is never touched.
            let on: Bool? = query["on"].map { $0 == "1" || $0.lowercased() == "true" }
            var info: [String: Any] = [:]
            if let on { info["on"] = on }
            Task { @MainActor in NotificationCenter.default.post(name: .goLive, object: nil, userInfo: info) }
            var out = displaysJSON(); out["pending"] = true
            out["detail"] = on == false ? "taking the CONFIDENCE MONITOR and KEY OVERLAY off the air" : (on == true ? "GO LIVE: CONFIDENCE MONITOR (and KEY OVERLAY when it has a display) to their displays" : "toggling GO LIVE")
            return out
        case "/api/identify":
            // IDENTIFY, or ?window=stage|confidence for that output's test card.
            let which = query["window"].flatMap { StageWindow(apiName: $0) }
            if KeyOverlaySetting.refuses(which) { return ["ok": false, "error": KeyOverlaySetting.disabledError] }
            Task { @MainActor [placement] in
                guard let placement else { return }
                if let which { ArcStageTimerApp.sharedRoutingManager.testCard(which, placement) }
                else { ArcStageTimerApp.sharedRoutingManager.identifyAll(placement) }
            }
            return ["ok": true, "pending": true]
        case "/api/shows":
            return automationJSON()
        case "/api/show/test":
            let name = query["name"] ?? "ARC Style Review"
            let cues = Int(query["cues"] ?? "") ?? 3
            let open = (query["open"] ?? "1") != "0"
            var request = Automation.defaultTestShow(name: name, cues: cues)
            request.open = open
            Task { @MainActor in Automation.shared.ask(.testShow(request)) }
            var out = automationJSON(); out["pending"] = true
            out["detail"] = "building \"\(name)\" with \(cues) cue(s)" + (open ? " and opening it" : "") + "; GET /api/shows for the result"
            return out
        case "/api/show/open":
            guard let name = query["name"] else { return ["ok": false, "error": "open needs ?name=<show name>"] }
            Task { @MainActor in Automation.shared.ask(.open(name)) }
            var out = automationJSON(); out["pending"] = true
            out["detail"] = "opening \"\(name)\"; GET /api/shows for the result"
            return out
        case "/api/window/open":
            let which = (query["window"] ?? "stage").lowercased()
            if KeyOverlaySetting.refuses(StageWindow(apiName: which)) {
                return ["ok": false, "error": KeyOverlaySetting.disabledError]
            }
            let id = StageWindow(apiName: which) == .confidence ? StageWindowID.confidence : StageWindowID.stage
            Task { @MainActor in Automation.shared.ask(.openOutput(id)) }
            var out = automationJSON(); out["pending"] = true
            out["detail"] = "opening the \(which) output window"
            return out
        case "/api/show/close":
            Task { @MainActor in Automation.shared.ask(.close) }
            var out = automationJSON(); out["pending"] = true
            return out
        case "/api/offprimary":
            Task { @MainActor [placement] in
                guard let placement else { return }
                StageLog.log(placement.placeOffPrimary())
            }
            var out = displaysJSON(); out["ok"] = true; out["pending"] = true
            out["detail"] = "control to the second display, confidence monitor to the third, nothing on the primary"
            return out
        default:
            break
        }
        #endif

        guard let engine else {
            return ["error": "engine not connected", "ok": false]
        }

        switch path {
        case "/api/status":
            return statusJSON()

        case "/api/play":
            engine.start()
            return statusJSON()

        case "/api/pause":
            engine.pause()
            return statusJSON()

        case "/api/toggle":
            engine.togglePlayPause()
            return statusJSON()

        case "/api/next":
            engine.next()
            return statusJSON()

        case "/api/previous":
            engine.previous()
            return statusJSON()

        case "/api/reset":
            engine.reset()
            return statusJSON()

        case "/api/addtime":
            let seconds = Int(query["seconds"] ?? "60") ?? 60
            engine.addTime(seconds: seconds)
            return statusJSON()

        case "/api/subtracttime":
            let seconds = Int(query["seconds"] ?? "60") ?? 60
            engine.subtractTime(seconds: seconds)
            return statusJSON()

        case "/api/goto":
            let index = Int(query["cue"] ?? "0") ?? 0
            engine.goToCue(at: index)
            return statusJSON()

        case "/api/message":
            // ?text=...[&seconds=N | &hold=1]. Default 5 s, as before.
            if let text = query["text"] {
                let decoded = text.replacingOccurrences(of: "+", with: " ")
                let hold = query["hold"] == "1" || query["hold"]?.lowercased() == "true"
                let seconds = query["seconds"].flatMap(Double.init) ?? 5
                stageDirector?.sendMessage(decoded, duration: hold ? nil : seconds)
            }
            return statusJSON()

        case "/api/message/clear":
            stageDirector?.clearMessage()
            return statusJSON()

        case "/api/alert":
            // TEXT ALERT: the red banner that stays until /api/alert/clear.
            guard let text = query["text"]?.replacingOccurrences(of: "+", with: " "), !text.isEmpty else {
                return ["ok": false, "error": "alert needs ?text=..."]
            }
            stageDirector?.sendAlert(text)
            return statusJSON()

        case "/api/alert/clear":
            stageDirector?.clearAlert()
            return statusJSON()

        case "/api/flash":
            // ?color=red|yellow|green|white[&pulses=N]: one flash, or N in a row for attention.
            let colorName = query["color"] ?? "red"
            let color = colorFromName(colorName)
            if let n = query["pulses"].flatMap(Int.init), n > 1 { stageDirector?.flashForAttention(color: color, pulses: n) }
            else { stageDirector?.flash(color: color) }
            return statusJSON()

        case "/api/flash/stop":
            stageDirector?.stopFlash()
            return statusJSON()

        case "/api/clear":
            // Message, alert and flash all off the confidence monitor.
            stageDirector?.clearAll()
            return statusJSON()

        case "/api/clock":
            stageDirector?.setMode(.clock)
            return statusJSON()

        case "/api/hold":
            stageDirector?.setMode(.hold)
            return statusJSON()

        case "/api/timer":
            stageDirector?.setMode(.timer)
            return statusJSON()

        // MARK: - Live Flexibility Routes

        case "/api/shift":
            let shifted = engine.shiftScheduleToNow()
            var json = statusJSON()
            json["shiftedSeconds"] = shifted
            return json

        case "/api/addcue":
            let title = query["title"] ?? "New Cue"
            let duration = Int(query["duration"] ?? "900") ?? 900
            let afterIndex = query["after"].flatMap { Int($0) }
            let cue = Cue(
                title: title,
                sortOrder: engine.cues.count,
                durationSeconds: duration
            )
            let idx = engine.insertCue(cue, afterIndex: afterIndex)
            var json = statusJSON()
            json["insertedIndex"] = idx
            return json

        case "/api/removecue":
            let index = Int(query["index"] ?? "-1") ?? -1
            let removed = engine.removeCue(at: index)
            var json = statusJSON()
            json["removed"] = removed
            return json

        case "/api/undo":
            if engine.canUndo {
                let actionName = engine.undoActionName ?? "Unknown"
                engine.undo()
                var json = statusJSON()
                json["undone"] = true
                json["undoneAction"] = actionName
                return json
            } else {
                var json = statusJSON()
                json["undone"] = false
                json["reason"] = "Nothing to undo"
                return json
            }

        case "/api/compress":
            if let result = engine.calculateCompression() {
                engine.applyCompression(result.proposals)
                var json = statusJSON()
                json["compressed"] = true
                json["deficit"] = result.deficit
                json["recovered"] = result.proposals.reduce(0) { $0 + $1.savedSeconds }
                return json
            } else {
                var json = statusJSON()
                json["compressed"] = false
                json["reason"] = "No compression needed or possible"
                return json
            }

        case "/api/session-log":
            if let data = engine.exportSessionLog(),
               let csv = String(data: data, encoding: .utf8) {
                return ["ok": true, "csv": csv, "entries": engine.sessionLog.count]
            } else {
                return ["ok": false, "error": "No session data recorded"]
            }

        default:
            return ["error": "unknown route", "path": path, "ok": false]
        }
    }

    // MARK: - Status

    /// What the automation bridge did last, and what shows exist.
    private func automationJSON() -> [String: Any] {
        let a = AutomationSnapshot.shared.current
        return ["ok": true, "lastAction": a.lastAction, "openShow": a.openShow as Any, "shows": a.shows]
    }

    #if os(macOS)
    /// Every display this Mac has, which window sits on each, and whether this is a headless run.
    private func displaysJSON() -> [String: Any] {
        let rows = DisplaySnapshot.shared.current.map { d -> [String: Any] in
            ["index": d.index, "name": d.name, "uuid": d.uuid, "width": d.width, "height": d.height, "main": d.isMain, "windows": d.windows]
        }
        return ["ok": true, "displays": rows, "headless": StageTimerLaunch.isHeadless, "keyOverlayEnabled": KeyOverlaySetting.isEnabled,
                "outputs": DisplaySnapshot.shared.outputs, "warnings": DisplaySnapshot.shared.warnings]
    }
    #endif

    private func statusJSON() -> [String: Any] {
        guard let engine else { return ["ok": false] }
        var json: [String: Any] = [
            "ok": true,
            "state": engine.state.rawValue,
            "colorState": engine.colorState.stringValue,
            "cueIndex": engine.currentCueIndex,
            "cueTitle": engine.currentCue?.title ?? "",
            "remainingSeconds": engine.remainingSeconds,
            "elapsedSeconds": engine.elapsedSeconds,
            "displayTime": engine.displayTime,
            "isOvertime": engine.isOvertime,
            "progress": engine.progress,
            "hasNext": engine.hasNext,
            "hasPrevious": engine.hasPrevious,
            "cueCount": engine.cues.count,
            "stageMode": stageDirector?.stageMode.rawValue ?? "timer",
            "canUndo": engine.canUndo
        ]
        if let undoName = engine.undoActionName {
            json["undoActionName"] = undoName
        }
        if let nextCue = engine.nextCue {
            json["nextCueTitle"] = nextCue.title
        }
        // What the confidence monitor is showing (MESSAGE / ALERT / FLASH, 2026-09-24).
        if let d = stageDirector {
            json["message"] = d.message ?? ""
            json["messageHeld"] = d.messageHeld
            json["alert"] = d.alert ?? ""
            json["flashing"] = d.isFlashingForAttention
        }
        return json
    }

    // MARK: - Full State (for SSE broadcast — includes display fields)

    private func fullStateJSON() -> [String: Any] {
        if let state = displayState {
            return state.toJSON()
        }
        return statusJSON()
    }

    // MARK: - Helpers

    private func colorFromName(_ name: String) -> SwiftUI.Color {
        switch name.lowercased() {
        case "red": return .red
        case "yellow": return .yellow
        case "green": return .green
        case "white": return .white
        case "blue": return .blue
        default: return .red
        }
    }

    /// Serve a bundled static file (HTML/CSS/JS) for the web stage display
    private func sendStaticFile(connection: NWConnection, resource: String, ext: String, contentType: String) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext, subdirectory: "WebStageDisplay"),
              let body = try? Data(contentsOf: url) else {
            let notFound = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: notFound, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: \(contentType); charset=utf-8",
            "Content-Length: \(body.count)",
            "Access-Control-Allow-Origin: *",
            "Cache-Control: no-cache",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var response = Data(header.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Get the local network IP address for display in the UI
    static func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            guard addrFamily == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name == "en1" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let address = String(cString: hostname)
            if !address.isEmpty { return address }
        }
        return nil
    }

    private func sendResponse(connection: NWConnection, json: [String: Any]) {
        let body: Data
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
            body = data
        } else {
            body = Data("{\"error\":\"serialization failed\"}".utf8)
        }

        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Access-Control-Allow-Origin: *",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var response = Data(header.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

