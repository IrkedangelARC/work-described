//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// The floating control windows behind the expand glyphs (docs/PLAN_capture_gui.md): OPTIONS,
/// READINESS and LOG. Each is a `Window` scene in `ArcCaptureApp`; `ControlWindow.toggle` opens
/// and closes them from the glyph and the menu.
enum CaptureWindows {
    static let options = (id: "capture-options", title: "Capture Options")
    static let readiness = (id: "capture-readiness", title: "Capture Readiness")
    static let log = (id: "capture-log", title: "Capture Log")
}

// MARK: - OPTIONS

/// The run's options, in full, with what each one does. Leave them as they are unless told otherwise.
struct OptionsWindowView: View {
    @Bindable var session: CaptureSession
    @State private var dwellText = ""
    @State private var maxRecordText = ""

    var body: some View {
        VStack(spacing: ARCTheme.paddingSmall) {
            VStack(alignment: .leading, spacing: 10) {
                option("DWELL", unit: "s", text: $dwellText, help: "Pause after a slide settles before the next click. 0.3 is right; raise it only if PowerPoint is slow to draw.") {
                    if let v = Double(dwellText) { session.dwellTime = v }
                }
                ARCTheme.line.frame(height: 1)
                option("MAX CLIP", unit: "s", text: $maxRecordText, help: "Longest recording for an animation whose length is unknown. Movies are measured and recorded in full whatever this says.") {
                    if let v = Double(maxRecordText) { session.maxRecordingTime = v }
                }
                ARCTheme.line.frame(height: 1)
                HStack(alignment: .top, spacing: 12) {
                    Toggle(isOn: $session.keepPNGs) { Text("KEEP PNGS").font(ARCTheme.mono(12, .heavy)).foregroundStyle(ARCTheme.textPrimary) }
                        .toggleStyle(.switch).controlSize(.small).frame(width: 150, alignment: .leading)
                    Text("Also write every slide as a PNG beside the deck. Off for shows; on when someone needs the stills.")
                        .font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .arcModule(title: "OPTIONS", tint: ARCTheme.secOrange)
            Text("Leave these as they are unless told otherwise. They apply to the next capture.")
                .font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .arcModule(tint: ARCTheme.line)
        }
        .padding(ARCTheme.paddingMedium)
        .frame(width: 560)
        .background(ARCTheme.background)
        .onAppear { dwellText = String(session.dwellTime); maxRecordText = String(Int(session.maxRecordingTime)) }
    }

    private func option(_ label: String, unit: String, text: Binding<String>, help: String, commit: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 6) {
                Text(label).font(ARCTheme.mono(12, .heavy)).foregroundStyle(ARCTheme.textPrimary)
                TextField("", text: text).textFieldStyle(.roundedBorder).focusEffectDisabled()
                    .font(ARCTheme.mono(12, .regular)).frame(width: 58).onSubmit(commit)
                Text(unit).font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary)
            }
            .frame(width: 150, alignment: .leading)
            Text(help).font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - READINESS

/// Every check with its hint and the button that fixes it, the story behind the STATUS tiles.
struct ReadinessWindowView: View {
    @Bindable var readiness: Readiness

    var body: some View {
        VStack(spacing: ARCTheme.paddingSmall) {
            ReadinessView(readiness: readiness)
                .arcModule(title: "READY?", tint: readiness.allRequiredOK ? ARCTheme.secGreen : ARCTheme.liveRed,
                           badge: ARCBandBadge(text: readiness.allRequiredOK ? "ALL REQUIRED OK" : "SOMETHING TO FIX", fill: readiness.allRequiredOK ? ARCTheme.readyGreen : ARCTheme.liveRed))
            Text("Checked every 5 s. Screen recording, accessibility, control of System Events and each installed presentation app, and a second display are required; all of them are asked for when the app opens; the apps only for the decks they open.")
                .font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .arcModule(tint: ARCTheme.line)
        }
        .padding(ARCTheme.paddingMedium)
        .frame(width: 720)
        .background(ARCTheme.background)
    }
}

// MARK: - LOG

/// The capture log in its own window: every line, not the last 200.
struct LogWindowView: View {
    @State private var monitor = CaptureMonitor.shared
    @State private var filter = ""

    var body: some View {
        VStack(spacing: ARCTheme.paddingSmall) {
            HStack(spacing: 6) {
                Text("FILTER").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.textSecondary)
                TextField("tag or words", text: $filter).textFieldStyle(.roundedBorder).focusEffectDisabled().font(ARCTheme.mono(12, .regular))
                ARCChip("COPY ALL", tint: ARCTheme.secBlue) {
                    let text = monitor.lines.map { "\(Self.time.string(from: $0.time)) [\($0.tag)] \($0.message)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                }
                ARCChip("OPEN FILE", tint: ARCTheme.secBlue) { NSWorkspace.shared.open(DebugLog.core.url) }
            }
            CaptureLogList(lines: monitor.lines, filter: filter, limit: nil)
                .arcModule(title: "LOG", tint: ARCTheme.line, badge: ARCBandBadge(text: "\(monitor.lines.count)", fill: ARCTheme.text0))
        }
        .padding(ARCTheme.paddingMedium)
        .frame(minWidth: 820, minHeight: 480)
        .background(ARCTheme.background)
    }

    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
}

/// The log lines, coloured by tag and by what they say; shared by the monitor's LOG module and the window.
struct CaptureLogList: View {
    let lines: [CaptureMonitor.Line]
    var filter: String = ""
    var limit: Int? = 200

    var body: some View {
        let shown = (limit.map { Array(lines.suffix($0)) } ?? lines).filter { filter.isEmpty || $0.tag.localizedCaseInsensitiveContains(filter) || $0.message.localizedCaseInsensitiveContains(filter) }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(shown) { l in
                        HStack(alignment: .top, spacing: 8) {
                            Text(LogWindowView.time.string(from: l.time)).foregroundStyle(ARCTheme.textTertiary)
                            Text(l.tag).foregroundStyle(Self.tagColor(l.tag)).frame(width: 64, alignment: .leading)
                            Text(l.message).foregroundStyle(Self.lineColor(l.message))
                                .fontWeight(l.message.contains("TRANSITION captured") || l.message.contains("MOVIE clip") ? .bold : .regular)
                                .lineLimit(2)
                        }
                        .font(ARCTheme.mono(12, .regular))
                        .id(l.id)
                    }
                }
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(ARCTheme.ink).cornerRadius(3)
            .onChange(of: lines.count) { _, _ in if let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
    }

    static func lineColor(_ m: String) -> Color {
        if m.hasPrefix("STALL") || m.hasPrefix("ERROR") || m.hasPrefix("WARNING") { return ARCTheme.warn }
        if m.contains("TRANSITION captured") { return ARCTheme.arcRed }
        if m.contains("MOVIE clip") { return ARCTheme.secGreen }
        return ARCTheme.textPrimary
    }

    static func tagColor(_ tag: String) -> Color {
        switch tag {
        case "Session": ARCTheme.secOrange
        case "Frame": ARCTheme.secGreen
        case "Driver": ARCTheme.secBlue
        case "Headless", "Deck": ARCTheme.secCrimson
        default: ARCTheme.textSecondary
        }
    }
}
