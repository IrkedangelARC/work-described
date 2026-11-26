//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// The house account's PORTAL settings, over the REST API rather than a browser.
///
/// Two of them gate features the SDK cannot turn on from inside a meeting: automated captions (live
/// transcription starts, the clients say "looking for a service", no text ever arrives) and cloud
/// recording (`canStartRecording` refuses; local file recording is not an option because it shares the
/// SDK recorder with the raw video feed). Both were flipped by hand in the portal before this, which is
/// no good on a show day and cannot be verified from the app.
///
/// TWO RULES that shaped this file:
///
/// 1. **The schema is not stable.** Zoom has moved captions between `in_meeting.closed_caption`,
///    `in_meeting.closed_captioning.enable` and friends. So nothing here hard-codes ONE path: each
///    concern lists candidate paths and the first one the live document actually contains wins. A
///    concern that is absent is reported as absent, never invented.
/// 2. **A PATCH that returns 204 has not necessarily changed anything.** An account-level or group-level
///    lock leaves the setting exactly as it was and says nothing. So every write is followed by a re-read
///    and the answer reports the value as it IS, plus which concerns did not move.
///
/// Portal changes apply to NEW meetings only; a meeting already up keeps the settings it started with.
enum ZoomPortal {

    // MARK: - The concerns

    /// One portal setting the sidecar cares about, with every path Zoom has been known to keep it at.
    /// Most are toggles; a few are a choice among strings (`recording.auto_recording` is "none" / "local"
    /// / "cloud"), and reading one of those as a boolean would report a lie, so the kind is declared.
    /// A few more are LICENCE facts, not settings: they read but a PATCH will never move them.
    struct Concern {
        let name: String
        let group: String
        let doc: String
        let paths: [[String]]
        var choices: [String]? = nil
        var readOnly: Bool = false
        var isChoice: Bool { choices != nil }
    }

    /// The groups, in the order the portal page lays them out.
    static let groups = ["captions", "recording", "people", "sharing", "picture and sound", "chat", "stream", "licence"]

    /// Every path here is as MEASURED on ARC Tech 2026-09-21, with older spellings kept behind them:
    /// Zoom writes the nested `closed_captioning` group AND the legacy flat `closed_caption` key, and it
    /// is `auto_transcribing`, not `auto_transcription` (the guess that reported automated captions
    /// "absent" the first time). Order is the order the portal page shows them.
    static let concerns: [Concern] = [
        // MARK: captions - the gate that cost two sessions: with `captions` OFF, live transcription
        // starts, the clients say "looking for a service", and no text ever arrives.
        Concern(name: "captions", group: "captions",
                doc: "Closed captioning. The master switch: with it OFF, live transcription starts and no text ever arrives.",
                paths: [["in_meeting", "closed_captioning", "enable"], ["in_meeting", "closed_caption"]]),
        Concern(name: "autoCaptions", group: "captions",
                doc: "Automated captions (Zoom's own live transcription), under the captions master switch.",
                paths: [["in_meeting", "closed_captioning", "auto_transcribing"],
                        ["in_meeting", "closed_captioning", "auto_transcription"], ["in_meeting", "auto_transcription"]]),
        Concern(name: "manualCaptions", group: "captions",
                doc: "A human captioner may be assigned in the meeting. ARC's path when a client hires CART.",
                paths: [["in_meeting", "manual_captioning", "manual_captions"], ["in_meeting", "manual_captions"]]),
        Concern(name: "captionAPI", group: "captions",
                doc: "Third-party captioning service: the caption API token ARC hands a vendor.",
                paths: [["in_meeting", "closed_captioning", "third_party_captioning_service"]]),
        Concern(name: "fullTranscript", group: "captions",
                doc: "Attendees may open the full live transcript panel.",
                paths: [["in_meeting", "closed_captioning", "view_full_transcript"]]),
        Concern(name: "saveCaptions", group: "captions",
                doc: "Attendees may save the caption transcript.",
                paths: [["in_meeting", "closed_captioning", "save_caption"], ["in_meeting", "save_caption"]]),

        // MARK: recording - cloud is the only path while raw video runs: local file recording shares the
        // SDK recorder with the raw feed and answers WrongUsage.
        Concern(name: "cloudRecording", group: "recording",
                doc: "Record to Zoom's cloud. The only recording path while raw video runs.",
                paths: [["recording", "cloud_recording"]]),
        Concern(name: "localRecording", group: "recording",
                doc: "Record to a local file. Shares the SDK recorder with raw video, so it is unusable from the sidecar.",
                paths: [["recording", "local_recording"]]),
        Concern(name: "cloudTranscript", group: "recording",
                doc: "Zoom transcribes the cloud recording afterwards. The transcript a client asks for a week later.",
                paths: [["recording", "recording_audio_transcript"]]),
        Concern(name: "separateFiles", group: "recording",
                doc: "Cloud recording keeps active speaker, gallery and shared screen as separate files. An editor wants this.",
                paths: [["recording", "record_files_separately", "active_speaker"]]),
        Concern(name: "recordingDisclaimer", group: "recording",
                doc: "A consent dialog at the start of recording. A rack Mac nobody is watching cannot answer it.",
                paths: [["recording", "recording_disclaimer"]]),
        Concern(name: "autoRecording", group: "recording",
                doc: "Start recording automatically. A show wants none: the operator arms REC.",
                paths: [["recording", "auto_recording"]], choices: ["none", "local", "cloud"]),

        // MARK: people
        Concern(name: "waitingRoom", group: "people",
                doc: "The waiting room. ON means the sidecar must admit every device, including the operator's iPad, at every restart.",
                paths: [["in_meeting", "waiting_room"], ["schedule_meeting", "waiting_room"]]),
        Concern(name: "coHost", group: "people",
                doc: "The host may name co-hosts. OFF means ARC crew cannot be given controls while the sidecar holds host.",
                paths: [["in_meeting", "co_host"]]),
        Concern(name: "joinBeforeHost", group: "people",
                doc: "Attendees may join before the host. OFF holds everyone until the sidecar has started the meeting.",
                paths: [["schedule_meeting", "join_before_host"]]),
        Concern(name: "muteOnEntry", group: "people",
                doc: "New arrivals join muted. The account default; the in-meeting SETTINGS chip overrides it per meeting.",
                paths: [["schedule_meeting", "mute_upon_entry"]]),
        Concern(name: "requestUnmute", group: "people",
                doc: "Ask each attendee once for permission to unmute them. Without it, a host unmute is only a request they must accept.",
                paths: [["in_meeting", "request_permission_to_unmute_participants"]]),
        Concern(name: "reactions", group: "people",
                doc: "Emoji reactions from attendees.",
                paths: [["in_meeting", "meeting_reactions"]]),
        Concern(name: "raiseHand", group: "people",
                doc: "Non-verbal feedback: the raised hands the sidecar queues for Q&A.",
                paths: [["in_meeting", "non_verbal_feedback"]]),
        Concern(name: "focusMode", group: "people",
                doc: "The host may turn on focus mode (attendees see only the host and the spotlight).",
                paths: [["in_meeting", "allow_host_to_enable_focus_mode"]]),

        // MARK: sharing
        Concern(name: "screenShare", group: "sharing",
                doc: "Screen sharing at all. OFF would stop the sidecar sending program into the call.",
                paths: [["in_meeting", "screen_sharing"]]),
        Concern(name: "whoMayShare", group: "sharing",
                doc: "Who may start a share. host keeps the room feed safe; all lets a presenter share their own deck.",
                paths: [["in_meeting", "who_can_share_screen"]], choices: ["host", "all"]),
        Concern(name: "shareWhileSharing", group: "sharing",
                doc: "Who may start a share while someone else is sharing. host stops a presenter cutting the program feed.",
                paths: [["in_meeting", "who_can_share_screen_when_someone_is_sharing"]], choices: ["host", "all"]),
        Concern(name: "simultaneousShare", group: "sharing",
                doc: "How many shares at once. one is what a single program feed wants.",
                paths: [["in_meeting", "participants_share_simultaneously"]], choices: ["one", "multiple"]),
        Concern(name: "annotation", group: "sharing",
                doc: "Attendees may draw on a shared screen. A presenter tool and a heckling risk.",
                paths: [["in_meeting", "annotation"]]),
        Concern(name: "remoteControl", group: "sharing",
                doc: "Attendees may request control of a shared screen.",
                paths: [["in_meeting", "remote_control"]]),
        Concern(name: "cameraControl", group: "sharing",
                doc: "Far-end camera control: another participant may drive a PTZ. ARC's own PTZ suite does this locally.",
                paths: [["in_meeting", "far_end_camera_control"]]),
        Concern(name: "whiteboard", group: "sharing",
                doc: "The Zoom whiteboard.",
                paths: [["in_meeting", "whiteboard"]]),

        // MARK: picture and sound
        Concern(name: "groupHD", group: "picture and sound",
                doc: "HD video in group meetings. What lets the program participant arrive above 360p.",
                paths: [["in_meeting", "group_hd"]]),
        Concern(name: "virtualBackground", group: "picture and sound",
                doc: "Virtual backgrounds and blur. The sidecar's own BLUR chip needs it.",
                paths: [["in_meeting", "virtual_background"]]),
        Concern(name: "e2eEncryption", group: "picture and sound",
                doc: "End-to-end encryption. MUST STAY OFF: it shuts off the raw data the sidecar draws from, and cloud recording with it.",
                paths: [["in_meeting", "e2e_encryption"]]),
        Concern(name: "audioType", group: "picture and sound",
                doc: "How attendees may connect audio: both, telephony (dial-in), voip, or a third-party bridge.",
                paths: [["schedule_meeting", "audio_type"]], choices: ["both", "telephony", "voip", "thirdParty"]),

        // MARK: chat
        Concern(name: "chat", group: "chat",
                doc: "Meeting chat. The sidecar's CHAT module reads and writes it.",
                paths: [["in_meeting", "chat"]]),
        Concern(name: "privateChat", group: "chat",
                doc: "Attendees may chat privately with each other. OFF keeps Q&A in the room.",
                paths: [["in_meeting", "private_chat"]]),
        Concern(name: "saveChat", group: "chat",
                doc: "Chat is saved automatically when the meeting ends.",
                paths: [["in_meeting", "auto_saving_chat"]]),

        // MARK: stream
        Concern(name: "allowLiveStreaming", group: "stream",
                doc: "Live streaming at all. The master switch above the RTMP service.",
                paths: [["in_meeting", "allow_live_streaming"]]),
        Concern(name: "liveStream", group: "stream",
                doc: "Custom live streaming service: the RTMP URL + key path out of the meeting to a client's platform.",
                paths: [["in_meeting", "custom_live_streaming_service"]]),

        // MARK: licence - facts about what ARC Tech has bought. They read; a PATCH will not move them.
        Concern(name: "webinar", group: "licence",
                doc: "Webinar licence. Workplace Pro caps a meeting at 100: a bigger event needs this or Large Meeting.",
                paths: [["feature", "webinar"]], readOnly: true),
        Concern(name: "translatedCaptions", group: "licence",
                doc: "Translated captions. A paid add-on, not a plain toggle.",
                paths: [["feature", "zoom_translated_captions"]], readOnly: true),
    ]

    static func concern(named name: String) -> Concern? { concerns.first { $0.name == name } }

    // MARK: - Reading

    struct Reading {
        /// name → value, for the toggle concerns the document actually carries.
        var values: [String: Bool] = [:]
        /// name → value, for the choice concerns (auto_recording and friends).
        var choices: [String: String] = [:]
        /// name → the path it was found at, for the answer and for the next reader.
        var paths: [String: [String]] = [:]
        /// Concerns no path matched: not ARC's to flip, or renamed again.
        var absent: [String] = []
        /// The whole settings document, for `GET /portal?full=1`.
        var document: [String: Any] = [:]

        /// One concern's value as text, whichever kind it is, or nil when it is absent. The write
        /// path compares with this so a toggle and a choice are checked the same way.
        func reading(_ name: String) -> String? {
            if let v = values[name] { return v ? "true" : "false" }
            return choices[name]
        }
    }

    enum PortalError: Error, CustomStringConvertible {
        case scopeMissing(String)
        case requestFailed(status: Int, body: String)
        case notJSON

        var description: String {
            switch self {
            case .scopeMissing(let body):
                return "the Zoom token cannot read account settings (needs user:read:settings, and "
                     + "user:update:settings to change them). Relaunch ARC Zoom: it asks for consent "
                     + "once when the stored token predates a scope. Zoom said: \(body)"
            case .requestFailed(let status, let body):
                return "Zoom refused the settings request (HTTP \(status)): \(body)"
            case .notJSON:
                return "Zoom's settings answer was not a JSON object"
            }
        }
    }

    static func read(accessToken: String) async throws -> Reading {
        let data = try await send(method: "GET", body: nil, accessToken: accessToken)
        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw PortalError.notJSON }
        return reading(from: doc)
    }

    /// The concern table resolved against one settings document. Pure, so the path matching is testable
    /// without a live account (which is the part that breaks when Zoom renames something).
    static func reading(from doc: [String: Any]) -> Reading {
        var reading = Reading()
        reading.document = doc
        for c in concerns {
            if c.isChoice {
                if let hit = c.paths.first(where: { text(at: $0, in: doc) != nil }), let v = text(at: hit, in: doc) {
                    reading.choices[c.name] = v
                    reading.paths[c.name] = hit
                    continue
                }
            } else if let hit = c.paths.first(where: { bool(at: $0, in: doc) != nil }), let v = bool(at: hit, in: doc) {
                reading.values[c.name] = v
                reading.paths[c.name] = hit
                continue
            }
            reading.absent.append(c.name)
        }
        return reading
    }

    // MARK: - Writing

    struct WriteResult {
        var before: Reading
        var after: Reading
        /// name → the value asked for, only for concerns that moved to it.
        var changed: [String: String] = [:]
        /// Asked for, patched, and still reading the old value: locked by the account or group.
        var refused: [String: String] = [:]
        /// Asked for and already there.
        var unchanged: [String: String] = [:]
        /// Asked for and not in the document at all, or not a value the setting takes.
        var unknown: [String] = []
        /// Asked for and not ARC's to set: a licence fact.
        var readOnly: [String] = []
    }

    /// Patch the wanted concerns, then read back and report what actually moved. Values arrive as the
    /// query string wrote them: "0"/"1" for a toggle, one of `choices` for a choice.
    static func write(_ wanted: [String: String], accessToken: String) async throws -> WriteResult {
        let before = try await read(accessToken: accessToken)
        var result = WriteResult(before: before, after: before)

        var patch: [String: Any] = [:]
        var asked: [String: String] = [:]
        for (name, raw) in wanted {
            guard let c = concern(named: name), let path = before.paths[name] else {
                result.unknown.append(name); continue
            }
            // A licence fact is not a setting. Patching it would answer 204 and change nothing, which
            // reads exactly like an account lock; say what it is instead.
            if c.readOnly { result.readOnly.append(name); continue }
            if let choices = c.choices {
                guard choices.contains(raw) else { result.unknown.append("\(name)=\(raw)"); continue }
                merge(raw, at: path, into: &patch)
                asked[name] = raw
            } else {
                let on = raw != "0"
                merge(on, at: path, into: &patch)
                asked[name] = on ? "true" : "false"
            }
        }
        guard !patch.isEmpty else { return result }

        let body = try JSONSerialization.data(withJSONObject: patch)
        _ = try await send(method: "PATCH", body: body, accessToken: accessToken)

        // A 204 is not proof. Read it back: a locked setting is patched in silence and does not move.
        let after = try await read(accessToken: accessToken)
        result.after = after
        for (name, want) in asked {
            let now = after.reading(name), was = before.reading(name)
            if now == want {
                if was == want { result.unchanged[name] = want } else { result.changed[name] = want }
            } else {
                result.refused[name] = want
            }
        }
        return result
    }

    // MARK: - The personal meeting ID

    /// Zoom's own rules for a custom PMI (support KB0068443, read 2026-09-21), checked here first so
    /// the operator gets the rule by name rather than a bare 400: 10 digits; first digit 2-9; no 5 of
    /// the same digit in a row; no run of 8 identical digits; no 3-digit group repeated three times;
    /// not a straight sequence; not one of the toll-free / reserved prefixes.
    static func pmiProblem(_ text: String) -> String? {
        guard text.count == 10, text.allSatisfy(\.isNumber) else { return "a PMI is exactly 10 digits (Zoom does not customise 11 or 12)" }
        guard let first = text.first, "23456789".contains(first) else { return "a PMI cannot start with 0 or 1" }
        let reserved = ["800", "400", "888", "887", "877", "866", "855", "850", "803", "804", "807", "808", "809", "660", "508", "900", "200", "300", "500", "600", "700"]
        if let r = reserved.first(where: { text.hasPrefix($0) }) { return "a PMI cannot start with \(r) (reserved by Zoom)" }
        let digits = Array(text)
        var run = 1
        for i in 1..<digits.count { run = digits[i] == digits[i - 1] ? run + 1 : 1; if run >= 5 { return "no digit 5 or more times in a row" } }
        let group = String(digits[0..<3])
        if String(digits[3..<6]) == group, String(digits[6..<9]) == group { return "a 3-digit group may not repeat three times (\(group)\(group)\(group)x)" }
        let asc = "1234567890", desc = "0987654321"
        if asc.contains(String(digits[0..<9])) || desc.contains(String(digits[0..<9])) { return "sequential digits are not allowed" }
        return nil
    }

    /// PATCH the PMI, then read the profile back: the answer is what Zoom now holds, not what was asked.
    static func setPMI(_ pmi: String, accessToken: String) async throws -> Int64? {
        let body = try JSONSerialization.data(withJSONObject: ["pmi": Int64(pmi) ?? 0])
        _ = try await send(method: "PATCH", path: "/v2/users/me", body: body, accessToken: accessToken)
        return try await TokenFetcher.fetchUserInfo(accessToken: accessToken).pmi
    }

    // MARK: - HTTP

    private static func send(method: String, path: String = "/v2/users/me/settings", body: Data?, accessToken: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.zoom.us" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let text = String(data: data, encoding: .utf8) ?? ""
        // 4711 is Zoom's "this token has no such scope"; it arrives as a 400 with that code in the body.
        if status == 400 && text.contains("4711") { throw PortalError.scopeMissing(text) }
        if status == 401 || status == 403 { throw PortalError.scopeMissing(text) }
        guard (200...299).contains(status) else { throw PortalError.requestFailed(status: status, body: text) }
        return data
    }

    // MARK: - Nested dictionary helpers

    /// The boolean at a dotted path, or nil when any step is missing or it is not a boolean. Zoom sends
    /// booleans as JSON true/false, which bridges to NSNumber, so check the type before trusting it.
    static func bool(at path: [String], in doc: [String: Any]) -> Bool? {
        var node: Any = doc
        for step in path {
            guard let dict = node as? [String: Any], let next = dict[step] else { return nil }
            node = next
        }
        guard let number = node as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// The string at a path, for the choice concerns. A boolean is not a string, so it does not match.
    static func text(at path: [String], in doc: [String: Any]) -> String? {
        var node: Any = doc
        for step in path {
            guard let dict = node as? [String: Any], let next = dict[step] else { return nil }
            node = next
        }
        if let number = node as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        return node as? String
    }

    /// Put a value at a path, keeping whatever siblings are already in the patch (two caption concerns
    /// live under the same parent, so a plain assignment would drop one of them).
    static func merge(_ value: Any, at path: [String], into patch: inout [String: Any]) {
        guard let head = path.first else { return }
        if path.count == 1 {
            patch[head] = value
            return
        }
        var child = patch[head] as? [String: Any] ?? [:]
        merge(value, at: Array(path.dropFirst()), into: &child)
        patch[head] = child
    }
}

// MARK: - The answers GET/POST /portal give

extension ZoomPortal.Reading {
    /// One row per concern: where it lives, what it is, what it is for. A toggle answers true/false, a
    /// choice answers its string and lists what it takes, and an absent setting answers null.
    func json(full: Bool) -> String {
        let rows = ZoomPortal.concerns.map { c -> String in
            let value: String
            if let v = values[c.name] { value = v ? "true" : "false" }
            else if let t = choices[c.name] { value = "\"\(jsonEscape(t))\"" }
            else { value = "null" }
            let path = paths[c.name]?.joined(separator: ".") ?? ""
            var row = "{\"name\":\"\(c.name)\",\"group\":\"\(c.group)\",\"value\":\(value),\"path\":\"\(jsonEscape(path))\""
            if c.readOnly { row += ",\"readOnly\":true" }
            if let choices = c.choices {
                row += ",\"takes\":[\(choices.map { "\"\($0)\"" }.joined(separator: ","))]"
            }
            return row + ",\"doc\":\"\(jsonEscape(c.doc))\"}"
        }.joined(separator: ",")
        var out = "{\"settings\":[\(rows)],\"absent\":[\(absent.map { "\"\($0)\"" }.joined(separator: ","))]"
        out += ",\"note\":\"portal changes apply to NEW meetings only\""
        if full, let data = try? JSONSerialization.data(withJSONObject: document),
           let text = String(data: data, encoding: .utf8) {
            out += ",\"document\":\(text)"
        }
        return out + "}"
    }
}

extension ZoomPortal.WriteResult {
    func json() -> String {
        func pairs(_ d: [String: String]) -> String {
            d.keys.sorted().map { "\"\($0)\":\"\(jsonEscape(d[$0]!))\"" }.joined(separator: ",")
        }
        var out = "{\"changed\":{\(pairs(changed))},\"alreadySo\":{\(pairs(unchanged))}"
        out += ",\"refused\":{\(pairs(refused))}"
        out += ",\"unknown\":[\(unknown.sorted().map { "\"\(jsonEscape($0))\"" }.joined(separator: ","))]"
        out += ",\"readOnly\":[\(readOnly.sorted().map { "\"\(jsonEscape($0))\"" }.joined(separator: ","))]"
        if !refused.isEmpty {
            out += ",\"refusedMeans\":\"patched without error and still reading the old value: locked on the account or the group\""
        }
        out += ",\"now\":\(after.json(full: false))}"
        return out
    }
}
