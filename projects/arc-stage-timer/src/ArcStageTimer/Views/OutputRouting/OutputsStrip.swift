//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

#if os(macOS)
import AppKit

/// Opens the OUTPUTS panel from anywhere (header strip, the run view's OUTPUTS module, a chip's popover).
@MainActor
@Observable
final class OutputsPanelController {
    static let shared = OutputsPanelController()
    var isOpen = false

    /// An assignment waiting for the operator's OK: it would put two outputs on one display.
    struct PendingAssign: Identifiable, Equatable {
        let window: StageWindow
        let display: DisplayInfo
        let other: StageWindow
        var id: String { window.rawValue + display.id }
    }
    var pending: PendingAssign?

    /// Every assignment made from a chip or the panel comes here. One that would share a display with the
    /// other output is confirmed first (Share anyway / Cancel), because only one can be seen (2026-09-24).
    func request(_ window: StageWindow, to display: DisplayInfo) {
        let placement = ArcStageTimerApp.sharedPlacement
        if let other = placement.book.conflict(assigning: window, to: display, among: placement.connected) {
            pending = PendingAssign(window: window, display: display, other: other)
        } else {
            placement.assign(window, to: display)
        }
    }

    func confirmPending() {
        if let p = pending { ArcStageTimerApp.sharedPlacement.assign(p.window, to: p.display) }
        pending = nil
    }
}

extension View {
    /// The "two outputs on one display" confirmation, on whichever surface is in front (console or panel).
    func outputConflictAlert(when active: Bool) -> some View {
        let panel = OutputsPanelController.shared
        return alert(
            panel.pending.map { "\($0.other.outputLabel) is already on \($0.display.name)" } ?? "",
            isPresented: Binding(get: { active && panel.pending != nil }, set: { if !$0 { panel.pending = nil } }),
            presenting: panel.pending
        ) { _ in
            Button("Share anyway") { panel.confirmPending() }
            Button("Cancel", role: .cancel) { panel.pending = nil }
        } message: { p in
            Text("Only one output can be seen on a display. GO LIVE puts up the CONFIDENCE MONITOR and leaves the KEY OVERLAY off. Put \(p.window.outputLabel) on \(p.display.name) anyway?")
        }
    }
}

/// GO LIVE and OFF AIR, with the app's own state (the confidence layout switch, the run view's ON AIR flags)
/// kept in step. One place, used by the header button, the Show menu (Cmd-Shift-L) and POST /api/golive.
@MainActor
enum GoLive {
    /// `on`: true = up, false = off, nil = toggle (OFF AIR when both are live, else bring up what is missing).
    static func perform(_ on: Bool?, open openWindow: OpenWindowAction) {
        let placement = ArcStageTimerApp.sharedPlacement
        let wantOn = on ?? (placement.goLiveButton != .live)
        if wantOn {
            guard placement.hasOutputDisplay else {
                StageLog.log("GO LIVE: no display besides the console's; nothing opened")
                return
            }
            placement.goLive { w in
                if w == .confidence {
                    // The confidence window renders its confidence layout only when enabled (StageDisplayView).
                    ArcStageTimerApp.sharedConfidenceState.config.isEnabled = true
                    ArcStageTimerApp.sharedDisplayManager.isConfidenceActive = true
                } else {
                    ArcStageTimerApp.sharedDisplayManager.isConnected = true
                }
                openWindow.output(w.sceneID)
            }
        } else {
            placement.takeOffAir()
            ArcStageTimerApp.sharedConfidenceState.config.isEnabled = false
            ArcStageTimerApp.sharedDisplayManager.isConnected = false
            ArcStageTimerApp.sharedDisplayManager.isConfidenceActive = false
        }
    }
}

/// The header's one red button: GO LIVE (STAGE and CONFIDENCE up on their displays), OFF AIR while live.
struct GoLiveButton: View {
    /// The strip's once-a-second tick: window state is AppKit's, not observable, so a new tick re-reads it.
    let tick: Date
    @Environment(\.openWindow) private var openWindow
    @State private var placement = ArcStageTimerApp.sharedPlacement

    var body: some View {
        let state = placement.goLiveButton
        Button { GoLive.perform(nil, open: openWindow) } label: {
            ZStack {
                // The widest face, hidden, so the strip never moves when the state changes.
                face(.partial(1, 2)).hidden()
                face(.live).hidden()
                face(state)
            }
        }
        .buttonStyle(.plain)
        .disabled(state == .noOutputDisplay)
        .help(tip(state))
    }

    @ViewBuilder
    private func face(_ state: GoLiveButtonState) -> some View {
        let enabled = state != .noOutputDisplay
        HStack(spacing: 6) {
            if state == .live {
                Text("ON AIR").font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.arcRed)
                    .padding(.horizontal, 5).padding(.vertical, 2).background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                Text("TAKE OFF").font(ARCTheme.mono(13, .heavy))
            } else {
                Text("GO LIVE").font(ARCTheme.mono(13, .heavy))
                if case .partial(let n, let m) = state {
                    Text("\(n)/\(m) LIVE").font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.arcRed)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
        }
        .foregroundStyle(enabled ? .white : ARCTheme.text2)
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 14).padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(enabled ? ARCTheme.arcRed : ARCTheme.appGrey)
        // Live: a white rule inside the red, the "tally" (the only red-filled button, now lit).
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(state == .live ? Color.white : (enabled ? ARCTheme.arcRed : ARCTheme.line), lineWidth: state == .live ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func tip(_ state: GoLiveButtonState) -> String {
        switch state {
        case .off: "GO LIVE: the CONFIDENCE MONITOR full screen on its display, and the KEY OVERLAY on its own when it has one (Cmd-Shift-L). A CONFIDENCE MONITOR with no display gets the first free one that is not the console's."
        case .partial: "Not every output is up: GO LIVE brings the rest up (Cmd-Shift-L)"
        case .live: "OFF AIR: close the CONFIDENCE MONITOR and the KEY OVERLAY (Cmd-Shift-L). Assignments are kept."
        case .noOutputDisplay: "No display besides the console's: connect one for the CONFIDENCE MONITOR. Nothing opens over the console."
        }
    }
}

/// The app header, on EVERY screen of the console (show list, editor, run view): the ARC mark and name on the
/// left, the OUTPUTS strip on the right (2026-09-24: choosing and assigning the
/// output monitor has to be very clear). Presenter 5.5's header OUTPUTS chips, in Stage Timer's words.
struct AppHeaderBar: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "V\(v) (\(b))"
    }

    var body: some View {
        // Widest first; each step gives up the least useful thing (2026-09-25, checked at 960 to 2048 pt): the
        // name and version, then chip width (display names shorten in the middle, IDENTIFY becomes a glyph),
        // then the chips stack in two rows.
        ViewThatFits(in: .horizontal) {
            row(title: true, grid: false, compact: false)
            row(title: false, grid: false, compact: false)
            row(title: false, grid: false, compact: true)
            row(title: false, grid: true, compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(ARCTheme.ink)
        .overlay(alignment: .bottom) { Rectangle().fill(ARCTheme.line).frame(height: 1) }
    }

    private func row(title: Bool, grid: Bool, compact: Bool) -> some View {
        HStack(spacing: 12) {
            mark
            if title {
                Text("ARC STAGE TIMER")
                    .font(ARCTheme.mono(17, .heavy))
                    .tracking(2)
                    .foregroundStyle(ARCTheme.text0)
                    .lineLimit(1).fixedSize()
                Text(version)
                    .font(ARCTheme.mono(11, .bold))
                    .foregroundStyle(ARCTheme.text1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(ARCTheme.line, lineWidth: 1))
                    .fixedSize()
            }
            Spacer(minLength: 12)
            OutputsStrip(grid: grid, compact: compact)
        }
    }

    private var mark: some View {
        Image("ARCLogo")
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 30)
            .foregroundStyle(ARCTheme.arcRed)
    }
}

/// The OUTPUTS strip: one chip per output, each naming its state and its display, one click to change it.
/// A chip never collapses to a dot: it has a floor width and its display name truncates in the MIDDLE.
struct OutputsStrip: View {
    var grid: Bool = false
    /// Narrow console: chips cap at a shorter width (names lose their middle) and IDENTIFY is a glyph.
    var compact: Bool = false
    @Environment(OutputRoutingManager.self) private var routing
    @Environment(DeckLinkOutputManager.self) private var deckLink
    @State private var placement = ArcStageTimerApp.sharedPlacement
    @State private var panel = OutputsPanelController.shared

    var body: some View {
        // Window state (is an output up, on which display) is AppKit's, not observable: re-read it every second.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 6) {
                Text("OUTPUTS")
                    .font(ARCTheme.mono(11, .heavy))
                    .tracking(1.4)
                    .foregroundStyle(ARCTheme.ink)
                    .padding(.horizontal, 8)
                    .frame(maxHeight: .infinity)
                    .background(ARCTheme.secCrimson)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
                GoLiveButton(tick: ctx.date)
                if !placement.hasOutputDisplay {
                    Text("NO OUTPUT DISPLAY")
                        .font(ARCTheme.mono(11, .heavy))
                        .foregroundStyle(ARCTheme.warn)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.warn, lineWidth: 1.5))
                        .help("Only the console's display is connected. The CONFIDENCE MONITOR and KEY OVERLAY need another display; GO LIVE opens nothing over the console.")
                }
                if grid {
                    // Two rows, left-aligned, room outputs on top and the console under them: the old 2x2 grid
                    // left gaps where the KEY OVERLAY and SDI chips were off, so the two chips sat diagonally.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            OutputChip(window: .stage, tick: ctx.date, maxW: chipMax)
                            if placement.keyOverlayEnabled { OutputChip(window: .confidence, tick: ctx.date, maxW: chipMax) }
                        }
                        HStack(spacing: 6) {
                            if showSDI { SDIChip() }
                            OutputChip(window: .control, tick: ctx.date, maxW: chipMax)
                        }
                    }
                } else {
                    OutputChip(window: .stage, tick: ctx.date, maxW: chipMax)
                    // The KEY OVERLAY is a Settings option (off by default): no chip while it is off.
                    if placement.keyOverlayEnabled { OutputChip(window: .confidence, tick: ctx.date, maxW: chipMax) }
                    if showSDI { SDIChip() }
                    OutputChip(window: .control, tick: ctx.date, maxW: chipMax)
                }
                Group {
                    if compact {
                        StripButton(title: "", icon: "viewfinder", on: routing.identifying) { toggleIdentify() }
                    } else {
                        StripButton(title: "IDENTIFY", on: routing.identifying) { toggleIdentify() }
                    }
                }
                .help("IDENTIFY: put a big number, name and resolution on every physical screen for four seconds (click one to clear)")
                ARCExpandButton(tip: "OUTPUTS panel: the display map, drag outputs onto displays, test cards, SDI", on: panel.isOpen) {
                    panel.isOpen = true
                }
                .fixedSize()
            }
            .fixedSize(horizontal: true, vertical: true)
        }
    }

    private var showSDI: Bool { deckLink.isDriverInstalled || !deckLink.devices.isEmpty }
    private var chipMax: CGFloat { compact ? 236 : OutputChip.maxW }

    private func toggleIdentify() {
        if routing.identifying { routing.dismissCards() } else { routing.identifyAll(placement) }
    }
}

// MARK: - One output's chip

/// How an output's chip reads. Pure, so every state is named in one place.
struct ChipLook {
    let text: String
    let dot: Color
    let border: Color
    let textColor: Color
    let tip: String
}

struct OutputChip: View {
    let window: StageWindow
    /// See GoLiveButton.tick.
    var tick: Date = .now
    /// The widest the chip may grow; a narrow console passes less and the display name loses its middle.
    var maxW: CGFloat = OutputChip.maxW
    @State private var placement = ArcStageTimerApp.sharedPlacement
    @State private var showing = false

    static var minW: CGFloat { (ARCTheme.legible(12) * 0.62 * 17).rounded() + 30 }
    static let maxW: CGFloat = 300

    var body: some View {
        let look = self.look
        Button { showing.toggle() } label: {
            HStack(spacing: 7) {
                Circle().fill(look.dot).frame(width: 9, height: 9)
                // "MONITOR →" never truncates; only the display name after the arrow loses its middle, so a
                // narrow header reads "MONITOR → Dis…(2)", not "MONIT…lay (2)" (2026-09-25).
                let parts = look.text.components(separatedBy: " → ")
                if parts.count == 2 {
                    Text(parts[0] + " →")
                        .font(ARCTheme.mono(12, .bold))
                        .foregroundStyle(look.textColor)
                        .lineLimit(1).fixedSize()
                    Text(parts[1])
                        .font(ARCTheme.mono(12, .bold))
                        .foregroundStyle(look.textColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(look.text)
                        .font(ARCTheme.mono(12, .bold))
                        .foregroundStyle(look.textColor)
                        .lineLimit(1)
                        // UNPLUGGED must survive the squeeze; a display name loses its middle instead.
                        .truncationMode(look.dot == ARCTheme.arcRed ? .tail : .middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .heavy)).foregroundStyle(ARCTheme.text1)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(minWidth: min(Self.minW, maxW), maxWidth: maxW, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .background(ARCTheme.appGrey)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(look.border, lineWidth: look.border == ARCTheme.line ? 1 : 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(look.tip)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            DisplayPickerPopover(window: window) { showing = false }
        }
    }

    private var look: ChipLook {
        let label = window.chipLabel
        let warned = placement.warnings.contains { w in
            switch w {
            case .onControlDisplay(let o, _), .onBuiltIn(let o, _): o == window
            case .shared(_, let os): os.contains(window)
            case .unplugged: false
            }
        }
        if window == .control {
            let id = placement.controlDisplayID()
            let d = placement.connected.first { $0.id == id }
            return ChipLook(text: "CONTROL → \(d?.name ?? "?")", dot: ARCTheme.secOrange,
                            border: ARCTheme.line, textColor: ARCTheme.text0,
                            tip: "The console is on \(d?.name ?? "this display"). Click to move it to another display.")
        }
        switch placement.state(window) {
        case .notSet where window == .confidence:
            // The KEY OVERLAY is optional: it feeds an ATEM, so NOT SET is a neutral state, not a warning.
            return ChipLook(text: "\(label) NOT SET", dot: ARCTheme.text2, border: ARCTheme.line, textColor: ARCTheme.text1,
                            tip: "KEY OVERLAY: assign it to the display that feeds your ATEM.")
        case .notSet:
            return ChipLook(text: "\(label) NOT SET", dot: ARCTheme.warn, border: ARCTheme.warn, textColor: ARCTheme.warn,
                            tip: "\(window.outputLabel) has no display. Click to choose one.")
        case .unplugged(let s):
            return ChipLook(text: "\(label) UNPLUGGED \(s.name)", dot: ARCTheme.arcRed, border: ARCTheme.arcRed, textColor: ARCTheme.text0,
                            tip: "\(window.outputLabel)'s display \(s.name) is not connected. The assignment is kept and restores when it returns.")
        case .onDisplay(let d) where window == .confidence && placement.state(.stage).display?.id == d.id:
            // The KEY OVERLAY on the CONFIDENCE MONITOR's display: GO LIVE leaves it off. Amber, not an error.
            return ChipLook(text: "\(label) → \(d.name)", dot: ARCTheme.warn, border: ARCTheme.warn, textColor: ARCTheme.warn,
                            tip: "KEY OVERLAY shares \(d.name) with the CONFIDENCE MONITOR: assign it to the display that feeds your ATEM. GO LIVE leaves it off.")
        case .onDisplay(let d):
            let live = placement.isLive(window)
            return ChipLook(text: "\(label) → \(d.name)", dot: live ? ARCTheme.live : ARCTheme.text1,
                            border: warned ? ARCTheme.warn : (live ? ARCTheme.live : ARCTheme.line), textColor: ARCTheme.text0,
                            tip: "\(window.outputLabel) → display \(d.index), \(d.name), \(d.resolution). " + (live ? "ON AIR." : "Assigned, not open.") + " Click to change.")
        }
    }
}

/// The chip's dropdown: every connected display by number, name and resolution, plus NOT SET, and TEST/OPEN.
struct DisplayPickerPopover: View {
    let window: StageWindow
    let done: () -> Void
    @Environment(OutputRoutingManager.self) private var routing
    @Environment(\.openWindow) private var openWindow
    @State private var placement = ArcStageTimerApp.sharedPlacement

    var body: some View {
        let state = placement.state(window)
        let control = placement.controlDisplayID()
        VStack(alignment: .leading, spacing: 4) {
            ForEach(placement.connected) { d in
                let selected = window == .control ? d.id == control : state.display?.id == d.id
                let others = StageWindow.roomOutputs.filter { $0 != window && placement.state($0).display?.id == d.id }.map(\.outputLabel)
                    + (window != .control && d.id == control ? ["CONTROL"] : [])
                DisplayRow(display: d, selected: selected, tint: window == .control ? ARCTheme.secOrange : ARCTheme.secCrimson, alsoOn: others) {
                    done()
                    OutputsPanelController.shared.request(window, to: d)
                }
            }
            if case .unplugged(let s) = state {
                HStack(spacing: 8) {
                    Text("UNPLUGGED").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.ink)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(ARCTheme.arcRed)
                    Text("\(s.name)  \(s.resolution)").font(ARCTheme.mono(12, .bold)).foregroundStyle(ARCTheme.text0)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.arcRed, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
            }
            if window != .control {
                PopoverRowButton(title: "NOT SET", selected: state == .notSet) { placement.assign(window, to: nil); done() }
                Rectangle().fill(ARCTheme.line).frame(height: 1).padding(.vertical, 2)
                HStack(spacing: 6) {
                    StripButton(title: "TEST", on: false, enabled: state.display != nil) { routing.testCard(window, placement) }
                        .help("A test card on \(window.outputLabel)'s display for four seconds")
                    if placement.isOpen(window) {
                        StripButton(title: "TAKE OFF", on: false) { placement.close(window) }
                            .help("Close the \(window.outputLabel) output window")
                    } else {
                        StripButton(title: "OPEN", on: false, enabled: state.display != nil) {
                            openWindow.output(window.sceneID)
                            placement.placeWhenOpen(window)
                            done()
                        }
                        .help("Open \(window.outputLabel) on its display now")
                    }
                    Spacer(minLength: 8)
                    StripButton(title: "PANEL", on: false) { done(); OutputsPanelController.shared.isOpen = true }
                }
            }
            ForEach(placement.warnings.filter { $0.concerns(window) }) { w in
                WarningLine(text: w.text)
            }
        }
        .padding(10)
        .frame(width: 380)
        .arcModule(title: window == .control ? "Control display" : window.outputLabel, tint: window == .control ? ARCTheme.secOrange : ARCTheme.secCrimson)
        .padding(6)
        .background(ARCTheme.appGrey)
    }
}

extension AssignmentWarning {
    func concerns(_ window: StageWindow) -> Bool {
        switch self {
        case .onControlDisplay(let w, _), .onBuiltIn(let w, _), .unplugged(let w, _): w == window
        case .shared(_, let ws): ws.contains(window)
        }
    }
}

/// One display in a picker: number box, name, resolution, tags, what else is on it.
struct DisplayRow: View {
    let display: DisplayInfo
    let selected: Bool
    var tint: Color = ARCTheme.secCrimson
    var alsoOn: [String] = []
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("\(display.index)")
                    .font(ARCTheme.mono(16, .heavy))
                    .foregroundStyle(selected ? tint : ARCTheme.ink)
                    .frame(width: 28, height: 28)
                    .background(selected ? ARCTheme.ink : ARCTheme.text1)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                VStack(alignment: .leading, spacing: 1) {
                    Text(display.name).font(ARCTheme.mono(13, .bold)).lineLimit(1).truncationMode(.middle)
                    Text(display.resolution + (display.isPrimary ? "  PRIMARY" : "") + (display.isBuiltIn ? "  BUILT-IN" : ""))
                        .font(ARCTheme.mono(11, .regular)).opacity(0.8).lineLimit(1)
                }
                Spacer(minLength: 4)
                ForEach(alsoOn, id: \.self) { o in
                    Text(o).font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.text0)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(ARCTheme.text1, lineWidth: 1))
                        .fixedSize()
                }
                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)) }
            }
            .foregroundStyle(selected ? ARCTheme.ink : ARCTheme.text0)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? tint : ARCTheme.surfaceLight)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? tint : ARCTheme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PopoverRowButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(ARCTheme.mono(12, .heavy))
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)) }
            }
            .foregroundStyle(selected ? ARCTheme.ink : ARCTheme.text0)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(selected ? ARCTheme.warn : ARCTheme.surfaceLight)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? ARCTheme.warn : ARCTheme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A small header/popover button: mono heavy, raised grey, filled blue when on.
struct StripButton: View {
    let title: String
    /// A glyph in place of the word, for the narrow header.
    var icon: String? = nil
    var on: Bool = false
    var enabled: Bool = true
    var tint: Color = ARCTheme.secBlue
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Group {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .heavy)) }
                else { Text(title) }
            }
                .font(ARCTheme.mono(11, .heavy))
                .foregroundStyle(on ? ARCTheme.ink : (enabled ? ARCTheme.text0 : ARCTheme.text2))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(on ? tint : ARCTheme.appGrey)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? tint : ARCTheme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// An amber warning, in plain words.
struct WarningLine: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(ARCTheme.warn)
            Text(text).font(ARCTheme.mono(12, .bold)).foregroundStyle(ARCTheme.text0)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ARCTheme.warn.opacity(0.12))
        .overlay(alignment: .leading) { Rectangle().fill(ARCTheme.warn).frame(width: 3) }
    }
}

// MARK: - SDI (DeckLink fill+key)

struct SDIChip: View {
    @Environment(DeckLinkOutputManager.self) private var deckLink
    @State private var showing = false

    var body: some View {
        let running = deckLink.isRunning
        let text = running ? "SDI → \(deckLink.selectedDeviceName)" : (deckLink.isStarting ? "SDI STARTING" : "SDI OFF")
        Button { showing.toggle() } label: {
            HStack(spacing: 7) {
                Circle().fill(running ? ARCTheme.live : (deckLink.lastError != nil ? ARCTheme.arcRed : ARCTheme.text2)).frame(width: 9, height: 9)
                Text(text).font(ARCTheme.mono(12, .bold)).foregroundStyle(ARCTheme.text0).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .heavy)).foregroundStyle(ARCTheme.text1)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(minWidth: OutputChip.minW, maxWidth: OutputChip.maxW, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .background(ARCTheme.appGrey)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(running ? ARCTheme.live : ARCTheme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(running ? "Timer overlay going out as SDI fill+key on \(deckLink.selectedDeviceName)" : "DeckLink fill+key to the ATEM: click to set up")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            DeckLinkOutputSection()
                .padding(10)
                .frame(width: 520)
                .arcModule(title: "SDI fill + key", tint: ARCTheme.secCrimson)
                .padding(6)
                .background(ARCTheme.appGrey)
        }
    }
}
#endif
