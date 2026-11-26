//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct OutputAssignmentView: View {
    @Environment(DisplayManager.self) private var displayManager
    @Environment(DeckLinkOutput.self) private var decklink
    @Environment(ShareOutput.self) private var share
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    /// The header's output chips (2026-09-23: OUTPUTS left the footer for the header bar). One row when
    /// the header has the width, two by two when it does not; a chip never narrows below its label.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                chips
                actions
            }
            HStack(spacing: 6) {
                let c = chipList
                Grid(horizontalSpacing: 6, verticalSpacing: 4) {
                    ForEach(0..<((c.count + 1) / 2), id: \.self) { row in
                        GridRow {
                            c[row * 2]
                            if row * 2 + 1 < c.count { c[row * 2 + 1] } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                        }
                    }
                }
                actions
            }
        }
    }

    /// The chips in order, as one list, so the 2 x 2 grid can place them.
    private var chipList: [AnyView] {
        var list: [AnyView] = []
        if displayManager.externalScreens.isEmpty {
            list.append(AnyView(noDisplays))
        } else {
            list.append(AnyView(outputBlock(output: .program, screenID: displayManager.programScreenID, isConnected: displayManager.isProgramConnected)))
            list.append(AnyView(outputBlock(output: .confidence, screenID: displayManager.confidenceScreenID, isConnected: displayManager.isConfidenceConnected)))
        }
        if DeckLinkOutput.driverInstalled { list.append(AnyView(sdiBlock)) }
        list.append(AnyView(shareBlock))
        return list
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(Array(chipList.enumerated()), id: \.offset) { _, chip in chip }
    }

    @ViewBuilder
    private var actions: some View {
        if !displayManager.externalScreens.isEmpty {
            actionButton
            identifyButton
        }
    }

    private var noDisplays: some View {
        HStack(spacing: 6) {
            Circle().fill(ARCTheme.textSecondary).frame(width: 8, height: 8)
            Text("NO DISPLAYS").font(Self.chipFont).foregroundStyle(ARCTheme.textSecondary).lineLimit(1).fixedSize()
        }
        .help("No external displays: PROGRAM and MON need one")
    }

    /// Chip text: the legible 12 pt (14 at standard console text), mono bold like the rest of the console.
    static let chipFont = ARCTheme.mono(12, .bold)

    // MARK: - SDI (V4.2: PROGRAM over a DeckLink / UltraStudio)

    /// Same chip as PGM / MON: dot, name, menu of playback devices. Picking one
    /// starts the output from the program window; None stops it.
    private var sdiBlock: some View {
        let running = decklink.isRunning
        let name = decklink.activeDevice?.name ?? "NOT SET"
        return Menu {
            ForEach(decklink.devices) { device in
                Button {
                    Task { await decklink.start(device: device) }
                } label: {
                    HStack {
                        if decklink.activeDevice?.persistentID == device.persistentID { Image(systemName: "checkmark") }
                        Text(device.name)
                    }
                }
            }
            if decklink.devices.isEmpty {
                Text("No DeckLink output connected").foregroundStyle(.secondary)
            }
            Divider()
            Picker("Frame rate", selection: Binding(get: { decklink.fps }, set: { decklink.fps = $0 })) {
                ForEach(DeckLinkOutput.fpsChoices, id: \.self) { f in Text(f == f.rounded() ? "\(Int(f))" : String(format: "%.2f", f)).tag(f) }
            }
            Divider()
            Button("Refresh devices") { decklink.refreshDevices() }
            Button("None") { decklink.stop() }
        } label: {
            Text("SDI  \(name)")
                .foregroundStyle(ARCTheme.text0)
                .lineLimit(1)
                .truncationMode(.middle)
                // The chip gives way before the window does: a Menu sizes to its label, so the
                // label itself is the flexible part (min, then truncation; ideal when there is room).
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .outputChipWidth()
        .font(Self.chipFont)
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(ARCTheme.appGrey)
        .overlay(alignment: .leading) {
            Circle().fill(running ? (decklink.isStalled ? ARCTheme.warn : ARCTheme.readyGreen) : (decklink.status != nil ? ARCTheme.liveRed : ARCTheme.textTertiary)).frame(width: 8, height: 8).padding(.leading, 6)
        }
        .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(running ? ARCTheme.live : ARCTheme.line, lineWidth: 1))
        .cornerRadius(ARCTheme.cornerRadius)
        .help(decklink.status ?? (running ? "PROGRAM is going out on \(name) at \(decklink.fps) fps (\(decklink.sentFrames) frames sent, \(decklink.droppedFrames) dropped)" : "Send PROGRAM to a Blackmagic DeckLink / UltraStudio as SDI or HDMI. Works with or without a PROGRAM display."))
        .onAppear { decklink.refreshDevices() }
    }

    // MARK: - SHARE (PLAN_zoom_source step 1: the plain program picture for Zoom's share picker)

    /// Same chip shape as SDI: dot, name. Click toggles the ordinary-level share window.
    private var shareBlock: some View {
        let open = share.isOpen
        return Button {
            if open { share.close() } else { Task { await share.open() } }
        } label: {
            Text("SHARE  \(open ? "OPEN" : "OFF")")
                .foregroundStyle(ARCTheme.text0)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .outputChipWidth()
        .font(Self.chipFont)
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(ARCTheme.appGrey)
        .overlay(alignment: .leading) {
            Circle().fill(open ? ARCTheme.readyGreen : (share.status != nil ? ARCTheme.liveRed : ARCTheme.textTertiary)).frame(width: 8, height: 8).padding(.leading, 6)
        }
        .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(open ? ARCTheme.live : ARCTheme.line, lineWidth: 1))
        .cornerRadius(ARCTheme.cornerRadius)
        .help(share.status ?? (open ? "The plain program picture is open as the window \"\(ShareOutput.title)\": pick it in Zoom's share picker under Application windows. Click to close." : "Open the program picture as an ordinary window for Zoom to share (\"\(ShareOutput.title)\"). Zoom cannot list the program output itself."))
    }

    // MARK: - Output Block

    private func outputBlock(
        output: OutputType,
        screenID: CGDirectDisplayID?,
        isConnected: Bool
    ) -> some View {
        let screenName = displayManager.screenFor(output)?.localizedName
        let dotColor: Color = isConnected ? ARCTheme.readyGreen
            : (screenID != nil ? ARCTheme.accent : ARCTheme.textTertiary)
        let nameColor: Color = isConnected ? ARCTheme.readyGreen
            : (screenID != nil ? ARCTheme.textSecondary : ARCTheme.textTertiary)

        return Menu {
            ForEach(displayManager.externalScreens) { screen in
                Button {
                    displayManager.assign(screen: screen, to: output)
                } label: {
                    HStack {
                        if screenID == screen.id {
                            Image(systemName: "checkmark")
                        }
                        Text("\(screen.localizedName) (\(screen.resolution))")
                    }
                }
            }

            Divider()

            Button("None") {
                displayManager.unassign(output)
            }
        } label: {
            // Unassigned is a state the operator must see, not a dimmed one.
            Text("\(output.shortLabel)  \(screenName ?? "NOT SET")")
                .foregroundStyle(ARCTheme.text0)
                .lineLimit(1)
                .truncationMode(.middle)
                // The chip gives way before the window does: a Menu sizes to its label, so the
                // label itself is the flexible part (min, then truncation; ideal when there is room).
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .outputChipWidth()
        .font(ARCTheme.mono(15, .bold))
        // Chip decoration on the menu itself: a borderless menu draws only
        // its label's text, so the dot, ground and border live out here.
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(ARCTheme.appGrey)
        .overlay(alignment: .leading) {
            Circle().fill(screenID == nil ? ARCTheme.warn : dotColor).frame(width: 8, height: 8).padding(.leading, 6)
        }
        .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(isConnected ? ARCTheme.live : ARCTheme.line, lineWidth: 1))
        .cornerRadius(ARCTheme.cornerRadius)
        .help("Assign \(output.displayName) to an external display")
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        if displayManager.hasActiveOutput {
            Button {
                displayManager.closeAllOutputs()
            } label: {
                Text("CLOSE")
                    .font(ARCTheme.mono(12, .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(ARCTheme.liveRed)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Close all output windows and return to edit mode")
        } else if displayManager.programScreenID != nil || displayManager.confidenceScreenID != nil {
            Button {
                activateOutputs()
            } label: {
                Text("GO LIVE")
                    .font(ARCTheme.mono(12, .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(ARCTheme.readyGreen)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Send slides to assigned output displays (Escape to close)")
        }
    }

    // MARK: - Identify

    private var identifyButton: some View {
        Button {
            displayManager.flashAllScreens()
        } label: {
            Image(systemName: "tv.badge.signal")
                .font(.system(size: 15))
                .foregroundStyle(ARCTheme.textPrimary)
        }
        .buttonStyle(.plain)
        .help("Flash screen labels on all displays (Cmd+Shift+I)")
    }


    // MARK: - Actions

    private func activateOutputs() {
        if displayManager.programScreenID != nil {
            openWindow(id: OutputType.program.rawValue)
        }
        if displayManager.confidenceScreenID != nil {
            openWindow(id: OutputType.confidence.rawValue)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            displayManager.openAllAssigned()
        }
    }
}

extension View {
    /// A borderless `Menu` is drawn by AppKit and does NOT honour a frame on its label: squeezed, it
    /// narrowed to its dot and the chip went blank ("the buttons for assigning the monitors was shrunk
    /// and unreadable", MacBook Pro 1512 pt, 2026-09-23). The width floor goes on the menu itself.
    /// In the header (2026-09-23) a chip is as wide as its label, clamped to the range, and no wider:
    /// stretched, four chips took the width the deck tabs needed.
    func outputChipWidth() -> some View {
        frame(minWidth: ARCTheme.outputChipMinW, maxWidth: ARCTheme.outputChipMaxW, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
    }
}
