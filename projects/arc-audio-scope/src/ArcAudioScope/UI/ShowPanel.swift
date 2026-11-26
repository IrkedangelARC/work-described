//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import ARCStyle
import ScopeKit
import SwiftUI

/// The show: which one is open, starting or opening another, its notes, the export and the
/// event log. Drawn over the screen in the window (not a sheet), so it works the same on the
/// iPad and shows in a screen capture.
struct ShowPanel: View {
    @EnvironmentObject private var model: MeterModel
    @State private var name = ""
    @State private var problem = ""
    @State private var notes = ""
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm:ss"
        return f
    }()

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea().onTapGesture { model.showPanelOpen = false }
            VStack(spacing: ARCTheme.paddingSmall) {
                shows
                notesModule
                exportModule
                ARCBank([ARCBankItem("DONE") { model.showPanelOpen = false }]).frame(width: 140)
            }
            .frame(width: 640)
            .padding(ARCTheme.paddingMedium)
            .background(ARCTheme.background, in: RoundedRectangle(cornerRadius: ARCTheme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).stroke(ARCTheme.line, lineWidth: 1))
        }
        .onAppear { notes = model.show.notes }
        .onChange(of: notes) { _, text in model.setNotes(text) }
        .onChange(of: model.showName) { _, _ in notes = model.show.notes }
    }

    private var shows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: ARCTheme.paddingSmall) {
                TextField("Name for a new show", text: $name).textFieldStyle(.roundedBorder)
                ARCBank([ARCBankItem("NEW") { problem = model.newShow(named: name) ?? ""; if problem.isEmpty { name = "" } },
                         ARCBankItem("SAVE AS") { problem = model.saveShowAs(name) ?? ""; if problem.isEmpty { name = "" } }])
                    .frame(width: 200)
            }
            if !problem.isEmpty { Text(problem).font(ARCTheme.mono(13)).foregroundStyle(ARCTheme.warn) }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.showNames, id: \.self) { show in
                        HStack {
                            Text(show).font(ARCTheme.mono(13, show == model.showName ? .bold : .regular))
                                .foregroundStyle(show == model.showName ? ARCTheme.text0 : ARCTheme.text1).lineLimit(1)
                            Spacer()
                            if show == model.showName {
                                Text("OPEN NOW").font(ARCTheme.mono(11)).foregroundStyle(ARCTheme.live)
                            } else {
                                ARCBank([ARCBankItem("OPEN") { problem = model.openShow(show) ?? "" }]).frame(width: 80)
                            }
                        }
                        .frame(minHeight: 26)
                    }
                }
            }
            .frame(maxHeight: 112)
            ARCModuleCaption("NEW starts a clean show on this rig. The interface, calibration, mic file and screen settings carry over. The logs and captured traces do not. SAVE AS copies this show, logs and all.")
        }
        .arcModule(title: "SHOW  \(model.showName)", tint: ARCTheme.secBlue)
    }

    private var notesModule: some View {
        TextEditor(text: $notes)
            .font(ARCTheme.mono(13, .regular)).foregroundStyle(ARCTheme.text0)
            .scrollContentBackground(.hidden)
            .frame(height: 70)
            .arcModule(title: "NOTES", tint: ARCTheme.secBlue)
    }

    private var exportModule: some View {
        let s = model.show
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(s.ringLog.count) rings   \(s.traces.count) RTA traces   \(s.transferTraces.count) transfer traces   \(s.events.count) events")
                    .font(ARCTheme.mono(12)).foregroundStyle(ARCTheme.text0).lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
                ARCBank([ARCBankItem("EXPORT") { model.export(reveal: true) }], tint: ARCTheme.secOrange).frame(width: 110)
            }
            if !model.exportMessage.isEmpty {
                Text(model.exportMessage).font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.text1).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(s.events.suffix(4).reversed().enumerated()), id: \.offset) { _, e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.clock.string(from: e.date)).foregroundStyle(ARCTheme.text1).fixedSize()
                    Text(e.detail.isEmpty ? e.kind.rawValue : e.detail).foregroundStyle(e.kind == .inputClip ? ARCTheme.arcRed : ARCTheme.warn).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(ARCTheme.mono(11, .regular))
            }
            ARCModuleCaption("EXPORT writes the bars and traces, the ring-out log, the events and the transfer function as CSV, the notes as text and the screen as PNG and PDF.")
        }
        .arcModule(title: "EXPORT AND EVENTS", tint: ARCTheme.secOrange)
    }
}
