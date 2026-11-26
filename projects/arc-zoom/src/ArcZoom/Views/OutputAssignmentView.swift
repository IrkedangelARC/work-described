//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import ARCStyle

/// Presenter's OUTPUTS chips, duplicated (2026-09-20): PGM and MON as menus of the external displays,
/// GO LIVE / CLOSE, IDENTIFY. Unassigned is a state the operator must see, not a dimmed one.
struct OutputAssignmentView: View {
    @State private var closeArmed = false
    @Environment(DisplayManager.self) private var displays
    @Environment(Sidecar.self) private var sidecar

    var body: some View {
        // One row in the console HEADER (2026-09-23: the displays are set once per show, so they sit with the
        // status, like Presenter 5.5.0's OUTPUTS chips; they were a sub-group beside the previews and made that
        // row, and the previews, taller).
        HStack(spacing: ARCTheme.s(6)) {
            if displays.externalScreens.isEmpty {
                HStack(spacing: 6) {
                    Circle().fill(ARCTheme.textSecondary).frame(width: ARCTheme.s(8), height: ARCTheme.s(8))
                    Text("NO EXTERNAL DISPLAYS").font(ARCTheme.ui(11, .heavy)).foregroundStyle(ARCTheme.textSecondary).fixedSize()
                }
                .padding(.horizontal, ARCTheme.s(8)).padding(.vertical, ARCTheme.s(5))
                .background(ARCTheme.surfaceLight)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
                .cornerRadius(4)
                .help("PGM and MON need a display besides this one. Connect it and the chips appear here.")
            } else {
                outputBlock(.program)
                outputBlock(.confidence)
                actionButton
                if displays.hasActiveOutput { blackButton }
                identifyButton
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// PGM / MON chip width. A borderless `Menu` ignores a frame on its LABEL (AppKit draws it), so the width
    /// goes on the menu itself, or the chip collapses to its dot when the header is short of room (the bug
    /// Presenter's field Pro showed, 2026-09-23). Never narrower than "PGM  NOT SET" at the chip font.
    static var chipMinW: CGFloat { (ARCTheme.legible(12) * ARCTheme.uiScale * 0.62 * 12).rounded() + 4 }
    static var chipMaxW: CGFloat { ARCTheme.s(170) }

    private func outputBlock(_ output: OutputType) -> some View {
        let screenID = displays.screenID(for: output)
        let connected = displays.isConnected(output)
        let screenName = displays.screenFor(output)?.localizedName
        let dot: Color = connected ? ARCTheme.readyGreen : (screenID != nil ? ARCTheme.accent : ARCTheme.warn)
        return Menu {
            ForEach(displays.externalScreens) { screen in
                Button {
                    displays.assign(screen: screen, to: output)
                } label: {
                    HStack {
                        if screenID == screen.id { Image(systemName: "checkmark") }
                        Text("\(screen.localizedName) (\(screen.resolution))")
                    }
                }
            }
            Divider()
            Button("Identify \(output.shortLabel) screen") { if let s = displays.screenFor(output) { displays.flashScreen(s) } }
                .disabled(screenID == nil)
            Button("None") { displays.unassign(output) }
        } label: {
            Text("\(output.shortLabel)  \(screenName ?? "NOT SET")")
                .foregroundStyle(ARCTheme.text0)
                .lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: Self.chipMinW, maxWidth: Self.chipMaxW, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .font(ARCTheme.ui(12, .bold))
        .padding(.leading, 20).padding(.trailing, 10).padding(.vertical, 5)
        .background(ARCTheme.appGrey)
        .overlay(alignment: .leading) { Circle().fill(dot).frame(width: ARCTheme.s(10), height: ARCTheme.s(10)).padding(.leading, 8) }
        .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(connected ? ARCTheme.live : ARCTheme.line, lineWidth: 1))
        .cornerRadius(ARCTheme.cornerRadius)
        .help("\(output.displayName): \(screenName ?? "not assigned"). \(connected ? "Live on its display." : (screenID != nil ? "Assigned, not live: GO LIVE puts it up." : "Pick an external display.")) Click to choose.")
    }

    private var actionButton: some View {
        let live = displays.hasActiveOutput
        return Button {
            if live {
                // CLOSE releases the room displays to the desktop: arm, then confirm within 3 s.
                if closeArmed { closeArmed = false; displays.closeAllOutputs() }
                else { closeArmed = true; DispatchQueue.main.asyncAfter(deadline: .now() + 3) { closeArmed = false } }
            }
            else {
                if displays.programScreenID == nil, displays.confidenceScreenID == nil { displays.autoAssign() }
                displays.openAllAssigned()
            }
        } label: {
            Text(live ? (closeArmed ? "CONFIRM CLOSE" : "CLOSE") : "GO LIVE")
                .font(ARCTheme.ui(11, .heavy)).lineLimit(1).fixedSize()
                .foregroundStyle(.white)
                .padding(.horizontal, ARCTheme.s(10)).padding(.vertical, ARCTheme.s(5))
                .background(live ? (closeArmed ? ARCTheme.warn : ARCTheme.appGrey) : ARCTheme.liveRed)
                .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(live ? ARCTheme.line : ARCTheme.liveRed, lineWidth: 1))
                .cornerRadius(ARCTheme.cornerRadius)
        }
        .buttonStyle(.plain)
        .help(live ? "Take every output off its display (⌘ Esc does the same); the windows come back to this screen" : "Put PGM and MON on their displays, full screen, shielding level")
    }

    /// BLACK every live output, or bring the pictures back. The displays stay covered either way.
    private var blackButton: some View {
        let held = LayoutWindow.Kind.allCases.filter { sidecar.isHeld($0) }
        let allBlack = !held.isEmpty && held.allSatisfy { sidecar.isBlack($0) }
        return Button { sidecar.blackAll(!allBlack) } label: {
            Text("BLACK")
                .font(ARCTheme.ui(11, .heavy)).lineLimit(1).fixedSize()
                .foregroundStyle(allBlack ? .white : ARCTheme.text0)
                .padding(.horizontal, ARCTheme.s(10)).padding(.vertical, ARCTheme.s(5))
                .background(allBlack ? ARCTheme.liveRed : ARCTheme.appGrey)
                .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(allBlack ? ARCTheme.liveRed : ARCTheme.line, lineWidth: 1))
                .cornerRadius(ARCTheme.cornerRadius)
        }
        .buttonStyle(.plain)
        .help(allBlack ? "Pictures back on every live output" : "Black every live output; the displays stay covered")
    }

    private var identifyButton: some View {
        Button { displays.flashAllScreens() } label: {
            Text("IDENTIFY")
                .font(ARCTheme.ui(11, .bold)).lineLimit(1).fixedSize()
                .foregroundStyle(ARCTheme.text0)
                .padding(.horizontal, ARCTheme.s(10)).padding(.vertical, ARCTheme.s(5))
                .background(ARCTheme.appGrey)
                .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(ARCTheme.line, lineWidth: 1))
                .cornerRadius(ARCTheme.cornerRadius)
        }
        .buttonStyle(.plain)
        .help("Flash every screen with its number, name and role for two seconds")
    }
}
