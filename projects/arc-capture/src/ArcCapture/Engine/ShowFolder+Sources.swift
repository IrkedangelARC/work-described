//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ARCShowFormat

/// A linked source folder, mirrored into `decks/` and kept so (SourceFolder.swift
/// plans, this does). The source is READ ONLY: nothing here writes, renames or
/// deletes anything outside the show folder. docs/PLAN_drive_source_folders.md.
extension ShowFolderStore {
    var sourcesURL: URL { sub(.state).appendingPathComponent("sources.json") }
    var linkedSource: URL? { sourceLedger.folders.first.map { URL(fileURLWithPath: $0) } }
    static let sourcePollSeconds: Double = 20

    func loadSources() {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: sourcesURL), let l = try? decoder.decode(SourceFolder.Ledger.self, from: data) { sourceLedger = l }
        // A show fed before the pipeline existed brought its files in on LINK: that was the consent, keep it.
        if sourceLedger.confirmedOrder == nil, !sourceLedger.links.isEmpty {
            sourceLedger.confirmedOrder = sourceLedger.links.filter { $0.goneSince == nil }.map { Self.itemID(from: $0.deck).id }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        if linkedSource != nil { startSourcePoll() }
    }

    func saveSources() {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: sub(.state), withIntermediateDirectories: true)
            try encoder.encode(sourceLedger).write(to: sourcesURL, options: .atomic)
        } catch { say("sources.json could not be written: \(error.localizedDescription)") }
    }

    // MARK: Controls

    /// One source per show: two folders would both want session 1.
    func linkSource(_ url: URL, dryRun: Bool = false) async {
        let path = url.path
        guard FileManager.default.fileExists(atPath: url.resolvingSymlinksInPath().path) else { say("source folder not found: \(path)"); return }
        if let had = linkedSource, had.path != path { say("source \(had.lastPathComponent) unlinked; what it brought stays in decks/") ; sourceLedger.links = [] }
        sourceLedger.folders = [path]
        saveSources()
        say("source linked (read only): \(path)")
        // Linking ASSESSES. Nothing is copied until the TD has confirmed the run order (headless: --sync-source).
        if dryRun { await syncSources(dryRun: true) } else { await assess() }
        startSourcePoll()
    }

    /// STOP: the mirror stops, what was copied stays.
    func unlinkSource() {
        sourcePoll?.cancel(); sourcePoll = nil
        guard let had = linkedSource else { return }
        sourceLedger.folders = []
        saveSources()
        say("source \(had.lastPathComponent) unlinked; what it brought stays in decks/")
    }

    private func startSourcePoll() {
        sourcePoll?.cancel()
        sourcePoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.sourcePollSeconds))
                guard let self, !Task.isCancelled else { return }
                // Never while a capture runs: a copy landing in decks/ is a rescan, and the Mac is not to be touched.
                // And never before the run order was confirmed: until then the poll only keeps the assessment fresh.
                guard !self.busy, !self.syncing else { continue }
                if self.sourceLedger.confirmedOrder != nil { await self.syncSources(quiet: true) }
                await self.assess(quiet: true)
                await self.autoCaptureIfDue()
            }
        }
    }

    // MARK: Sync

    /// List the source, plan against the ledger, copy what is new or changed into `decks/`.
    /// `dryRun` lists and plans only: nothing is copied and nothing is remembered.
    @discardableResult
    func syncSources(dryRun: Bool = false, quiet: Bool = false) async -> [SourceFolder.Action] {
        guard let source = linkedSource, !syncing else { return [] }
        setSyncing(true); defer { setSyncing(false) }
        let root = source.resolvingSymlinksInPath()
        let began = Date()
        let entries = await Task.detached(priority: .utility) { Self.list(root) }.value
        guard let entries else {
            if !quiet { say("source not reachable: \(source.path) (is Google Drive running?)") }
            return []
        }
        let plan = SourceFolder.plan(entries: entries, ledger: sourceLedger.links, excluded: Set(sourceLedger.excluded ?? [])) { ext in
            ext == "gslides" || Self.kind(of: URL(fileURLWithPath: "x.\(ext)")).map { $0 != .arcdeck } == true
        }
        // The count and the reasons are ONE report. They used to have different conditions, so a quiet run
        // with changes printed "21 passed over" and suppressed every line saying why: the same silent drop
        // the reasons were added to cure (2026-09-18).
        let announced = !quiet || !plan.actions.isEmpty
        if announced {
            say("source \(source.lastPathComponent): \(entries.count) file(s), \(plan.actions.count) change(s), \(plan.ignored.count) passed over" + (dryRun ? " (dry run)" : ""))
            for skip in plan.ignored { say("  passed over: \(skip.rel) (\(skip.reason))") }
        }
        if dryRun {
            for a in plan.actions { say("  would \(a.kind.rawValue): \(a.rel)\(a.deck.isEmpty ? "" : " -> decks/\(a.deck)") (\(a.detail))") }
            return plan.actions
        }

        var links = plan.links
        let decks = sub(.decks)
        let copies = plan.actions.filter { $0.kind == .add || $0.kind == .update }
        var copied = 0
        for a in plan.actions {
            if stopRequested, a.kind == .add || a.kind == .update { say("  stopped: \(copies.count - copied) file(s) not brought in"); links = links.filter { l in l.deck != a.deck || sourceLedger.links.contains { $0.deck == a.deck } }; continue }
            switch a.kind {
            case .add, .update:
                let from = root.appendingPathComponent(a.rel), to = decks.appendingPathComponent(a.deck)
                // The copy this one replaces, when the client's new file has another name or type.
                let key = links.first { $0.deck == a.deck }?.key
                let old = sourceLedger.links.first { $0.key == key && $0.deck != a.deck }?.deck
                let t = Date()
                let bytes = entries.first { $0.rel == a.rel }?.size ?? 0
                copied += 1
                setStatus("bringing in \(a.deck)")
                setActivity(Activity(step: .capture, title: "Bringing in \(a.deck)", detail: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " from the source folder",
                                     index: copied, count: copies.count))
                say("  \(a.kind.rawValue): \(a.rel) (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))) ...")
                let error = await Task.detached(priority: .utility) { Self.bring(from, to: to, replacing: old.map { decks.appendingPathComponent($0) }) }.value
                if let error {
                    say("  \(a.kind.rawValue) FAILED: \(a.rel): \(error)")
                    // Not remembered, so the next sync tries again.
                    if a.kind == .add { links.removeAll { $0.deck == a.deck } }
                    else if let i = links.firstIndex(where: { $0.deck == a.deck }), let was = sourceLedger.links.first(where: { $0.key == links[i].key }) { links[i] = was }
                } else {
                    say(String(format: "    -> decks/%@ (%@, %.1f s)", a.deck, a.detail, Date().timeIntervalSince(t)))
                    rescan()      // the item shows up in the list as it lands, not when the whole folder is done
                }
            case .shadowed, .gone, .back:
                say("  \(a.kind.rawValue): \(a.rel) (\(a.detail))")
            }
        }
        sourceLedger.links = links
        lastSourceSync = Date()
        if !copies.isEmpty { setActivity(nil) }
        if !plan.actions.isEmpty {
            saveSources()
            rescan()
            say(String(format: "source sync done in %.1f s", Date().timeIntervalSince(began)))
        }
        return plan.actions
    }

    // MARK: Off the main actor

    /// nil = the folder cannot be read (Drive not running, the volume gone): that is not "everything vanished".
    nonisolated static func list(_ root: URL) -> [SourceFolder.Entry]? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        guard (try? fm.contentsOfDirectory(atPath: root.path)) != nil,
              let walk = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var out: [SourceFolder.Entry] = []
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in walk {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true || v.isPackage == true else { continue }
            guard url.path.hasPrefix(base) else { continue }
            out.append(SourceFolder.Entry(rel: String(url.path.dropFirst(base.count)), size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast))
        }
        return out
    }

    /// Copy into `decks/` through a dot name (the rescan ignores it), then swap it in whole: a half copy is never an item.
    /// Reading a streamed Drive file is what downloads it. A Google Slides pointer becomes a link file.
    nonisolated static func bring(_ from: URL, to: URL, replacing old: URL?) -> String? {
        let fm = FileManager.default
        let temp = to.deletingLastPathComponent().appendingPathComponent(".incoming-\(UUID().uuidString)")
        do {
            if from.pathExtension.lowercased() == "gslides" {
                let modified = (try? from.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                guard let text = SourceFolder.linkFile(pointer: try Data(contentsOf: from), modified: modified) else { return "the pointer holds no doc_id" }
                try Data(text.utf8).write(to: temp)
            } else {
                try fm.copyItem(at: from, to: temp)
            }
            if let old, old.path != to.path, fm.fileExists(atPath: old.path) {
                let kept = to.deletingLastPathComponent().appendingPathComponent(".replaced", isDirectory: true)
                try fm.createDirectory(at: kept, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                try fm.moveItem(at: old, to: kept.appendingPathComponent("\(stamp) \(old.lastPathComponent)"))
            }
            if fm.fileExists(atPath: to.path) { _ = try fm.replaceItemAt(to, withItemAt: temp) } else { try fm.moveItem(at: temp, to: to) }
            return nil
        } catch {
            try? fm.removeItem(at: temp)
            return error.localizedDescription
        }
    }
}
