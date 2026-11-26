//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import ARCStyle

// The PORTAL window (2026-09-21): the ARC Tech ACCOUNT settings, in the app, instead of hunting
// them in a browser on a show day. These are not meeting controls - they are what the account allows,
// they apply to NEW meetings only, and the one that cost two sessions (closed captioning OFF) was
// invisible from inside the meeting while every in-meeting call answered success.
//
// It reads on open and after every write, because a PATCH that succeeds may have changed nothing: an
// account or group LOCK takes the change and keeps the old value. A locked row says so.

struct PortalWindowView: View {
    @Environment(PortalStore.self) private var portal

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: ARCTheme.railPad) {
                header
                if !portal.warnings.isEmpty { warnings }
                ForEach(ZoomPortal.groups, id: \.self) { group in
                    let rows = portal.rows(in: group)
                    if !rows.isEmpty { section(group, rows) }
                }
                if portal.reading == nil, !portal.loading {
                    Text("READ to fetch the account settings. They need the SDK engine and a Zoom sign-in.")
                        .font(ARCTheme.ui(12, .regular)).foregroundStyle(ARCTheme.textSecondary)
                        .padding(ARCTheme.s(ARCTheme.modulePad))
                        .arcSubGroup()
                }
            }
            .padding(ARCTheme.railPad)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .background(ARCTheme.ink)
        .task { if portal.reading == nil { await portal.refresh() } }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: ARCTheme.s(6)) {
                arcChip(portal.loading ? "READING…" : "READ") { Task { await portal.refresh() } }
                    .disabled(portal.loading)
                Text(state)
                    .font(ARCTheme.ui(11, .regular))
                    .foregroundStyle(portal.error == nil ? ARCTheme.textSecondary : ARCTheme.liveRed)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(ARCTheme.s(ARCTheme.modulePad))
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcSubGroup("arc tech account · changes apply to NEW meetings only, not one already up")
    }

    private var state: String {
        if let error = portal.error { return error }
        guard let at = portal.readAt else { return "not read yet" }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return "read at \(f.string(from: at))  ·  \(portal.rows.filter { !$0.isAbsent }.count) settings"
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(portal.warnings, id: \.self) { line in
                Text(line)
                    .font(ARCTheme.ui(11, .regular))
                    .foregroundStyle(ARCTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(ARCTheme.s(ARCTheme.modulePad))
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcSubGroup("wrong for a live event")
    }

    // MARK: - One group

    /// A group is a grid of CELLS, each one setting with its description beside it. The columns are
    /// adaptive: two across at the window's normal width, one when it is dragged narrow, so a long
    /// description never squeezes a chip off the row.
    private func section(_ group: String, _ rows: [PortalStore.Row]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: ARCTheme.s(430)), spacing: ARCTheme.s(10), alignment: .topLeading)],
                  alignment: .leading, spacing: ARCTheme.s(10)) {
            ForEach(rows) { row in cell(row) }
        }
        .padding(ARCTheme.s(ARCTheme.modulePad))
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcSubGroup(group)
    }

    /// The control on the left in a fixed column so every description starts at the same x, and what
    /// the setting COSTS on a show on the right. The description is the point of the page: the names
    /// are Zoom's and say nothing about what turning one off does to a live event.
    private func cell(_ row: PortalStore.Row) -> some View {
        HStack(alignment: .top, spacing: ARCTheme.s(10)) {
            control(row)
                .frame(width: ARCTheme.s(200), alignment: .topLeading)
            Text(note(row))
                .font(ARCTheme.ui(10, .regular))
                .foregroundStyle(locked(row) ? ARCTheme.warn : ARCTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .help(help(row))
    }

    /// The description as the page shows it: the doc, plus the state that would otherwise only be in a
    /// tooltip (absent, licence, locked).
    private func note(_ row: PortalStore.Row) -> String {
        if row.isAbsent { return row.concern.doc + " Not in this account's document: not ARC's to set, or Zoom has renamed it again." }
        if row.concern.readOnly { return row.concern.doc + " A licence fact, not a setting." }
        if locked(row) { return row.concern.doc + " LOCKED on the account or the group: Zoom took the change and kept the old value." }
        return row.concern.doc
    }

    /// A toggle is one chip that lights when it is on. A choice is its name over one chip per value. A
    /// licence fact is a lamp, not a button: patching it would answer 204 and change nothing.
    @ViewBuilder
    private func control(_ row: PortalStore.Row) -> some View {
        let name = Self.label(row.concern.name)
        if row.isAbsent {
            arcChip("\(name) —", tint: ARCTheme.textTertiary) {}
                .disabled(true)
        } else if row.concern.readOnly {
            arcChip("\(name) \(row.isOn ? "YES" : "NO")", fill: row.isOn ? ARCTheme.secBlue : nil) {}
                .disabled(true)
        } else if let choices = row.concern.choices {
            VStack(alignment: .leading, spacing: ARCTheme.s(4)) {
                Text(name).font(ARCTheme.ui(10, .heavy)).foregroundStyle(ARCTheme.textSecondary).fixedSize()
                FlowRow(spacing: ARCTheme.s(4)) {
                    ForEach(choices, id: \.self) { choice in
                        arcChip(choice.uppercased(), fill: row.value == choice ? ARCTheme.secBlue : nil) {
                            Task { await portal.set(row.concern.name, to: choice) }
                        }
                        .disabled(portal.writing != nil)
                    }
                }
            }
        } else {
            arcChip(name, tint: locked(row) ? ARCTheme.warn : ARCTheme.text0, fill: row.isOn ? ARCTheme.secBlue : nil) {
                Task { await portal.toggle(row) }
            }
            .disabled(portal.writing != nil)
        }
    }

    private func locked(_ row: PortalStore.Row) -> Bool { portal.locked.contains(row.concern.name) }

    /// The tooltip keeps the one thing the page has no room for: where the setting actually lives.
    private func help(_ row: PortalStore.Row) -> String { row.foundPath }

    /// "cloudRecording" -> "CLOUD RECORDING". The table's names are the API's; the chips are the show's.
    /// A run of capitals is one word: splitting on every capital made captionAPI read "CAPTION A P I".
    static func label(_ name: String) -> String {
        var out = ""
        let chars = Array(name)
        for (i, ch) in chars.enumerated() {
            let previousIsLower = i > 0 && chars[i - 1].isLowercase
            let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
            if ch.isUppercase, i > 0, previousIsLower || nextIsLower { out.append(" ") }
            out.append(ch)
        }
        return out.uppercased()
    }
}
