//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import ARCShowFormat
import AppKit
import UniformTypeIdentifiers

/// RUNDOWN: the show's cues, in order, edited in place (the stage timer
/// inside Presenter, phase 1). Its own window like SOURCES, opened from the
/// Window menu; the operator footer gets a chip in phase 4.
///
/// What the stage timer's console called the cue list: title, who is on, how
/// long, and the two thresholds. Reorder by drag. Every edit is saved to the
/// show folder as it is made.
struct RundownWindowView: View {
    @Environment(RundownStore.self) private var store
    @Environment(CueTimer.self) private var cue

    var body: some View {
        VStack(spacing: ARCTheme.paddingSmall) {
            header
            if store.rundown != nil { transport }
            if !store.isOpen {
                empty("OPEN A SHOW FOLDER FIRST", detail: "The rundown lives in the show folder as state/rundown.json and travels with it.")
            } else if let r = store.rundown {
                cueList(r)
                footer(r)
            } else {
                empty("NO RUNDOWN IN THIS FOLDER", detail: "Start one, or import the run of show the old stage timer exported.") {
                    HStack(spacing: 8) {
                        chip("NEW RUNDOWN", tint: ARCTheme.secGreen) { store.create(name: showName) }
                        chip("IMPORT…") { importROS() }
                    }
                }
            }
            if let e = store.lastError {
                Text(e).font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.warn)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(ARCTheme.paddingMedium)
        .frame(minWidth: 720, minHeight: 420)
        .background(ARCTheme.background)
    }

    private var showName: String {
        store.folder?.lastPathComponent ?? "Show"
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Text("RUNDOWN").font(ARCTheme.moduleTitle).foregroundStyle(ARCTheme.textSecondary)
            if let r = store.rundown {
                Text(r.name.uppercased()).font(ARCTheme.statusBadge).foregroundStyle(ARCTheme.textPrimary).lineLimit(1)
                if let n = r.arcNumber, !n.isEmpty {
                    Text(n).font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.textSecondary)
                }
                // A rundown that would look authoritative and is not (no test
                // data on a live console): say so where the operator reads.
                if r.looksLikeTestData {
                    mark("TEST DATA", help: "This rundown has a test ARC number or placeholder people. It is not a show's run of show.")
                } else if !r.belongs(toFolderNamed: showName) {
                    mark("OTHER JOB", help: "This rundown names \(r.arcNumber ?? "another job") and this folder is not it.")
                }
            }
            Spacer()
            if store.rundown != nil {
                chip("ADD CUE", tint: ARCTheme.secGreen) { addCue() }
                chip("IMPORT…") { importROS() }
                chip("EXPORT…") { exportROS() }
            }
        }
    }

    /// The controls. Robust means: one button per verb, each always does
    /// the same thing, and the clock is the biggest thing on the window.
    private var transport: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cue.now == nil ? "NOTHING SELECTED" : "NOW").font(ARCTheme.moduleTitle).foregroundStyle(cue.isRunning ? ARCTheme.liveRed : ARCTheme.textSecondary)
                Text(cue.now?.title ?? "click a row, or START takes the first cue").font(ARCTheme.mono(14)).foregroundStyle(ARCTheme.textPrimary).lineLimit(1)
                Text(cue.now?.speakers ?? " ").font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.arcRed).lineLimit(1)
                if let n = cue.next {
                    Text("NEXT  \(n.title)").font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 0) {
                Text(cue.displayString).font(.system(size: 44, weight: .bold, design: .monospaced)).foregroundStyle(shadeColor).monospacedDigit()
                if cue.isOver { Text("OVER").font(ARCTheme.statusBadge).foregroundStyle(ARCTheme.liveRed) }
            }
            .frame(minWidth: 170)
            HStack(spacing: 6) {
                control("PREV", enabled: cue.hasPrevious) { cue.goPrevious() }
                control(cue.isRunning ? "STOP" : "START", tint: cue.isRunning ? ARCTheme.liveRed : ARCTheme.secGreen, wide: true) { cue.toggle() }
                control("RESET", enabled: cue.now != nil) { cue.reset() }
                control("NEXT", enabled: cue.hasNext || cue.now == nil) { cue.goNext() }
            }
            .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(ARCTheme.surface).cornerRadius(ARCTheme.cornerRadius)
        .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(cue.isRunning ? ARCTheme.liveRed : ARCTheme.line, lineWidth: cue.isRunning ? 2 : 1))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var shadeColor: Color {
        switch cue.shade {
        case .idle: ARCTheme.textSecondary
        case .normal: ARCTheme.textPrimary
        case .warning: ARCTheme.warn
        case .danger, .over: ARCTheme.liveRed
        }
    }

    private func control(_ title: String, tint: Color = ARCTheme.appGrey, enabled: Bool = true, wide: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .heavy, design: .monospaced))
                .foregroundStyle(tint == ARCTheme.appGrey ? ARCTheme.textPrimary : .white)
                .frame(minWidth: wide ? 96 : 64).padding(.vertical, 12)
                .background(tint).cornerRadius(ARCTheme.cornerRadius)
                .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(ARCTheme.line, lineWidth: 1))
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain).disabled(!enabled)
    }

    private func cueList(_ r: Rundown) -> some View {
        List {   // no List selection: its accent highlight diverged from the cue timer's NOW row (review, 2026-09-19)
            ForEach(Array(r.cues.enumerated()), id: \.element.id) { i, row in
                // Selecting is the BADGE column's click (review, 2026-09-19): a tap on the whole row fired from a
                // click into a text field, and select() stops and resets a running countdown mid-talk.
                CueRow(index: i + 1, cue: row, isNow: cue.selectedID == row.id, isRunning: cue.selectedID == row.id && cue.isRunning,
                       select: { cue.select(row.id) }) { store.update($0) } remove: { store.remove(id: row.id) }
                    .listRowBackground(cue.selectedID == row.id ? ARCTheme.surfaceLight : ARCTheme.surface)
                    .listRowSeparatorTint(ARCTheme.line)
            }
            .onMove { store.move(from: $0, to: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ARCTheme.surface)
        .cornerRadius(ARCTheme.cornerRadius)
    }

    private func footer(_ r: Rundown) -> some View {
        HStack {
            Text("\(r.cues.count) CUE\(r.cues.count == 1 ? "" : "S")").font(ARCTheme.moduleTitle).foregroundStyle(ARCTheme.textSecondary)
            if store.canUndoRemove {
                chip("UNDO REMOVE", tint: ARCTheme.warn) { store.undoRemove() }
                    .help("Put the last removed cue back where it was")
            }
            Spacer()
            Text("TOTAL \(Rundown.clock(r.totalSeconds))").font(ARCTheme.statusBadge).foregroundStyle(ARCTheme.textPrimary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func empty(_ title: String, detail: String, @ViewBuilder actions: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Text(title).font(ARCTheme.statusBadge).foregroundStyle(ARCTheme.textPrimary)
            Text(detail).font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.textSecondary).multilineTextAlignment(.center)
            actions()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func mark(_ title: String, help: String) -> some View {
        Text(title).font(ARCTheme.moduleTitle).foregroundStyle(.black)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(ARCTheme.warn).cornerRadius(ARCTheme.cornerRadius)
            .fixedSize().help(help)
    }

    private func chip(_ title: String, tint: Color = ARCTheme.line, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(ARCTheme.statusBadge).foregroundStyle(tint == ARCTheme.line ? ARCTheme.textPrimary : .white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(tint == ARCTheme.line ? ARCTheme.appGrey : tint)
                .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(ARCTheme.line, lineWidth: 1))
                .cornerRadius(ARCTheme.cornerRadius)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    // MARK: - Actions

    private func addCue() {
        let n = (store.rundown?.cues.count ?? 0) + 1
        var c = RundownCue(title: "Cue \(n)")
        c.format = .other
        store.add(c)
    }

    private func importROS() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.message = "A run of show JSON: what the old stage timer exported, or an intake export"
        if panel.runModal() == .OK, let url = panel.url { store.importROS(from: url) }
    }

    private func exportROS() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(store.rundown?.name ?? "Rundown").json"
        if panel.runModal() == .OK, let url = panel.url { store.exportROS(to: url) }
    }
}

/// One cue, edited in place. Text lands in the store on commit (Return or
/// focus out), not per keystroke, so a half-typed title never hits the disk.
private struct CueRow: View {
    let index: Int
    let cue: RundownCue
    var isNow = false
    var isRunning = false
    let select: () -> Void
    let commit: (RundownCue) -> Void
    let remove: () -> Void
    /// Any field in the row: leaving it commits, as Return does (review, 2026-09-19: clicking away lost the edit).
    @FocusState private var focused: Bool

    @State private var title: String = ""
    @State private var speakers: String = ""
    @State private var duration: String = ""
    @State private var warning: String = ""
    @State private var danger: String = ""
    @State private var format: RundownCue.Format = .other

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isNow {
                    Text(isRunning ? "LIVE" : "NOW").font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2).background(isRunning ? ARCTheme.liveRed : ARCTheme.textSecondary).cornerRadius(3).frame(width: 34)
                } else {
                    Text(String(format: "%02d", index)).font(ARCTheme.mono(13)).foregroundStyle(ARCTheme.textSecondary).frame(width: 34)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .help(isNow ? "This is the selected cue" : "Click to select this cue (stops a running countdown)")
            VStack(alignment: .leading, spacing: 2) {
                if let session = cue.subtitle, !session.isEmpty {
                    // The block this talk sits in (Session 1. Opening Talks): context, not a field.
                    Text(session.uppercased()).font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1)
                }
                TextField("", text: $title, prompt: Text("title").foregroundStyle(ARCTheme.textSecondary.opacity(0.5)), axis: .horizontal)
                    .focused($focused)
                    .onSubmit(push)
                    .textFieldStyle(.plain).font(ARCTheme.mono(14)).foregroundStyle(ARCTheme.textPrimary)
                TextField("", text: $speakers, prompt: Text("no presenter").foregroundStyle(ARCTheme.textSecondary.opacity(0.35)), axis: .horizontal)
                    .focused($focused)
                    .onSubmit(push)
                    .textFieldStyle(.plain).font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.arcRed)
            }
            Picker("", selection: $format) {
                ForEach(RundownCue.Format.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 120).onChange(of: format) { push() }
            field("LEN", $duration, width: 64)
            field("WARN", $warning, width: 52)
            field("DANGER", $danger, width: 52)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(ARCTheme.textSecondary)
            }
            .buttonStyle(.plain).help("Remove this cue")
        }
        .padding(.vertical, 4)
        .onAppear(perform: pull)
        .onChange(of: cue) { pull() }
        .onChange(of: focused) { if !focused { push() } }
    }

    private func field(_ label: String, _ text: Binding<String>, width: CGFloat) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(ARCTheme.textSecondary)
            TextField("", text: text)
                .focused($focused)
                .onSubmit(push)
                .textFieldStyle(.plain).font(ARCTheme.mono(13)).foregroundStyle(ARCTheme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .frame(width: width)
    }

    private func pull() {
        title = cue.title
        speakers = cue.speakers ?? ""
        duration = cue.durationClock
        warning = Rundown.clock(cue.warningSeconds)
        danger = Rundown.clock(cue.dangerSeconds)
        format = cue.format
    }

    private func push() {
        var c = cue
        c.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? cue.title : title
        c.speakers = speakers.isEmpty ? nil : speakers
        c.format = format
        if let s = Self.seconds(duration) { c.durationSeconds = s }
        if let w = Self.seconds(warning, bareIsSeconds: true) { c.warningSeconds = w }
        if let d = Self.seconds(danger, bareIsSeconds: true) { c.dangerSeconds = d }
        c.clampThresholds()
        if c != cue { commit(c) }
        pull()
    }

    /// "12", "12:30", "1:02:30". A bare number is minutes for a length and
    /// seconds for a threshold, which is how each is read on the row.
    static func seconds(_ text: String, bareIsSeconds: Bool = false) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let p = parts.map { $0! }
        switch p.count {
        case 1: return bareIsSeconds ? p[0] : p[0] * 60
        case 2: return p[0] * 60 + p[1]
        case 3: return p[0] * 3600 + p[1] * 60 + p[2]
        default: return nil
        }
    }
}
