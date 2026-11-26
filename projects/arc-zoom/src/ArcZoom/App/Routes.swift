//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import SwiftUI
import ZoomSDK

// The control API on 127.0.0.1:8766 as a TABLE (PLAN_stability_refactor.md step 12): one `Route` per
// method + path with a one-line doc, grouped by area. `GET /routes` prints this table, so the docs cannot
// drift from the code. Handlers are async (step 14): a route that acts waits for the action and answers
// with the state as it is afterwards, 200 or 409, never 202 for something that has not happened yet.

/// The query string, decoded (`+` and %XX), with the id helper every people-route uses.
struct Query {
    let raw: [String: String]
    init(_ raw: [String: String]) { self.raw = raw }
    subscript(_ key: String) -> String? { raw[key] }
    func user(_ key: String = "user") -> UInt32? { raw[key].flatMap { UInt32($0) } }
}

struct Route {
    let method: String
    let path: String
    let doc: String
    let handler: @MainActor (Sidecar, Query) async -> (Int, String)
    init(_ method: String, _ path: String, _ doc: String, _ handler: @escaping @MainActor (Sidecar, Query) async -> (Int, String)) {
        self.method = method; self.path = path; self.doc = doc; self.handler = handler
    }
}

@MainActor
func ok() -> (Int, String) { (200, ArcZoomApp.sharedSidecar.stateJSON) }
func bad(_ why: String) -> (Int, String) { (400, "{\"error\":\"\(jsonEscape(why))\"}") }

@MainActor
enum Routes {
    static let all: [Route] = meeting + outputs + audio + share + preview + text + system + rehearsal
    static let byKey: [String: Route] = Dictionary(all.map { ("\($0.method) \($0.path)", $0) }, uniquingKeysWith: { a, _ in a })

    /// The table, for Companion and for the next reader.
    static var listJSON: String {
        let rows = all.map { "{\"method\":\"\($0.method)\",\"path\":\"\($0.path)\",\"doc\":\"\(jsonEscape($0.doc))\"}" }.joined(separator: ",")
        return "{\"routes\":[\(rows)]}"
    }

    static func dispatch(method: String, path: String, query: [String: String]) async -> (Int, String) {
        if method == "GET", path == "/routes" { return (200, listJSON) }
        guard let route = byKey["\(method) \(path)"] else { return (404, "{\"error\":\"unknown command \(method) \(path)\"}") }
        return await route.handler(ArcZoomApp.sharedSidecar, Query(query))
    }

    // MARK: - Meeting and people

    static let meeting: [Route] = [
        Route("GET", "/", "The sidecar state: engine, meeting, program, participants, windows, last error.") { s, query in
            return ok()
        },
        Route("GET", "/state", "Same as GET /.") { s, query in
            return ok()
        },
        Route("GET", "/roster", "Same as GET /: the roster is inside the state.") { s, query in
            return ok()
        },
        Route("GET", "/meeting", "Meeting facts: ids, host, lock, topic, hands, quality, waiting room, unattended handlers.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            return (200, sdk.meetingJSON)
        },
        Route("POST", "/cohost", "?user=N&on=0|1  make or unmake a co-host (the portal's co_host must be ON). Answers with the roster.") { s, query in
            // ?user=N&on=0|1  make or unmake a co-host (the portal's co_host must be ON). Answers with the roster.
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            guard let id = query.user() else { return bad("cohost needs ?user=N") }
            guard sdk.participants.contains(where: { $0.id == id }) else { return (404, "{\"error\":\"no participant \(id)\"}") }
            let ok = sdk.setCoHost(id, on: query["on"] != "0")
            return (ok ? 200 : 409, ok ? s.stateJSON : "{\"error\":\"\(jsonEscape(sdk.lastError ?? "refused"))\"}")
        },
        Route("POST", "/video/raw", "?on=0|1  stop or restart the raw-data gate (diagnostic: what the recorder does without it).") { s, query in
            // ?on=0|1  stop or restart the raw-data gate (diagnostic: what the recorder does without it).
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            if query["on"] == "0" { sdk.stopRawData(); return (200, "{\"rawData\":false}") }
            let ok = await sdk.startRawData()
            return (ok ? 200 : 409, "{\"rawData\":\(sdk.rawDataRunning)}")
        },
        Route("POST", "/trust", "?on=0|1: accept the venue network's SSL-inspection certificates. Off by default.") { s, query in
            // ?on=0|1: accept the venue network's SSL-inspection certificates. Off by default.
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            sdk.trustVenueCertificates = query["on"] != "0"
            return (200, "{\"trustVenueCertificates\":\(sdk.trustVenueCertificates)}")
        },
        Route("GET", "/settings", "Meeting policies as the SDK reports them.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            return (200, sdk.settingsJSON)
        },
        Route("POST", "/settings", "Only the keys given are touched: ?lock=1&muteAll=1&allowUnmute=0&allowShare=&allowRename=&allowVideo=&allowChat=&waitingRoom=&muteOnEntry=&topic=&focus=&share=hostOnly|hostGrab|anyone|multi") { s, query in
            // Only the keys given are touched: ?lock=1&muteAll=1&allowUnmute=0&allowShare=&allowRename=&allowVideo=&allowChat=&waitingRoom=&muteOnEntry=&topic=&focus=&share=hostOnly|hostGrab|anyone|multi
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            func flag(_ k: String) -> Bool? { query[k].map { $0 != "0" } }
            var results: [String: Bool] = [:]
            if let v = flag("lock") { results["lock"] = sdk.setLock(v) }
            if let v = flag("muteAll") { results["muteAll"] = sdk.muteAll(v) }
            if let v = flag("allowUnmute") { results["allowUnmute"] = sdk.allowUnmuteBySelf(v) }
            if let v = flag("allowShare") { results["allowShare"] = sdk.allowShare(v) }
            if let v = flag("allowRename") { results["allowRename"] = sdk.allowRename(v) }
            if let v = flag("allowVideo") { results["allowVideo"] = sdk.allowVideo(v) }
            if let v = flag("allowChat") { results["allowChat"] = sdk.allowChat(v) }
            if let v = flag("waitingRoom") { results["waitingRoom"] = sdk.setWaitingRoomOnEntry(v) }
            if let v = flag("muteOnEntry") { results["muteOnEntry"] = sdk.setMuteOnEntry(v, allowUnmute: flag("allowUnmute") ?? true) }
            if let v = flag("focus") { results["focus"] = sdk.setFocusMode(v) }
            if let t = query["topic"] { results["topic"] = sdk.setTopic(t) }
            if let p = query["share"] { results["share"] = sdk.setSharePolicy(p) }
            let body = results.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
            let allOK = results.values.allSatisfy { $0 }
            return (allOK ? 200 : 409, "{\"applied\":{\(body)},\"error\":\(allOK ? "null" : "\"\(jsonEscape(sdk.lastError ?? "refused"))\""),\"settings\":\(sdk.settingsJSON)}")
        },
        Route("POST", "/hands/lower", "Lower every raised hand.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            return sdk.lowerAllHands() ? ok() : (409, "{\"error\":\"\(jsonEscape(sdk.lastError ?? "refused"))\"}")
        },
        Route("POST", "/order", "?ids=a,b,c  the gallery order every attendee follows") { s, query in
            // ?ids=a,b,c  the gallery order every attendee follows
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            let ids = (query["ids"] ?? "").split(separator: ",").compactMap { UInt32($0) }
            guard !ids.isEmpty else { return bad("order needs ?ids=a,b,c") }
            let known = Set(s.roster.map(\.id)); let unknown = ids.filter { !known.contains($0) }
            guard unknown.isEmpty else { return (404, "{\"error\":\"not in the meeting: \(unknown)\"}") }
            return sdk.pushVideoOrder(ids) ? ok() : (409, "{\"error\":\"\(jsonEscape(sdk.lastError ?? "refused"))\"}")
        },
        Route("GET", "/hands", "Raised hands in order, recent reactions.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            return (200, sdk.handsJSON)
        },
        Route("POST", "/hands/lower/one", "?user=N lower one raised hand.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine, let id = query.user() else { return bad("needs ?user=N") }
            return sdk.lowerHand(id) ? (200, sdk.handsJSON) : (409, "{\"error\":\"\(jsonEscape(sdk.lastError ?? "refused"))\"}")
        },
        Route("POST", "/reaction", "?type= send a reaction.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine, let t = query["type"] else { return bad("needs ?type=clap|thumbsup|heart|joy|openmouth|tada") }
            return sdk.sendReaction(t) ? ok() : (409, "{\"error\":\"\(jsonEscape(sdk.lastError ?? "refused"))\"}")
        },
        Route("POST", "/end", "End the meeting for everyone and stop any cloud recording.") { s, query in
            await s.endMeeting(); return (200, s.stateJSON)
        },
        Route("POST", "/refresh", "Re-read the meeting's roster. Roles change under us: the operator can promote the sidecar") { s, query in
            // Re-read the meeting's roster. Roles change under us: the operator can promote the sidecar
            // to host from a Zoom client and the SDK gives no callback we watch for it yet.
            (s.engine as? SDKZoomEngine)?.refreshRoster()
            return ok()
        },
        Route("GET", "/waiting", "Who is in the waiting room.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (200, "{\"waiting\":[]}") }
            let people = sdk.waitingRoom().map { "{\"id\":\($0.id),\"name\":\"\(jsonEscape($0.name))\"}" }.joined(separator: ",")
            return (200, "{\"waiting\":[\(people)]}")
        },
        Route("POST", "/admit", "?user=N, or all of them. The sidecar is the host, so the sidecar owns the door.") { s, query in
            // ?user=N, or all of them. The sidecar is the host, so the sidecar owns the door.
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            let who = query.user()
            if let who, !sdk.waitingRoomIDs.contains(who) { return (404, "{\"error\":\"\(who) is not in the waiting room\",\"waiting\":\(sdk.waitingRoomIDs)}") }
            let ok = await sdk.admit(who)
            return ok ? (200, "{\"ok\":true,\"waiting\":\(sdk.waitingRoomIDs)}") : (409, "{\"error\":\"\(jsonEscape(sdk.lastError ?? "refused"))\"}")
        },
        Route("POST", "/join", "?meeting=&passcode=&name= join someone else's meeting with the ARC Tech ZAK.") { s, query in
            let meeting = query["meeting"] ?? ""
            let name = query["name"] ?? "ARC Tech"
            let ok = await s.engine.join(meeting: meeting, passcode: query["passcode"], displayName: name)
            return ok ? (200, s.stateJSON) : (409, "{\"error\":\"\(jsonEscape(s.engine.lastError ?? "refused"))\"}")
        },
        Route("POST", "/start", "START a meeting as ARC Tech, so the sidecar is host from the first instant (spike item 6).") { s, query in
            // START a meeting as ARC Tech, so the sidecar is host from the first instant (spike item 6).
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running; POST /engine?use=sdk first\"}") }
            let name = query["name"] ?? "ARC Zoom"
            let ok = await sdk.startMeeting(displayName: name)
            return ok ? (200, "{\"ok\":true,\"diagnostics\":\(sdk.diagnosticsJSON)}") : (409, "{\"error\":\"\(jsonEscape(sdk.lastError ?? "refused"))\"}")
        },
        Route("POST", "/leave", "Leave the meeting WITHOUT ending it (keeps a personal meeting alive: prefer /end).") { s, query in
            await s.engine.leave()
            return (200, s.stateJSON)
        },
        Route("POST", "/spotlight", "?user=N (&off=1 to un-spotlight that one), or ?clear=1 for all. Meeting-wide: every attendee sees it.") { s, query in
            // ?user=N, or ?clear=1. Meeting-wide: every attendee sees it.
            if query["clear"] != nil { let ok = await s.spotlight(nil); return ok ? (200, s.stateJSON) : (409, "{\"error\":\"\(jsonEscape(s.engine.lastError ?? "refused"))\"}") }
            guard let id = query.user() else { return bad("spotlight needs ?user=N or ?clear=1") }
            guard let p = s.roster.first(where: { $0.id == id }) else { return (404, "{\"error\":\"no participant \(id)\"}") }
            guard p.videoOn else { return (409, "{\"error\":\"\(jsonEscape(p.name)) has no video on; Zoom only spotlights video\"}") }
            let ok = await s.spotlight(id, on: query["off"] == nil)
            return ok ? (200, s.stateJSON) : (409, "{\"error\":\"\(jsonEscape(s.engine.lastError ?? "refused"))\"}")
        },
        Route("POST", "/program", "?user=N | ?mode=spotlight|manual | ?clear=1. LOCAL: what the room sees, not the meeting.") { s, query in
            // ?user=N | ?mode=spotlight|manual | ?clear=1. LOCAL: what the room sees, not the meeting.
            if let mode = query["mode"] {
                guard let m = Sidecar.ProgramMode(rawValue: mode) else { return bad("mode is spotlight or manual") }
                s.setProgramMode(m); return ok()
            }
            if query["clear"] != nil { s.setProgram(nil); return ok() }
            guard let id = query.user() else { return bad("program needs ?user=N, ?mode=, or ?clear=1") }
            guard let p = s.roster.first(where: { $0.id == id }) else { return (404, "{\"error\":\"no participant \(id)\"}") }
            guard !p.isMe else { return (409, "{\"error\":\"the sidecar is never on PROGRAM: the operator is in the room\"}") }
            s.setProgram(id); return ok()
        },
        Route("POST", "/mute", "?user=N[&on=0|1] mute; unmute is a request the participant accepts.") { s, query in
            guard let id = query.user() else { return bad("mute needs ?user=N[&on=0|1]") }
            guard s.roster.contains(where: { $0.id == id }) else { return (404, "{\"error\":\"no participant \(id)\"}") }
            let on = query["on"] != "0"
            let ok = await s.engine.mute(id, on: on)
            return ok ? (200, s.stateJSON) : (409, "{\"error\":\"\(jsonEscape(s.engine.lastError ?? "refused"))\"}")
        },
        Route("POST", "/name", "?user=&to= friendly name for a participant (fake engine).") { s, query in
            guard let fake = s.engine as? FakeZoomEngine else { return (409, "{\"error\":\"friendly names need the engine's roster\"}") }
            guard let id = query.user() else { return bad("name needs ?user=N&to=<text>") }
            fake.rename(id, friendly: query["to"]); return ok()
        },
    ]

    // MARK: - Video, windows, displays, scenes

    static let outputs: [Route] = [
        Route("GET", "/video", "Raw video subscriptions with frame counts.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (200, "{\"subscriptions\":[]}") }
            return (200, sdk.videoJSON)
        },
        Route("POST", "/video/self", "?on=0|1, before a join or start. Suspect for raw video never arriving.") { s, query in
            // ?on=0|1, before a join or start. Suspect for raw video never arriving.
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            let on = query["on"] != "0"
            sdk.sendsOwnVideo = on
            // In a meeting already: flip the live camera too, not just the preference for next time.
            var live = "not in a meeting"
            if s.state == .inMeeting { live = sdk.setOwnVideo(on: on) ? "switched" : (sdk.lastError ?? "refused") }
            return (200, "{\"sendsOwnVideo\":\(sdk.sendsOwnVideo),\"live\":\"\(live)\"}")
        },
        Route("GET", "/video/blur", "Background blur state, the SDK's background items, diagnostics.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            let names = sdk.backgroundItemNames.map { "\"\(jsonEscape($0))\"" }.joined(separator: ",")
            return (200, "{\"supported\":\(sdk.blurSupported),\"blur\":\(sdk.blurOn),\"items\":[\(names)],\"diagnostics\":\(sdk.blurDiagnostics)}")
        },
        Route("POST", "/video/blur", "?on=0|1  background blur on the sidecar's own camera") { s, query in
            // ?on=0|1  background blur on the sidecar's own camera
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            let ok = sdk.setBlur(query["on"] != "0")
            return (ok ? 200 : 409, ok ? "{\"blur\":\(sdk.blurOn)}" : "{\"error\":\"\(jsonEscape(sdk.lastError ?? "refused"))\"}")
        },
        Route("GET", "/displays", "External displays and which holds PGM / MON.") { s, query in
            return (200, ArcZoomApp.sharedDisplays.displaysJSON)
        },
        Route("POST", "/output", "?kind=program|confidence[&display=<index|name|uuid>][&on=0|1]  assign and go live (default on=1)") { s, query in
            // ?kind=program|confidence[&display=<index|name|uuid>][&on=0|1]  assign and go live (default on=1)
            let d = ArcZoomApp.sharedDisplays
            guard let raw = query["kind"], let out = raw == "program" ? OutputType.program : (raw == "confidence" || raw == "gallery" ? OutputType.confidence : nil) else {
                return bad("output needs ?kind=program|confidence")
            }
            if let key = query["display"] {
                guard let screen = d.screen(matching: key) else { return (404, "{\"error\":\"no display matches \(jsonEscape(key))\",\"displays\":\(d.displaysJSON)}") }
                d.assign(screen: screen, to: out)
            }
            if query["on"] == "0" { d.closeOutput(out); return (200, d.displaysJSON) }
            guard d.openOutput(out) else { return (409, "{\"error\":\"\(jsonEscape(d.statusMessage ?? "no display assigned or the display is missing"))\",\"displays\":\(d.displaysJSON)}") }
            return (200, d.displaysJSON)
        },
        Route("GET", "/scenes", "The scene presets an output can show.") { s, query in
            let list = OutputScene.presets.map { sc in "{\"name\":\"\(sc.name)\",\"elements\":[\(sc.elements.map { "\"\($0.rawValue)\"" }.joined(separator: ","))]}" }.joined(separator: ",")
            let current = LayoutWindow.Kind.allCases.map { "\"\($0.rawValue)\":\"\(s.scene(for: $0).name)\"" }.joined(separator: ",")
            return (200, "{\"presets\":[\(list)],\"current\":{\(current)}}")
        },
        Route("POST", "/scene", "?kind=program|gallery|strip&name=<preset, e.g. speaker+gallery or \"SHARE + STRIP\">") { s, query in
            // ?kind=program|gallery|strip&name=<preset, e.g. speaker+gallery or "SHARE + STRIP">
            guard let k = query["kind"].flatMap(LayoutWindow.Kind.init(rawValue:)), let name = query["name"] else { return bad("scene needs ?kind=program|gallery|strip&name=<preset>") }
            return s.setScene(name.replacingOccurrences(of: "+", with: " + "), for: k) ? (200, s.stateJSON) : (404, "{\"error\":\"\(jsonEscape(s.lastError ?? "no such scene"))\"}")
        },
        Route("POST", "/selfview", "?on=0|1 the sidecar's own camera in GALLERY / STRIP and the previews.") { s, query in
            s.selfViewOn = query["on"] != "0"; return (200, s.stateJSON)
        },
        Route("POST", "/black", "?on=0|1[&kind=program|gallery|strip]  black a held output (default: all)") { s, query in
            // ?on=0|1[&kind=program|gallery|strip]  black a held output (default: all)
            let on = query["on"] != "0"
            if let k = query["kind"].flatMap(LayoutWindow.Kind.init(rawValue:)) {
                guard s.windows[k]?.isOpen == true else { return (409, "{\"error\":\"\(k.title) is not open\"}") }
                s.setBlack(k, on)
            } else { s.blackAll(on) }
            return (200, s.stateJSON)
        },
        Route("POST", "/outputs/close", "Take every output off its display (the displays show the desktop).") { s, query in
            ArcZoomApp.sharedDisplays.closeAllOutputs(); return (200, ArcZoomApp.sharedDisplays.displaysJSON)
        },
        Route("POST", "/identify", "Flash every display with its number, name and role.") { s, query in
            ArcZoomApp.sharedDisplays.flashAllScreens(); return ok()
        },
        Route("POST", "/video/resubscribe", "Tear down and rebuild every raw video subscription.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            await sdk.resubscribeAll()
            return (200, sdk.videoJSON)
        },
        Route("POST", "/window", "?kind=program|gallery|strip[&on=0|1][&size=WxH]") { s, query in
            // ?kind=program|gallery|strip[&on=0|1][&size=WxH]
            guard let raw = query["kind"], let kind = LayoutWindow.Kind(rawValue: raw) else {
                return bad("window needs ?kind=program|gallery|strip")
            }
            if query["on"] == "0" { s.close(kind); return ok() }
            var size: CGSize?
            if let spec = query["size"] {
                let parts = spec.lowercased().split(separator: "x")
                if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 80, h > 60 {
                    size = CGSize(width: w, height: h)
                } else {
                    return bad("size is WxH in points, e.g. 1280x720")
                }
            }
            s.open(kind, size: size); return ok()
        },
        Route("POST", "/aspect", "?value= tile aspect ratio for the room layout (16:9 default).") { s, query in
            guard let v = query["value"].flatMap(Double.init), v > 0.2, v < 5 else { return bad("aspect needs ?value=1.777") }
            s.tileAspect = CGFloat(v); s.relayout(); return ok()

        // The rehearsal rig: build a meeting shape with no meeting. Fake engine only.
        },
    ]

    // MARK: - Audio and devices

    static let audio: [Route] = [
        Route("POST", "/audio/self", "?on=0|1: the sidecar's own mic into the call (joins the meeting audio first).") { s, query in
            // ?on=0|1: the sidecar's own mic into the call (joins the meeting audio first).
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            let on = query["on"] != "0"
            let ok = sdk.setOwnAudio(on: on)
            let d = sdk.audioDevices
            return (ok ? 200 : 409, "{\"micOpen\":\(ok && on),\"result\":\"\(ok ? "ok" : jsonEscape(sdk.lastError ?? "refused"))\",\"mic\":\"\(jsonEscape(d.mic ?? "?"))\",\"speaker\":\"\(jsonEscape(d.speaker ?? "?"))\"}")
        },
        Route("POST", "/devices", "?camera=<name fragment>&mic=<name fragment>: pick the sidecar's own devices by name.") { s, query in
            // ?camera=<name fragment>&mic=<name fragment>: pick the sidecar's own devices by name.
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            let r = sdk.selectDevices(cameraMatch: query["camera"], micMatch: query["mic"])
            let errs = r.errors.map { "\"\(jsonEscape($0))\"" }.joined(separator: ",")
            return (r.errors.isEmpty ? 200 : 409, "{\"camera\":\"\(jsonEscape(r.camera ?? sdk.selectedCamera ?? "?"))\",\"mic\":\"\(jsonEscape(r.mic ?? sdk.audioDevices.mic ?? "?"))\",\"errors\":[\(errs)]}")
        },
        Route("GET", "/sound", "Sound processing flags, presets, config, device names and volumes.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            return (200, sdk.soundJSON)
        },
        Route("POST", "/sound", "?preset=music|speech  or any of ?original=&hifi=&stereo=&noise=none|auto|low|medium|high&agc=") { s, query in
            // ?preset=music|speech  or any of ?original=&hifi=&stereo=&noise=none|auto|low|medium|high&agc=
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            var notes: [String] = []; var okAll = true
            if let p = query["preset"] { let r = sdk.applyPreset(p); okAll = r.ok; notes += r.notes }
            else {
                func flag(_ k: String) -> Bool? { query[k].map { $0 != "0" } }
                notes += sdk.setSound(original: flag("original"), hifi: flag("hifi"), stereo: flag("stereo"), noise: query["noise"], agc: flag("agc"))
            }
            let list = notes.map { "\"\(jsonEscape($0))\"" }.joined(separator: ",")
            return (okAll ? 200 : 409, "{\"notes\":[\(list)],\"sound\":\(sdk.soundJSON)}")
        },
        Route("POST", "/audio/config", "?name=basic|console|split[&mixMinus=0|1]") { s, query in
            // ?name=basic|console|split[&mixMinus=0|1]
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            let did = sdk.applyAudioConfig(query["name"] ?? sdk.audioConfig, mixMinus: query["mixMinus"].map { $0 != "0" })
            let list = did.map { "\"\(jsonEscape($0))\"" }.joined(separator: ",")
            return (did.isEmpty ? 409 : 200, "{\"did\":[\(list)],\"sound\":\(sdk.soundJSON)}")
        },
        Route("POST", "/audio/speaker", "?on=0|1 (the sidecar's own playback of the call) &volume=0-100 &device=<name or id>") { s, query in
            // ?on=0|1 (the sidecar's own playback of the call) &volume=0-100 &device=<name or id>
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            var okAll = true
            if let dev = query["device"] { okAll = sdk.selectAudio(mic: false, id: dev) && okAll }
            if let on = query["on"] { okAll = sdk.setSpeakerOutput(on != "0") && okAll }
            if let v = query["volume"].flatMap(Float.init) { okAll = sdk.setVolume(mic: false, v) && okAll }
            return (okAll ? 200 : 409, sdk.soundJSON)
        },
        Route("POST", "/audio/mic", "?device=<name or id> select  &volume=0-100") { s, query in
            // ?device=<name or id> select  &volume=0-100
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            var okAll = true
            if let dev = query["device"] { okAll = sdk.selectAudio(mic: true, id: dev) && okAll }
            if let v = query["volume"].flatMap(Float.init) { okAll = sdk.setVolume(mic: true, v) && okAll }
            return (okAll ? 200 : 409, sdk.soundJSON)
        },
        Route("POST", "/audio/test", "?mic=start|stop|play &speaker=start|stop ; levels in GET /sound") { s, query in
            // ?mic=start|stop|play &speaker=start|stop ; levels in GET /sound
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            let notes = sdk.audioTest(mic: query["mic"], speaker: query["speaker"])
            let list = notes.map { "\"\(jsonEscape($0))\"" }.joined(separator: ",")
            return (200, "{\"notes\":[\(list)],\"sound\":\(sdk.soundJSON)}")
        },
        Route("GET", "/audio/check", "The pre-flight check: phase, step, level, last result.") { s, query in
            return (200, s.audioCheck.json)
        },
        Route("POST", "/audio/check", "?run=mic|out|stop  TEST MIC (5 s listen + playback) or TEST AUDIO OUT (4 s tone), before a meeting. &record=0 meters the mic without the SDK's recorder (diagnostic).") { s, query in
            // ?run=mic|out|stop  TEST MIC (5 s listen + playback) or TEST AUDIO OUT (4 s tone), before a meeting.
            switch query["run"] {
            case "mic": s.audioCheck.start(.mic, sidecar: s, sdkRecord: query["record"] != "0")
            case "out": s.audioCheck.start(.out, sidecar: s)
            case "stop": s.audioCheck.stop()
            default: return bad("audio/check needs ?run=mic|out|stop")
            }
            return (s.audioCheck.isRunning || query["run"] == "stop" ? 200 : 409, s.audioCheck.json)
        },
        Route("GET", "/audio", "Selected camera, mic and speaker; every audio device with its ID.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            let d = sdk.audioDevices
            let mics = sdk.audioDeviceList(mic: true).map(\.json).joined(separator: ","), spk = sdk.audioDeviceList(mic: false).map(\.json).joined(separator: ",")
            return (200, "{\"camera\":\"\(jsonEscape(sdk.selectedCamera ?? "?"))\",\"mic\":\"\(jsonEscape(d.mic ?? "?"))\",\"speaker\":\"\(jsonEscape(d.speaker ?? "?"))\",\"mics\":[\(mics)],\"speakers\":[\(spk)]}")
        },
    ]

    // MARK: - Sharing

    static let share: [Route] = [
        Route("GET", "/share", "The active remote share and who may share.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            sdk.refreshShare()
            return (200, sdk.shareJSON)
        },
        Route("GET", "/shareable", "Windows this Mac can share.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            return (200, sdk.shareStateJSON)
        },
        Route("POST", "/share", "One of: ?window=<CGWindowID or title> | ?display=<index|name|uuid> | ?file=<path> | ?camera=<name fragment> | ?audio=1") { s, query in
            // One of: ?window=<CGWindowID or title> | ?display=<index|name|uuid> | ?file=<path> | ?camera=<name fragment> | ?audio=1
            // Settings (also alone): &sound=0|1 &optimize=0|1 &stereo=0|1. ?on=0 stops, ?pause=0|1 pauses or resumes.
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            if let v = query["sound"] { sdk.shareSound = v != "0" }
            if let v = query["optimize"] { sdk.shareOptimizeVideo = v != "0" }
            if let v = query["stereo"] { sdk.shareStereo = v != "0" }
            if query["on"] == "0" { await sdk.stopShare(); return (200, sdk.shareStateJSON) }
            if let p = query["pause"] { return sdk.pauseShare(p != "0") ? (200, sdk.shareStateJSON) : (409, "{\"error\":\"\(jsonEscape(sdk.lastError ?? "refused"))\"}") }
            var okShare: Bool? = nil
            if let w = query["window"] {
                if let id = UInt32(w) { let win = sdk.shareableWindows().first { $0.id == id }; okShare = sdk.shareWindow(id, label: win.map { "\($0.app): \($0.title)" }) }
                else { okShare = sdk.shareableWindows().first { $0.title == w }.map { sdk.shareWindow($0.id, label: "\($0.app): \($0.title)") } ?? false; if okShare == false, sdk.lastError == nil { sdk.lastError = "no window titled \(w)" } }
            } else if let d = query["display"] {
                guard let screen = ArcZoomApp.sharedDisplays.screen(matching: d) else { return (404, "{\"error\":\"no display matches \(jsonEscape(d))\"}") }
                okShare = sdk.shareDisplay(screen.id, label: "display \(screen.localizedName)")
            } else if let f = query["file"] {
                okShare = sdk.shareVideoFile(f)
            } else if let c = query["camera"] {
                let cams = (ZoomSDK.shared().getSettingService()?.getVideoSetting()?.getCameraList() as? [SDKDeviceInfo]) ?? []
                guard let cam = cams.first(where: { $0.getDeviceName().localizedCaseInsensitiveContains(c) }) else { return (404, "{\"error\":\"no camera matches \(jsonEscape(c))\"}") }
                okShare = sdk.shareCamera(cam.getDeviceID(), label: cam.getDeviceName())
            } else if query["audio"] != nil {
                okShare = sdk.shareAudioOnly()
            }
            if let ok = okShare, !ok { return (409, "{\"error\":\"\(jsonEscape(sdk.lastError ?? "refused"))\",\"share\":\(sdk.shareStateJSON)}") }
            return (200, sdk.shareStateJSON)
        },
    ]

    // MARK: - PREVIEW (the OUTPUTS panel's camera / video-file player; SHARE THIS sends what it shows)

    /// The module's state with the share it has on air, for every PREVIEW route's answer.
    static func previewState(_ s: Sidecar) -> String {
        let p = s.preview
        let sdk = s.engine as? SDKZoomEngine
        let base = p.json
        return String(base.dropLast()) + ",\"meeting\":\"\(s.state.rawValue)\",\"thisMacSharing\":\(s.isSharing),\"rawShare\":\(sdk?.rawShareJSON ?? "null")}"
    }
    static func previewRefusal(_ s: Sidecar, _ why: String?) -> (Int, String) {
        (409, "{\"error\":\"\(jsonEscape(why ?? "refused"))\",\"preview\":\(previewState(s))}")
    }

    static let preview: [Route] = [
        Route("GET", "/preview", "PREVIEW: source (off|camera|file, with the camera's AUDIO IN), state (NO FILE|LOADING|CONVERTING n%|PAUSED|PLAYING|ENDED|FAILED), position, duration, loop, monitor volume/mute, level, onAir, shareMode (camera|camera-raw|file-raw|file-sdk), frames and audio chunks sent, the raw share's senders, the cameras and audio inputs, ffmpeg's path.") { s, query in
            (200, previewState(s))
        },
        Route("POST", "/preview", "One of: ?camera=<id or name fragment> [&audio=<input id or name fragment>|none] | ?file=<path> | ?off=1 (also cancels a conversion) | ?cancel=1 (stop a conversion) | ?pfl=<output device id or name fragment>|off (where local listening goes) | ?asVideo=1|0 (CAMERA: SHARE THIS sends it as ARC Zoom's own video, spotlighted, low delay). Also alone: &audio= (the camera's AUDIO IN, remembered per camera), &sendOnMain=0|1 (raw share senders on the main thread, a live-test switch).") { s, query in
            let p = s.preview
            if let v = query["sendOnMain"] { ZoomShareSink.sendOnMain = v != "0" }
            if query["off"] != nil { p.previewOff(); return (200, previewState(s)) }
            if query["cancel"] != nil { p.cancelConvert(); return (200, previewState(s)) }
            if let v = query["asVideo"] { p.sendAsVideo = v != "0"; return (200, previewState(s)) }
            if let v = query["pfl"] {
                if v == "off" || v.isEmpty { p.pflUID = nil; return (200, previewState(s)) }
                let outs = AudioOutputs.all()
                guard let d = outs.first(where: { $0.id == v }) ?? outs.first(where: { $0.name.localizedCaseInsensitiveContains(v) }) else {
                    return (404, "{\"error\":\"no output device matches \(jsonEscape(v))\",\"outputs\":[\(outs.map { "\"\(jsonEscape($0.name))\"" }.joined(separator: ","))]}")
                }
                p.pflUID = d.id
                return (200, previewState(s))
            }
            if let f = query["file"] {
                let path = (f as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: path) else { return (404, "{\"error\":\"no file at \(jsonEscape(path))\"}") }
                p.loadFile(URL(fileURLWithPath: path))
                return (200, previewState(s))
            }
            if let c = query["camera"] {
                let sdkCams = (s.engine as? SDKZoomEngine).flatMap { $0.didInit ? $0.cameraList().map { ($0.deviceID, $0.name) } : nil } ?? []
                let all = sdkCams.isEmpty ? PreviewPlayer.availableCameras().map { ($0.uniqueID, $0.localizedName) } : sdkCams
                guard let cam = all.first(where: { $0.0 == c }) ?? all.first(where: { $0.1.localizedCaseInsensitiveContains(c) }) else { return (404, "{\"error\":\"no camera matches \(jsonEscape(c))\"}") }
                p.previewCamera(id: cam.0, name: cam.1)
            }
            if let a = query["audio"] {
                let want: String?
                if a.isEmpty || a.lowercased() == "none" { want = nil }
                else {
                    guard let dev = PreviewPlayer.availableAudioInputs().first(where: { $0.uniqueID == a }) ?? PreviewPlayer.availableAudioInputs().first(where: { $0.localizedName.localizedCaseInsensitiveContains(a) }) else {
                        return (404, "{\"error\":\"no audio input matches \(jsonEscape(a))\"}")
                    }
                    want = dev.uniqueID
                }
                if !p.setCameraAudio(id: want) { return previewRefusal(s, p.note) }
            }
            return (200, previewState(s))
        },
        Route("POST", "/preview/transport", "FILE transport, any of: ?action=play|pause|toggle|restart &seek=<seconds> &loop=0|1 &volume=0..1 &mute=0|1 (volume and mute are the LOCAL monitor only, never what the call hears; on a camera they are its AUDIO IN's monitor). Acts live on the share while the file is on air.") { s, query in
            let p = s.preview
            if let v = query["loop"] { p.loop = v != "0" }
            if let v = query["volume"] { guard let d = Double(v), d.isFinite else { return bad("volume is 0..1") }; p.monitorVolume = Float(d) }
            if let v = query["mute"] { p.monitorMuted = v != "0" }
            if let t = query["seek"] {
                guard let d = Double(t), d.isFinite else { return bad("seek is seconds") }
                guard p.transport.isLoaded else { return previewRefusal(s, "no file is loaded (\(p.transport.word.lowercased()))") }
                p.seek(to: d)
            }
            switch query["action"] {
            case nil: break
            case "play": guard p.transport.isLoaded else { return previewRefusal(s, "no file is loaded (\(p.transport.word.lowercased()))") }; p.play()
            case "pause": p.pause()
            case "toggle": p.toggle()
            case "restart": p.restart()
            case let other?: return bad("action is play, pause, toggle or restart, not \(other)")
            }
            return (200, previewState(s))
        },
        Route("POST", "/preview/share", "?on=1 SHARE THIS: the camera (SDK camera share, or raw with its AUDIO IN) or the file (raw share: frames + sound from the player; Zoom's own file share if raw is refused). ?on=0 STOP SHARE. Answers after the SDK accepted or refused, 409 with its reason.") { s, query in
            if query["on"] == "0" { await s.stopPreviewShare(); return (200, previewState(s)) }
            let ok = await s.sharePreview()
            return ok ? (200, previewState(s)) : previewRefusal(s, s.lastError)
        },
    ]

    // MARK: - Chat, captions, recording

    static let text: [Route] = [
        Route("GET", "/captions", "Transcription status, diagnostics and the last captions.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            return (200, sdk.captionsJSON)
        },
        Route("POST", "/captions", "?on=0|1 live transcription; ?language=<id> spoken language for all") { s, query in
            // ?on=0|1 live transcription; ?language=<id> spoken language for all
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            var okAll = true
            if let l = query["language"].flatMap(Int.init) { okAll = sdk.setSpokenLanguage(l) && okAll }
            if let on = query["on"] { okAll = (on != "0" ? sdk.startTranscription() : sdk.stopTranscription()) && okAll }
            return (okAll ? 200 : 409, okAll ? sdk.captionsJSON : "{\"error\":\"\(jsonEscape(sdk.lastError ?? "refused"))\"}")
        },
        Route("GET", "/record", "Recording status, folder, last file.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            return (200, sdk.recordingJSON)
        },
        Route("POST", "/record", "?action=start|pause|resume|stop  ?folder=<path>") { s, query in
            // ?action=start|pause|resume|stop  ?folder=<path>
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            var okAll = true
            if let f = query["folder"] { okAll = sdk.setRecordingFolder(f) && okAll }
            switch query["action"] {
            case "start": okAll = sdk.startRecording() && okAll
            case "pause": okAll = sdk.pauseRecording() && okAll
            case "resume": okAll = sdk.resumeRecording() && okAll
            case "stop": okAll = sdk.stopRecording() && okAll
            default: break
            }
            return (okAll ? 200 : 409, okAll ? sdk.recordingJSON : "{\"error\":\"\(jsonEscape(sdk.lastError ?? "refused"))\"}")
        },
        Route("GET", "/chat", "Chat messages this meeting.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            return (200, sdk.chatJSON)
        },
        Route("POST", "/chat", "?text=<message>[&to=<user id>|&waiting=1]") { s, query in
            // ?text=<message>[&to=<user id>|&waiting=1]
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            guard let text = query["text"], !text.isEmpty else { return bad("chat needs ?text=") }
            let ok = sdk.sendChat(text, to: query["to"].flatMap { UInt32($0) }, toWaitingRoom: query["waiting"] != nil)
            return ok ? (200, sdk.chatJSON) : (409, "{\"error\":\"\(jsonEscape(sdk.lastError ?? "refused"))\"}")
        },
        Route("POST", "/record/cloudstop", "Stop a cloud recording left running.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            return sdk.stopCloudRecordingIfRunning() ? (200, sdk.recordingJSON) : (409, sdk.recordingJSON)
        },
    ]

    // MARK: - SDK, tokens, health, log, app

    static let system: [Route] = [
        Route("GET", "/health", "Connection, network, send/receive stats, per-user quality, warnings, subscriptions.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            return (200, sdk.healthJSON)
        },
        Route("GET", "/portal", "The house account settings the sidecar depends on (captions, recording, live stream, waiting room). ?full=1 adds the whole document.") { s, query in
            // The account's PORTAL settings over REST. These gate what the SDK can do IN a meeting and
            // cannot be set from inside one, so the operator needs to see them before a show, not guess.
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            guard let token = await sdk.freshAccessToken() else { return (409, "{\"error\":\"no Zoom access token; sign in first\"}") }
            do {
                let reading = try await ZoomPortal.read(accessToken: token)
                return (200, reading.json(full: query["full"] != nil && query["full"] != "0"))
            } catch {
                return (409, "{\"error\":\"\(jsonEscape("\(error)"))\"}")
            }
        },
        Route("POST", "/portal", "?captions=1&autoCaptions=1&cloudRecording=1&... flip account settings by the names GET /portal reports. Applies to NEW meetings only.") { s, query in
            // ?captions=1&autoCaptions=1&cloudRecording=1&... flip account settings by the names GET /portal reports.
            // Patched and then RE-READ: an account or group lock accepts the patch in silence and changes
            // nothing, so the answer reports what the settings now are, and names what refused to move.
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            var wanted: [String: String] = [:]
            var unknown: [String] = []
            for (key, value) in query.raw {
                if ZoomPortal.concern(named: key) != nil { wanted[key] = value } else { unknown.append(key) }
            }
            if wanted.isEmpty {
                let names = ZoomPortal.concerns.map(\.name).joined(separator: "|")
                return bad("portal needs at least one of \(names) as ?name=0|1")
            }
            if !unknown.isEmpty { return bad("portal does not know \(unknown.sorted().joined(separator: ", "))") }
            guard let token = await sdk.freshAccessToken() else { return (409, "{\"error\":\"no Zoom access token; sign in first\"}") }
            do {
                let result = try await ZoomPortal.write(wanted, accessToken: token)
                ShowLog.log("portal: changed \(result.changed.keys.sorted().joined(separator: " "))"
                            + (result.refused.isEmpty ? "" : ", REFUSED \(result.refused.keys.sorted().joined(separator: " "))"))
                return (result.refused.isEmpty ? 200 : 409, result.json())
            } catch {
                return (409, "{\"error\":\"\(jsonEscape("\(error)"))\"}")
            }
        },
        Route("POST", "/portal/pmi", "?value=<10 digits>  set ARC Tech's personal meeting ID (the number CREATE MEETING uses). Zoom's rules are checked first; the stored PMI follows what Zoom holds. Needs user:update:user on the Marketplace app AND in oauthScopes (off by default: the PMI is set in the portal).") { s, query in
            // ?value=<10 digits>  set ARC Tech's personal meeting ID. Zoom's rules are checked first; the stored PMI follows what Zoom holds.
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            guard let want = query["value"] else { return bad("portal/pmi needs ?value=<10 digits>") }
            if let why = ZoomPortal.pmiProblem(want) { return bad("PMI \(want) refused before asking Zoom: \(why)") }
            guard s.state == .idle else { return (409, "{\"error\":\"end the meeting first: the PMI is the meeting that is up\"}") }
            guard let token = await sdk.freshAccessToken() else { return (409, "{\"error\":\"no Zoom access token; sign in first\"}") }
            do {
                let now = try await ZoomPortal.setPMI(want, accessToken: token)
                var stored = TokenStore.load(); stored.pmi = now; _ = TokenStore.save(stored)
                let changed = now.map(String.init) == want
                ShowLog.log("portal: PMI now \(now.map(String.init) ?? "?")\(changed ? "" : " (asked for \(want): Zoom kept its own)")")
                return (changed ? 200 : 409, "{\"pmi\":\(now.map(String.init) ?? "null"),\"asked\":\"\(jsonEscape(want))\",\"changed\":\(changed)}")
            } catch {
                return (409, "{\"error\":\"\(jsonEscape("\(error)"))\"}")
            }
        },
        Route("GET", "/window/operator", "The operator window: frame, screen, visible area, fits, uiScale.") { s, query in
            return (200, AppDelegate.operatorWindowJSON)
        },
        Route("POST", "/window/operator", "?w=&h=  resize the operator window (fit tests); ?fit=1 re-fit it to its screen") { s, query in
            // ?w=&h=  resize the operator window (fit tests); ?fit=1 re-fit it to its screen
            if let w = query["w"].flatMap(Double.init), let h = query["h"].flatMap(Double.init), let win = AppDelegate.operatorWindow() {
                var f = win.frame; f.origin.y += f.height - h; f.size = CGSize(width: w, height: h)
                win.setFrame(f, display: true, animate: false)
            }
            if query["fit"] != nil { AppDelegate.fitOperatorWindowToScreen() }
            return (200, AppDelegate.operatorWindowJSON)
        },
        Route("POST", "/ui", "?window=settings|participants|chat|captions|portal|log  toggle a pop-up window (Companion, capture tooling)") { s, query in
            // ?window=settings|participants|chat|captions|portal  toggle a pop-up window (Companion, capture tooling)
            guard let w = query["window"], ["settings", "participants", "chat", "captions", "portal", "log"].contains(w) else { return bad("ui needs ?window=settings|participants|chat|captions|portal|log") }
            NotificationCenter.default.post(name: .toggleWindow, object: w)
            return ok()
        },
        Route("POST", "/quit", "Scripted quit for relaunch tooling and Companion: END for everyone, close the outputs, exit.") { s, query in
            // Scripted quit for relaunch tooling and Companion: END for everyone, close the outputs, exit.
            // No dialog: the caller has decided. `applicationShouldTerminate` sees no meeting and no output.
            Task { @MainActor in
                if s.state != .idle { await s.endMeeting() }
                ArcZoomApp.sharedDisplays.closeAllOutputs()
                try? await Task.sleep(nanoseconds: 300_000_000)
                NSApp.terminate(nil)
            }
            return (202, "{\"ok\":true,\"quitting\":true}")
        },
        Route("GET", "/capabilities", "What this account can do in this meeting, measured from the SDK.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running\"}") }
            let body = sdk.capabilities.sorted { $0.key < $1.key }.map { "\"\(jsonEscape($0.key))\":\"\(jsonEscape($0.value))\"" }.joined(separator: ",")
            return (200, "{\(body)}")
        },
        Route("GET", "/sdk", "SDK version, authentication, raw-data gate, invite, last error.") { s, query in
            guard let sdk = s.engine as? SDKZoomEngine else {
                return (200, "{\"running\":false,\"engine\":\"\(s.engineKind)\",\"available\":\(SDKZoomEngine.available),\"reason\":\"\(jsonEscape(SDKZoomEngine.unavailableReason))\"}")
            }
            return (200, "{\"running\":true,\"engine\":\"sdk\",\"diagnostics\":\(sdk.diagnosticsJSON)}")
        },
        Route("POST", "/sdk/authorize", "The OAuth round trip: opens a browser for ARC Tech's consent, catches the redirect on") { s, query in
            // The OAuth round trip: opens a browser for ARC Tech's consent, catches the redirect on
            // 8767, stores the tokens in the keychain. Needed once; the join does it automatically.
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running; POST /engine?use=sdk first\"}") }
            Task { @MainActor in _ = await sdk.authorize() }
            return (202, "{\"ok\":true,\"poll\":\"GET /tokens\",\"note\":\"a browser is opening for Zoom's consent\"}")
        },
        Route("GET", "/tokens", "OAuth token state (fingerprint only, never the secret).") { s, query in
            let t = TokenStore.load()
            return (200, "{\"fingerprint\":\"\(jsonEscape(t.fingerprint))\",\"fresh\":\(t.accessTokenIsFresh),\"zak\":\(t.zak != nil)}")
        },
        Route("POST", "/tokens/clear", "Forget the OAuth tokens (next start signs in again).") { s, query in
            TokenStore.clear()
            return (200, "{\"cleared\":true}")
        },
        Route("POST", "/sdk/prepare", "Initialise the SDK and authenticate the app. Idempotent; the first call is the slow one.") { s, query in
            // Initialise the SDK and authenticate the app. Idempotent; the first call is the slow one.
            guard let sdk = s.engine as? SDKZoomEngine else { return (409, "{\"error\":\"the SDK engine is not running; POST /engine?use=sdk first\"}") }
            let ok = await sdk.prepare()
            return ok ? (200, "{\"ok\":true,\"diagnostics\":\(sdk.diagnosticsJSON)}") : (409, "{\"error\":\"\(jsonEscape(sdk.lastError ?? "refused"))\"}")
        },
        Route("POST", "/engine", "?use=fake|sdk. The fake is the rehearsal rig and stays reachable with the SDK built in.") { s, query in
            // ?use=fake|sdk. The fake is the rehearsal rig and stays reachable with the SDK built in.
            guard let want = query["use"] else { return bad("engine needs ?use=fake|sdk") }
            switch want {
            case "fake":
                guard !(s.engine is FakeZoomEngine) else { return ok() }
                await s.use(FakeZoomEngine())
                return (200, s.stateJSON)
            case "sdk":
                guard !(s.engine is SDKZoomEngine) else { return ok() }
                guard SDKZoomEngine.available else { return (409, "{\"error\":\"\(jsonEscape(SDKZoomEngine.unavailableReason))\"}") }
                let sdk = SDKZoomEngine()
                await s.use(sdk)
                let ok = await sdk.prepare()
                return ok ? (200, s.stateJSON) : (409, "{\"error\":\"\(jsonEscape(sdk.lastError ?? "refused"))\"}")
            default:
                return bad("engine is fake or sdk")
            }
        },
        Route("GET", "/credentials", "Never the secret itself: enough to recognise WHICH app, never enough to use it.") { s, query in
            // Never the secret itself: enough to recognise WHICH app, never enough to use it.
            switch ZoomCredentials.load() {
            case .success(let c): return (200, "{\"present\":true,\"fingerprint\":\"\(jsonEscape(c.fingerprint))\",\"service\":\"\(jsonEscape(ZoomCredentials.service))\"}")
            case .failure(let e): return (200, "{\"present\":false,\"reason\":\"\(jsonEscape(e.description))\"}")
            }
        },
        Route("POST", "/credentials", "?id=&secret=[&login=] seed the Marketplace pair (and the OPERATOR login) into this Mac's keychain; the pair is checked with Zoom first.") { s, query in
            // The fleet seeding path (seed-zoom-credentials.sh): the office workstation reads its keychain
            // and this app writes its OWN keychain, in the logged-in session where the keychain is unlocked
            // and the item's ACL trusts this app. The script's curl reads the secret from stdin, so it is
            // never in a process list. Localhost only, like every route here. Never logs a value.
            guard let id = query["id"]?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  let secret = query["secret"]?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty
            else { return bad("credentials needs ?id=&secret=") }
            let creds = ZoomCredentials(clientID: id, clientSecret: secret)
            switch await ZoomCredentials.verify(creds) {
            case .valid: break
            case .invalid: return (409, "{\"error\":\"Zoom rejected the pair (invalid_client); nothing was stored\"}")
            case .unknown(let why): return (409, "{\"error\":\"could not verify the pair with Zoom: \(jsonEscape(why)); nothing was stored\"}")
            }
            guard ZoomCredentials.store(creds) else { return (500, "{\"error\":\"the keychain refused the pair\"}") }
            var login = false
            if let pw = query["login"], !pw.isEmpty {
                guard AppLogin.store(password: pw) else { return (500, "{\"error\":\"pair stored, but the keychain refused the login password\"}") }
                login = true
            }
            ShowLog.log("credentials seeded into the keychain: \(creds.fingerprint)\(login ? ", OPERATOR login set" : "")")
            _ = await s.ensureSDK()
            return (200, "{\"present\":true,\"verified\":true,\"fingerprint\":\"\(jsonEscape(creds.fingerprint))\",\"login\":\(login)}")
        },
        Route("GET", "/login", "Is the OPERATOR login provisioned on this Mac, and is the operator window unlocked.") { s, query in
            (200, "{\"provisioned\":\(AppLogin.shared.provisioned),\"unlocked\":\(AppLogin.shared.unlocked)}")
        },
        Route("POST", "/credentials/import", "One-time migration of the 2026-05 spike's gitignored config.json into the keychain.") { s, query in
            // One-time migration of the 2026-05 spike's gitignored config.json into the keychain.
            guard let path = query["path"] else { return bad("import needs ?path=/abs/config.json") }
            switch ZoomCredentials.importFromSpikeConfig(at: path) {
            case .success(let c):
                ShowLog.log("credentials imported into the keychain: \(c.fingerprint)")
                return (200, "{\"present\":true,\"fingerprint\":\"\(jsonEscape(c.fingerprint))\"}")
            case .failure(let e):
                return (400, "{\"error\":\"\(jsonEscape(e.description))\"}")
            }
        },
        Route("GET", "/log", "?n=N the last N show-log lines.") { s, query in
            let n = query["n"].flatMap(Int.init) ?? 100
            let lines = ShowLog.recent(n).map { "\"\(jsonEscape($0))\"" }.joined(separator: ",")
            return (200, "{\"lines\":[\(lines)]}")
        },
    ]

    // MARK: - The fake engine (rehearsal rig)

    static let rehearsal: [Route] = [
        Route("POST", "/fake/add", "?name= add a synthetic participant (fake engine).") { s, query in
            guard let fake = s.engine as? FakeZoomEngine else { return (409, "{\"error\":\"the fake engine is not running\"}") }
            guard fake.addParticipant(name: query["name"]) != nil else { return (409, "{\"error\":\"join a meeting first, or the cast is full\"}") }
            return ok()
        },
        Route("POST", "/fake/remove", "?user= remove a synthetic participant (fake engine).") { s, query in
            guard let fake = s.engine as? FakeZoomEngine else { return (409, "{\"error\":\"the fake engine is not running\"}") }
            guard let id = query.user() else { return bad("remove needs ?user=N") }
            fake.removeParticipant(id); return ok()
        },
        Route("POST", "/fake/video", "?user=&on= synthetic video on/off (fake engine).") { s, query in
            guard let fake = s.engine as? FakeZoomEngine else { return (409, "{\"error\":\"the fake engine is not running\"}") }
            guard let id = query.user() else { return bad("video needs ?user=N&on=0|1") }
            fake.setVideo(id, on: query["on"] != "0"); return ok()
        },
    ]
}
