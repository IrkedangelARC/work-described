//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import AVFoundation
import PDFKit
import Observation
import ARCShowFormat

/// The operator's go/no-go before doors (stability plan 3.4). One run checks
/// the permissions this Mac has granted, that the saved show's displays and
/// SDI device are present, disk space, that every saved deck opens and every
/// clip in it is playable, and that the control API answers. PASS/FAIL per
/// row, all of it in the show log. Runs from THIS MAC on the load screen and
/// from `POST /preshow`.
@MainActor
@Observable
final class PreShowCheck {
    struct Row: Identifiable {
        let id: String
        let label: String
        let ok: Bool
        let required: Bool
        let detail: String
    }

    private(set) var rows: [Row] = []
    private(set) var isRunning = false
    private(set) var lastRun: Date?
    var passed: Bool { rows.filter(\.required).allSatisfy(\.ok) }
    var summary: String {
        guard lastRun != nil else { return "" }
        let failed = rows.filter { !$0.ok }
        if failed.isEmpty { return "PASS: \(rows.count) checks" }
        let required = failed.filter(\.required).count
        return "\(required > 0 ? "FAIL" : "PASS with warnings"): \(failed.count) of \(rows.count) flagged"
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        var list: [Row] = []

        // 1. Permissions (the THIS MAC rows).
        let readiness = Readiness()
        readiness.refresh()
        for c in readiness.checks {
            list.append(Row(id: "perm.\(c.id)", label: c.label, ok: c.ok, required: c.required, detail: c.hint))
        }

        // 2. The saved show: displays, SDI, decks.
        let disp = ArcPresenterApp.sharedDisplayManager
        disp.detectScreens()
        if let saved = SessionStore.load() {
            for (out, label) in [(saved.program, "PROGRAM DISPLAY"), (saved.confidence, "MONITOR DISPLAY")] {
                guard let out else { continue }
                let present = disp.availableScreens.contains { $0.uuid == out.uuid || $0.id == out.displayID }
                list.append(Row(id: "display.\(label)", label: label, ok: present, required: true,
                                detail: present ? "\(out.name) is connected" : "\(out.name) (last show's \(label.lowercased())) is NOT connected"))
            }
            if let dlSaved = saved.decklink, dlSaved.running {
                let dl = ArcPresenterApp.sharedDeckLink
                dl.refreshDevices()
                let present = dl.devices.contains { $0.persistentID == dlSaved.persistentID || $0.name == dlSaved.name }
                list.append(Row(id: "sdi", label: "SDI DEVICE", ok: present, required: true,
                                detail: present ? "\(dlSaved.name) present" : "\(dlSaved.name) (last show's SDI output) is NOT connected"))
            }
            for (i, deckState) in saved.decks.enumerated() {
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: deckState.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                    list.append(Row(id: "deck.\(i)", label: "DECK \(i + 1)", ok: false, required: true, detail: "saved deck \(i + 1) cannot be located"))
                    continue
                }
                let name = url.lastPathComponent
                guard FileManager.default.fileExists(atPath: url.path) else {
                    list.append(Row(id: "deck.\(i)", label: name, ok: false, required: true, detail: "missing: \(url.path)"))
                    continue
                }
                let verdict = await Self.verify(deck: url, kind: deckState.kind)
                list.append(Row(id: "deck.\(i)", label: name, ok: verdict.ok, required: true, detail: verdict.detail))
            }
            if saved.decks.isEmpty && saved.powerPoint == nil {
                list.append(Row(id: "decks", label: "DECKS", ok: false, required: false, detail: "no decks in the saved show"))
            }
            if let ppt = saved.powerPoint {
                let exists = FileManager.default.fileExists(atPath: ppt.path)
                list.append(Row(id: "ppt.file", label: "POWERPOINT DECK", ok: exists, required: true,
                                detail: exists ? URL(fileURLWithPath: ppt.path).lastPathComponent : "missing: \(ppt.path)"))
            }
        } else {
            list.append(Row(id: "session", label: "SAVED SHOW", ok: false, required: false, detail: "no saved show on this Mac yet: open the decks and assign the outputs first"))
        }

        // 2b. ARC Capture's preflight of the open show folder, when there is one.
        for r in ArcPresenterApp.sharedShow.preflightRows {
            list.append(Row(id: "capture.\(r.label)", label: "CAPTURE: \(r.label)", ok: r.ok, required: r.required, detail: r.detail))
        }

        // 3. Disk.
        var freeGB = 0.0
        if let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage { freeGB = Double(free) / 1_000_000_000 }
        list.append(Row(id: "disk", label: "DISK", ok: freeGB >= 10, required: freeGB < 2, detail: String(format: "%.0f GB free", freeGB)))

        // 4. Control API.
        let apiOK = await Self.apiAnswers()
        list.append(Row(id: "api", label: "CONTROL API", ok: apiOK, required: false, detail: apiOK ? "answering on localhost:8760" : "not answering on localhost:8760 (Companion and Claude sessions cannot drive the app)"))

        rows = list
        lastRun = Date()
        ShowLog.log("PRE-SHOW CHECK \(summary)")
        for r in list where !r.ok { ShowLog.log("  \(r.required ? "FAIL" : "WARN") \(r.label): \(r.detail)") }
    }

    /// Off main: the PDF opens, the manifest parses, every clip exists and is playable.
    nonisolated static func verify(deck url: URL, kind: String) async -> (ok: Bool, detail: String) {
        await Task.detached(priority: .userInitiated) { () -> (Bool, String) in
            switch kind {
            case "video":
                let asset = AVURLAsset(url: url)
                let playable = (try? await asset.load(.isPlayable)) ?? false
                return (playable, playable ? "video playable" : "video NOT playable")
            case "arcdeck":
                let v = await DeckVerifier.verifyNow(arcdeck: url)
                return (v.ok, v.detail)
            default:
                guard let doc = PDFDocument(url: url) else { return (false, "PDF will not open") }
                return (true, "\(doc.pageCount) pages")
            }
        }.value
    }

    nonisolated static func apiAnswers() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8760/state") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200 && !data.isEmpty
    }

    var json: String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let list = rows.map { "{\"id\":\"\($0.id)\",\"label\":\"\(esc($0.label))\",\"ok\":\($0.ok),\"required\":\($0.required),\"detail\":\"\(esc($0.detail))\"}" }.joined(separator: ",")
        return "{\"passed\":\(passed),\"summary\":\"\(esc(summary))\",\"rows\":[\(list)]}"
    }
}
