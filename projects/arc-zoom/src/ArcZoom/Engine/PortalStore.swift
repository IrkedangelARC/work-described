//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Observation

/// The house account settings, held for the PORTAL window.
///
/// The settings themselves are not in the meeting and the SDK cannot see them: they come over REST
/// (`ZoomPortal`) and they apply to NEW meetings only. So this store is deliberately NOT part of the
/// 1 Hz sampler - it reads when the window opens or the operator asks, and after every write, because a
/// write is only believed once it has been read back.
@MainActor
@Observable
final class PortalStore {
    /// One settled row for the view: the concern and the value the account actually holds.
    struct Row: Identifiable {
        let concern: ZoomPortal.Concern
        /// nil when the setting is not in the document at all.
        let value: String?
        /// The path it was FOUND at, which is not always the first candidate: `closed_captioning.enable`
        /// on this account, the flat `closed_caption` on an older one.
        let foundPath: String
        var id: String { concern.name }
        var isOn: Bool { value == "true" }
        var isAbsent: Bool { value == nil }
    }

    private(set) var reading: ZoomPortal.Reading?
    private(set) var loading = false
    /// The name being written, so its chip can show it is in flight.
    private(set) var writing: String?
    private(set) var error: String?
    private(set) var readAt: Date?
    /// Names that were patched without error and did not move: locked on the account or the group.
    private(set) var locked: Set<String> = []

    var rows: [Row] {
        guard let reading else { return [] }
        return ZoomPortal.concerns.map {
            Row(concern: $0, value: reading.reading($0.name),
                foundPath: reading.paths[$0.name]?.joined(separator: ".") ?? $0.paths.first?.joined(separator: ".") ?? "")
        }
    }

    func rows(in group: String) -> [Row] { rows.filter { $0.concern.group == group } }

    /// The ONE thing an operator needs to see before a show: what is set wrong for a live event. Each
    /// line names the setting and what it costs, measured against how ARC runs a show.
    var warnings: [String] {
        guard let r = reading else { return [] }
        var out: [String] = []
        func on(_ n: String) -> Bool? { r.values[n] }
        if on("captions") == false { out.append("CAPTIONS off: live transcription will start and deliver no text") }
        if on("captions") == true, on("autoCaptions") == false { out.append("AUTO CAPTIONS off: captions need a human captioner or a vendor") }
        if on("cloudRecording") == false { out.append("CLOUD RECORDING off: there is NO recording path, local recording cannot run beside raw video") }
        if on("e2eEncryption") == true { out.append("E2E ENCRYPTION on: raw video and cloud recording both stop. Turn it off") }
        if on("groupHD") == false { out.append("GROUP HD off: the program participant cannot arrive above 360p") }
        if on("recordingDisclaimer") == true { out.append("RECORDING DISCLAIMER on: a consent dialog nobody is at the rack to answer") }
        if r.choices["autoRecording"] != nil, r.choices["autoRecording"] != "none" {
            out.append("AUTO RECORDING \(r.choices["autoRecording"]!.uppercased()): recording starts by itself instead of when the operator arms REC")
        }
        if on("screenShare") == false { out.append("SCREEN SHARING off: the sidecar cannot send program into the call") }
        if on("coHost") == false { out.append("CO-HOST off: ARC crew cannot be given controls while the sidecar holds host") }
        if on("waitingRoom") == true { out.append("WAITING ROOM on: every device, including the iPad, must be admitted at each restart") }
        return out
    }

    /// Take a reading that came from somewhere other than the network. Only the tests use it, and they
    /// are the reason the warning rules can be checked without an account.
    func adopt(_ reading: ZoomPortal.Reading) {
        self.reading = reading
        readAt = Date()
    }

    // MARK: - Reading and writing

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        guard let token = await token() else { return }
        do {
            reading = try await ZoomPortal.read(accessToken: token)
            readAt = Date()
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    /// Flip one setting and read it back. A refusal is kept per name so the row can say so, rather than
    /// the chip silently springing back with no reason.
    func set(_ name: String, to value: String) async {
        guard writing == nil else { return }
        writing = name
        defer { writing = nil }
        guard let token = await token() else { return }
        do {
            let result = try await ZoomPortal.write([name: value], accessToken: token)
            reading = result.after
            readAt = Date()
            if result.refused[name] != nil {
                locked.insert(name)
                error = "\(name) is locked on the account or the group: Zoom took the change and kept the old value"
            } else {
                locked.remove(name)
                error = nil
                ShowLog.log("portal: \(name) = \(value)")
            }
        } catch {
            self.error = "\(error)"
        }
    }

    func toggle(_ row: Row) async {
        guard !row.concern.readOnly, !row.isAbsent else { return }
        await set(row.concern.name, to: row.isOn ? "0" : "1")
    }

    private func token() async -> String? {
        guard let sdk = ArcZoomApp.sharedSidecar.engine as? SDKZoomEngine else {
            error = "account settings need the SDK engine: CREATE MEETING or switch the engine first"
            return nil
        }
        guard let token = await sdk.freshAccessToken() else {
            error = "no Zoom access token; sign in first"
            return nil
        }
        return token
    }
}
