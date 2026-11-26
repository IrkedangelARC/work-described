//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ARCShowFormat
import Observation

/// The open show's rundown, bound to the show folder: loaded when the folder
/// attaches, saved after every change, gone when the folder closes (the stage
/// timer inside Presenter, phase 1).
///
/// It follows the folder through the notifications `ShowFolderSession`
/// posts, so neither object holds the other and the tests can drive it with a
/// temp folder and no session at all.
@MainActor @Observable
final class RundownStore {
    private(set) var folder: URL?
    private(set) var rundown: Rundown? {
        didSet { onChange?() }   // open, close and every edit: the cue timer reconciles against the rows (review, 2026-09-19)
    }
    private(set) var lastError: String?

    var isOpen: Bool { folder != nil }
    var hasRundown: Bool { rundown != nil }
    var cueCount: Int { rundown?.cues.count ?? 0 }
    var totalSeconds: Int { rundown?.totalSeconds ?? 0 }

    private var observers: [Any] = []
    /// After every change that persisted: the cue timer reconciles what it holds against the rows.
    var onChange: (() -> Void)?
    /// The last cue removed and where it was, for one step back. A row on a
    /// console must not vanish for good on one click (2026-09-18, two
    /// talks gone in two seconds while looking at the window).
    private(set) var lastRemoved: (cue: RundownCue, index: Int)?
    var canUndoRemove: Bool { lastRemoved != nil }

    init(followingShowFolder: Bool = true) {
        guard followingShowFolder else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .showFolderAttached, object: nil, queue: .main) { [weak self] n in
            guard let url = n.object as? URL else { return }
            Task { @MainActor in self?.open(folder: url) }
        })
        observers.append(nc.addObserver(forName: .showFolderClosed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        })
    }

    // MARK: - Folder

    func open(folder: URL) {
        self.folder = folder
        lastError = nil
        do {
            rundown = try Rundown.load(from: folder)
            if let r = rundown { ShowLog.log("rundown: \(r.cues.count) cue(s), \(Rundown.clock(r.totalSeconds)) total, from \(Rundown.fileName)") }
        } catch {
            rundown = nil
            lastError = "state/\(Rundown.fileName) will not read: \(error.localizedDescription)"
            ShowLog.error("rundown: \(lastError!)")
        }
    }

    func close() {
        folder = nil
        rundown = nil
        lastError = nil
        lastRemoved = nil
    }

    /// An empty rundown for a folder that has none, named after the show.
    func create(name: String, arcNumber: String? = nil, date: String? = nil) {
        guard folder != nil else { refuse("no show folder is open"); return }
        rundown = Rundown(name: name, arcNumber: arcNumber, date: date)
        persist("created")
    }

    // MARK: - Edits (each one saved)

    func add(_ cue: RundownCue, at index: Int? = nil) {
        guard rundown != nil else { refuse("no rundown to add to"); return }
        let i = min(max(0, index ?? rundown!.cues.count), rundown!.cues.count)
        rundown!.cues.insert(cue, at: i)
        persist("added \(cue.title)")
    }

    func remove(id: UUID) {
        guard let i = rundown?.cues.firstIndex(where: { $0.id == id }) else { refuse("no such cue to remove"); return }
        let title = rundown!.cues[i].title
        lastRemoved = (rundown!.cues[i], i)
        rundown!.cues.remove(at: i)
        persist("removed \(title)")
    }

    /// Put the last removed cue back where it was.
    func undoRemove() {
        guard rundown != nil, let (cue, i) = lastRemoved else { refuse("nothing to put back"); return }
        rundown!.cues.insert(cue, at: min(i, rundown!.cues.count))
        lastRemoved = nil
        persist("put back \(cue.title)")
    }

    func move(from source: IndexSet, to destination: Int) {
        guard rundown != nil else { return }
        rundown!.cues.move(fromOffsets: source, toOffset: destination)
        persist("reordered")
    }

    func update(_ cue: RundownCue) {
        guard let i = rundown?.cues.firstIndex(where: { $0.id == cue.id }) else {
            // A row's field loses focus as the row is removed and commits once more: not an error (review, 2026-09-19).
            if lastRemoved?.cue.id != cue.id { refuse("no such cue to update") }
            return
        }
        var c = cue
        c.clampThresholds()
        rundown!.cues[i] = c
        persist("edited \(c.title)")
    }

    func rename(_ name: String) {
        guard rundown != nil else { return }
        rundown!.name = name
        persist("renamed")
    }

    // MARK: - ROS files

    @discardableResult
    func importROS(from url: URL, replace: Bool = true) -> Bool {
        guard folder != nil else { refuse("open a show folder before importing a rundown"); return false }
        do {
            let incoming = try Rundown.fromROS(try Data(contentsOf: url))
            if replace || rundown == nil {
                rundown = incoming
            } else {
                rundown!.cues.append(contentsOf: incoming.cues)
            }
            persist("imported \(incoming.cues.count) cue(s) from \(url.lastPathComponent)")
            return true
        } catch {
            refuse("import of \(url.lastPathComponent) failed: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func exportROS(to url: URL) -> Bool {
        guard let r = rundown else { refuse("no rundown to export"); return false }
        do {
            try r.rosData().write(to: url, options: .atomic)
            ShowLog.log("rundown exported: \(r.cues.count) cue(s) to \(url.lastPathComponent)")
            return true
        } catch {
            refuse("export to \(url.lastPathComponent) failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: -

    private func persist(_ what: String) {
        defer { onChange?() }
        guard let folder, let r = rundown else { return }
        do {
            try r.save(to: folder)
            lastError = nil
            ShowLog.log("rundown \(what): \(r.cues.count) cue(s), \(Rundown.clock(r.totalSeconds))")
        } catch {
            lastError = "rundown not saved: \(error.localizedDescription)"
            ShowLog.error(lastError!)
        }
    }

    /// Every refusal says why and logs it (a silent false on this console
    /// cost a drill on 2026-09-18).
    private func refuse(_ why: String) {
        lastError = why
        ShowLog.log("rundown refused: \(why)")
    }
}

extension Notification.Name {
    /// Posted by `ShowFolderSession` with the folder URL as `object`.
    static let showFolderAttached = Notification.Name("com.example.arc.showFolderAttached")
    static let showFolderClosed = Notification.Name("com.example.arc.showFolderClosed")
}
