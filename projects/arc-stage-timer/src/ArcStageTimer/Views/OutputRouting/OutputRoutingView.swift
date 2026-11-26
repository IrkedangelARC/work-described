//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

#if os(macOS)
import AppKit

/// The OUTPUTS panel: the expanded form of the header strip (2026-09-24). It replaced two sheets (OUTPUT ROUTING
/// from the show list, REROUTE OUTPUTS from the run view) whose pickers defaulted to "Not Assigned", forgot every
/// choice at quit and dropped a route when its display was unplugged.
///
///   DISPLAYS: the displays as they are ARRANGED (proportional, like System Settings > Displays), each with its
///             number, name, resolution and the outputs on it. Click one to put the ARMED output there, or drag
///             an output onto it. An unplugged display an output belongs to is a dashed ghost beside the map.
///   OUTPUTS:  one row per output: ARM, TEST (a test card on its display), OPEN / TAKE OFF, CLEAR. Then SDI.
///   CHECKS:   on the control display, on the built-in screen, two outputs sharing a display, unplugged.
struct OutputsPanel: View {
    @Environment(OutputRoutingManager.self) private var routing
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var placement = ArcStageTimerApp.sharedPlacement
    @State private var armed: StageWindow = .stage

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: ARCTheme.paddingSmall) {
                HStack(alignment: .top, spacing: ARCTheme.paddingSmall) {
                    displaysModule
                    outputsColumn.frame(width: 420)
                }
                .frame(maxHeight: .infinity)
                checksModule
                footer
            }
            .padding(ARCTheme.paddingSmall)
        }
        .frame(minWidth: 1000, idealWidth: 1120, minHeight: 640, idealHeight: 720)
        .outputConflictAlert(when: true)
        .background(ARCTheme.background)
        .onAppear { placement.refreshSnapshot() }
    }

    // MARK: DISPLAYS

    private var displaysModule: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("CLICK A DISPLAY TO PUT")
                    .font(ARCTheme.mono(11, .bold)).foregroundStyle(ARCTheme.text1)
                OutputToken(window: armed, filled: true)
                Text("ON IT, OR DRAG AN OUTPUT ONTO ONE")
                    .font(ARCTheme.mono(11, .bold)).foregroundStyle(ARCTheme.text1)
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            DisplayMap(armed: armed)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .arcModule(title: "Displays", tint: ARCTheme.secCrimson,
                   badge: ARCBandBadge(text: "\(placement.connected.count) CONNECTED", fill: ARCTheme.ink))
    }

    // MARK: OUTPUTS

    private var outputsColumn: some View {
        VStack(spacing: ARCTheme.paddingSmall) {
            VStack(spacing: 6) {
                ForEach(StageWindow.assignable, id: \.self) { w in outputRow(w) }
            }
            .arcModule(title: "Outputs", tint: ARCTheme.secCrimson)
            keyOverlayModule
            ScrollView {
                DeckLinkOutputSection()
            }
            .frame(maxHeight: .infinity)
            .arcModule(title: "SDI fill + key", tint: ARCTheme.secCrimson)
        }
    }

    private func outputRow(_ w: StageWindow) -> some View {
        let state = placement.state(w)
        let control = placement.controlDisplayID()
        let targetText: String = {
            if w == .control {
                return placement.connected.first { $0.id == control }.map { "\($0.index)  \($0.name)  \($0.resolution)" } ?? "?"
            }
            switch state {
            case .notSet: return w == .confidence ? "NOT SET  (feeds your ATEM)" : "NOT SET"
            case .unplugged(let s): return "UNPLUGGED  \(s.name)"
            case .onDisplay(let d): return "\(d.index)  \(d.name)  \(d.resolution)"
            }
        }()
        let targetColor: Color = {
            if w == .control { return ARCTheme.text0 }
            switch state {
            case .notSet: return w == .confidence ? ARCTheme.text1 : ARCTheme.warn
            case .unplugged: return ARCTheme.arcRed
            case .onDisplay: return ARCTheme.text0
            }
        }()
        let live = w != .control && placement.isLive(w)
        return VStack(alignment: .leading, spacing: 6) {
            // Name on one line, where it goes on the next: CONFIDENCE MONITOR is too long to share a line with
            // a display's name and resolution (2026-09-24 rename).
            HStack(spacing: 8) {
                OutputToken(window: w, filled: armed == w)
                    .onTapGesture { armed = w }
                Spacer(minLength: 4)
                if live {
                    Text("ON AIR").font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.ink)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(ARCTheme.live).fixedSize()
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .heavy)).foregroundStyle(ARCTheme.text1)
                Text(targetText)
                    .font(ARCTheme.mono(12, .bold)).foregroundStyle(targetColor)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                StripButton(title: armed == w ? "ARMED" : "ARM", on: armed == w, tint: ARCTheme.secCrimson) { armed = w }
                    .help("Arm \(w.outputLabel): the next display you click takes it")
                if w != .control {
                    StripButton(title: "TEST", enabled: state.display != nil) { routing.testCard(w, placement) }
                        .help("A test card on \(w.outputLabel)'s display for four seconds")
                    if placement.isOpen(w) {
                        StripButton(title: "TAKE OFF") { placement.close(w) }
                            .help("Close the \(w.outputLabel) output window")
                    } else {
                        StripButton(title: "OPEN", enabled: state.display != nil) {
                            openWindow.output(w.sceneID); placement.placeWhenOpen(w)
                        }
                        .help("Open \(w.outputLabel) on its display now")
                    }
                    StripButton(title: "CLEAR", enabled: state != .notSet) { placement.assign(w, to: nil) }
                        .help("Set \(w.outputLabel) to NOT SET (takes it off the air)")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .background(ARCTheme.subGroup)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(armed == w ? ARCTheme.secCrimson : ARCTheme.line, lineWidth: armed == w ? 1.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: ADVANCED: KEY OVERLAY

    /// The KEY OVERLAY (the ATEM overlay / PIP key layer) is off unless turned on here or in Settings (2026-09-24:
    /// nearly every show is the console and the confidence monitor).
    private var keyOverlayModule: some View {
        @Bindable var placement = placement
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $placement.keyOverlayEnabled) {
                Text("ENABLE KEY OVERLAY OUTPUT").font(ARCTheme.mono(12, .heavy)).foregroundStyle(ARCTheme.text0)
            }
            .toggleStyle(.switch)
            ARCModuleCaption(placement.keyOverlayEnabled
                             ? "The timer as a fill + key layer for an ATEM (overlay or PIP): its own chip, GO LIVE, and Run Timer > Key Overlay."
                             : "Off: CONTROL and the CONFIDENCE MONITOR only. A saved KEY OVERLAY assignment is kept for when it is turned on.")
        }
        .arcModule(title: "Advanced: Key overlay", badge: ARCBandBadge(text: placement.keyOverlayEnabled ? "ON" : "OFF", fill: ARCTheme.ink))
    }

    // MARK: CHECKS

    private var checksModule: some View {
        let warnings = placement.warnings
        return VStack(alignment: .leading, spacing: 4) {
            if warnings.isEmpty {
                Text(placement.state(.stage) == .notSet
                     ? "The CONFIDENCE MONITOR has no display yet. Arm it and click a display."
                     : "Every assigned output has a display of its own.")
                    .font(ARCTheme.mono(12, .bold)).foregroundStyle(ARCTheme.text0)
            } else {
                ForEach(warnings) { WarningLine(text: $0.text) }
            }
        }
        .arcModule(title: "Checks", tint: warnings.isEmpty ? ARCTheme.secGreen : ARCTheme.warn,
                   badge: ARCBandBadge(text: warnings.isEmpty ? "CLEAR" : "\(warnings.count) TO CHECK", fill: ARCTheme.ink))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            StripButton(title: "IDENTIFY", on: routing.identifying) {
                if routing.identifying { routing.dismissCards() } else { routing.identifyAll(placement) }
            }
            .help("Big number, name and resolution on every physical screen")
            StripButton(title: "REFRESH") { placement.screensChanged() }
                .help("Read the connected displays again")
            Spacer()
            StripButton(title: "TAKE ALL OFF", enabled: StageWindow.roomOutputs.contains { placement.isOpen($0) }) {
                routing.closeAllOutputs()
            }
            .help("Close the CONFIDENCE MONITOR and KEY OVERLAY windows (assignments are kept)")
            ARCActionButton("Done", size: 13) { dismiss() }
                .frame(height: 36)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(ARCTheme.moduleBg)
        .clipShape(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius))
    }
}

/// An output's name as a draggable tag: filled crimson (orange for CONTROL) when armed.
struct OutputToken: View {
    let window: StageWindow
    var filled: Bool = true
    /// The chip's short name (MONITOR, KEY), for the small display tiles.
    var short: Bool = false
    var body: some View {
        let tint = window == .control ? ARCTheme.secOrange : ARCTheme.secCrimson
        Text(short ? window.chipLabel : window.outputLabel)
            .font(ARCTheme.mono(12, .heavy))
            .tracking(1)
            .foregroundStyle(filled ? ARCTheme.ink : tint)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(filled ? tint : ARCTheme.ink)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tint, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .draggable(window.rawValue)
            .help("Drag \(window.outputLabel) onto a display")
    }
}

// MARK: - The display map

/// The displays as they are arranged, scaled to fit, each labelled; the drop and click targets.
struct DisplayMap: View {
    let armed: StageWindow
    @State private var placement = ArcStageTimerApp.sharedPlacement
    @State private var dropTarget: String?

    private struct Ghost: Identifiable { let id: String; let stored: StoredDisplay; let outputs: [StageWindow] }

    var body: some View {
        let displays = placement.connected
        let ghosts = self.ghosts
        GeometryReader { geo in
            let layout = self.layout(displays, ghosts: ghosts.count, in: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(displays) { d in
                    if let r = layout.rects[d.id] {
                        tile(d).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    }
                }
                ForEach(Array(ghosts.enumerated()), id: \.element.id) { i, g in
                    if i < layout.ghostRects.count {
                        let r = layout.ghostRects[i]
                        ghostTile(g).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(ARCTheme.ink)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var ghosts: [Ghost] {
        var byID: [String: (StoredDisplay, [StageWindow])] = [:]
        for w in StageWindow.roomOutputs {
            if case .unplugged(let s) = placement.state(w) {
                byID[s.id, default: (s, [])].1.append(w)
            }
        }
        return byID.map { Ghost(id: $0.key, stored: $0.value.0, outputs: $0.value.1) }.sorted { $0.id < $1.id }
    }

    /// Proportional rectangles: the union of the display frames scaled into the area (AppKit y flipped), with
    /// room kept on the right for unplugged ghosts.
    private func layout(_ displays: [DisplayInfo], ghosts: Int, in size: CGSize) -> (rects: [String: CGRect], ghostRects: [CGRect]) {
        let pad: CGFloat = 16
        guard let first = displays.first else { return ([:], []) }
        var union = displays.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let ghostW = union.height * 0.9 * 16 / 9 * 0.6
        if ghosts > 0 { union.size.width += (ghostW + union.width * 0.04) }
        let scale = min((size.width - 2 * pad) / union.width, (size.height - 2 * pad) / union.height)
        let used = CGSize(width: union.width * scale, height: union.height * scale)
        let ox = (size.width - used.width) / 2, oy = (size.height - used.height) / 2
        var rects: [String: CGRect] = [:]
        let gap: CGFloat = 3
        for d in displays {
            let f = d.frame
            rects[d.id] = CGRect(x: ox + (f.minX - union.minX) * scale + gap,
                                 y: oy + (union.maxY - f.maxY) * scale + gap,
                                 width: f.width * scale - 2 * gap, height: f.height * scale - 2 * gap)
        }
        var ghostRects: [CGRect] = []
        if ghosts > 0 {
            let gw = ghostW * scale, gh = min(used.height / CGFloat(ghosts) - 8, gw * 9 / 16 + 60)
            for i in 0..<ghosts {
                ghostRects.append(CGRect(x: ox + used.width - gw, y: oy + CGFloat(i) * (gh + 8), width: gw, height: gh))
            }
        }
        return (rects, ghostRects)
    }

    private func tile(_ d: DisplayInfo) -> some View {
        let outs = StageWindow.roomOutputs.filter { placement.state($0).display?.id == d.id }
        let isControl = placement.controlDisplayID() == d.id
        let targeted = dropTarget == d.id
        let shared = outs.count > 1
        let border: Color = targeted ? ARCTheme.secBlue : (shared ? ARCTheme.warn : (outs.isEmpty ? ARCTheme.text2 : ARCTheme.secCrimson))
        return Button {
            OutputsPanelController.shared.request(armed, to: d)
        } label: {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(targeted ? ARCTheme.subGroup : ARCTheme.moduleBg)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(d.index)")
                            .font(.system(size: 44, weight: .heavy, design: .monospaced))
                            .foregroundStyle(ARCTheme.text0)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).font(ARCTheme.mono(15, .heavy)).foregroundStyle(ARCTheme.text0)
                                .lineLimit(1).truncationMode(.middle)
                            Text(d.resolution).font(ARCTheme.mono(12, .bold)).foregroundStyle(ARCTheme.text1)
                        }
                    }
                    HStack(spacing: 4) {
                        if d.isPrimary { tag("PRIMARY", ARCTheme.text1) }
                        if d.isBuiltIn { tag("BUILT-IN", ARCTheme.text1) }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(outs, id: \.self) { OutputToken(window: $0, short: true) }
                        if isControl { OutputToken(window: .control, short: true) }
                        if outs.isEmpty && !isControl {
                            Text("NO OUTPUT").font(ARCTheme.mono(11, .bold)).foregroundStyle(ARCTheme.text2)
                        }
                    }
                }
                .padding(12)
            }
            .overlay(Rectangle().strokeBorder(border, lineWidth: outs.isEmpty && !targeted ? 1.5 : 3))
            .overlay(alignment: .leading) { Rectangle().fill(border).frame(width: 5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Display \(d.index): \(d.name), \(d.resolution). Click to put \(armed.outputLabel) here.")
        .contextMenu {
            ForEach(StageWindow.assignable, id: \.self) { w in
                Button("Put \(w.outputLabel) here") { OutputsPanelController.shared.request(w, to: d) }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let w = StageWindow(rawValue: raw) else { return false }
            OutputsPanelController.shared.request(w, to: d)
            return true
        } isTargeted: { on in
            if on { dropTarget = d.id } else if dropTarget == d.id { dropTarget = nil }
        }
    }

    private func ghostTile(_ g: Ghost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UNPLUGGED").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.ink)
                .padding(.horizontal, 6).padding(.vertical, 2).background(ARCTheme.arcRed)
            Text(g.stored.name).font(ARCTheme.mono(14, .heavy)).foregroundStyle(ARCTheme.text0).lineLimit(1).truncationMode(.middle)
            Text(g.stored.resolution).font(ARCTheme.mono(12, .bold)).foregroundStyle(ARCTheme.text1)
            Spacer(minLength: 0)
            ForEach(g.outputs, id: \.self) { OutputToken(window: $0, filled: false, short: true) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(Rectangle().strokeBorder(ARCTheme.arcRed, style: StrokeStyle(lineWidth: 2, dash: [8, 5])))
        .help("\(g.outputs.map(\.outputLabel).joined(separator: " and ")) belong on \(g.stored.name), which is not connected. Kept; restores when it returns.")
    }

    private func tag(_ t: String, _ c: Color) -> some View {
        Text(t).font(ARCTheme.mono(10, .heavy)).foregroundStyle(c)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(c, lineWidth: 1))
    }
}
#endif
