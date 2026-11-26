//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// SOURCES module (rail): what the program output is showing AND what is parked
/// under it, side by side, so a PowerPoint opened mid-show can be seen to be
/// ready before it is taken (2026-09-16). The right tile is the live
/// ScreenCaptureKit stream of PowerPoint's show window, which works while the
/// window is fully covered by the program output (measured, V4_SWITCHER.md).
struct SourcesControlView: View {
    @Environment(SwitchEngine.self) private var switcher
    @Environment(PowerPointSource.self) private var powerPoint
    @Environment(WindowCapture.self) private var capture
    @Environment(WindowSource.self) private var windowSource
    @State private var pickerShown = false
    @State private var picks: [WindowSource.Pick] = []

    private static let pptTypes: [UTType] = ["pptx", "ppt", "pptm"].compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                programTile
                powerPointTile
            }
            .frame(height: 132)

            // One fixed caption line (a module that changes height moves the rail).
            Text(statusLine)
                .font(ARCTheme.mono(12, .regular))
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 16)
                .help(statusHelp)

            HStack(spacing: 8) {
                chip("OPEN…") { openPowerPoint() }
                    .disabled(powerPoint.isBusy || switcher.isPowerPointLive)
                    .help("Open a .pptx natively in PowerPoint and park it under the program output, notes on the confidence monitor")
                // Any app's window (Keynote played In Window, a browser, a player) parked the same way.
                chip("WINDOW…") { pickerShown = true }
                    .disabled(windowSource.isBusy || switcher.isPowerPointLive)
                    .help("Park any on-screen window of another app under the program output and drive it with the clicker")
                    .popover(isPresented: $pickerShown, arrowEdge: .bottom) { windowPicker }
                if powerPoint.phase == .idle, let remembered = powerPoint.file {
                    // A restart found the deck from the last session but no show
                    // running for it: one press brings it back.
                    chip("REOPEN", tint: ARCTheme.warn) {
                        Task { @MainActor in
                            await capture.stop()
                            await powerPoint.open(remembered)
                            if powerPoint.isReady { await switcher.prepare() }
                        }
                    }
                    .disabled(powerPoint.isBusy)
                    .help("Reopen \(remembered.lastPathComponent) in PowerPoint and park it")
                }

                if switcher.isPowerPointLive {
                    chip("RETURN TO DECK", fill: ARCTheme.liveRed) { Task { await switcher.returnToDeck() } }
                        .disabled(switcher.isBusy)
                        .help("Fade through black back to the deck (Cmd-Shift-K)")
                    chip("BLACK", fill: switcher.powerPointBlack ? ARCTheme.liveRed : nil) { switcher.togglePowerPointBlack() }
                        .help("Black the program output while the source is live (B)")
                } else if armedIsWindow {
                    chip("TAKE WINDOW", tint: windowSource.isReady ? ARCTheme.readyGreen : ARCTheme.textTertiary) { Task { await switcher.takeWindow() } }
                        .disabled(!windowSource.isReady || switcher.isBusy)
                        .help(windowSource.isReady ? "Fade through black to the parked window (Cmd-Shift-K)" : "Attach a window first")
                } else {
                    chip("TAKE POWERPOINT", tint: powerPoint.isReady ? ARCTheme.readyGreen : ARCTheme.textTertiary) { Task { await switcher.takePowerPoint() } }
                        .disabled(!powerPoint.isReady || switcher.isBusy)
                        .help(powerPoint.isReady ? "Fade through black to the parked PowerPoint show (Cmd-Shift-K)" : "Park a PowerPoint first")
                }

                Spacer(minLength: 4)

                if armedIsWindow {
                    chip("LET GO") { Task { await capture.stop(); windowSource.detach(); if powerPoint.isReady { switcher.arm(.powerpoint) } } }
                        .disabled(windowSource.phase == .idle || windowSource.isBusy || switcher.isPowerPointLive)
                        .help("Give the window back to its app (nothing is closed)")
                } else {
                    chip("CLOSE") { Task { await capture.stop(); await powerPoint.close() } }
                        .disabled(powerPoint.phase == .idle || powerPoint.isBusy || switcher.isPowerPointLive)
                        .help("End the PowerPoint show and close the file (PowerPoint stays open)")
                }
            }
        }
    }

    /// The source the TAKE goes to (SwitchEngine.external), once a window is attached.
    private var armedIsWindow: Bool { switcher.liveSource == .window || (switcher.liveSource == .deck && windowSource.phase != .idle && switcher.isExternalArmed(.window)) }

    private var windowPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PARK A WINDOW").font(ARCTheme.mono(11, .bold)).foregroundStyle(ARCTheme.textSecondary)
            // Listed HERE, on appear: filled in the same action that presented the popover, the popover rendered
            // the stale empty list ("no other app has a window open" with 20 candidates logged, 2026-09-19).
            Color.clear.frame(width: 0, height: 0).onAppear {
                picks = WindowSource.shareable()
                ShowLog.log("window picker: \(picks.count) candidate(s)")
            }
            if picks.isEmpty {
                Text("no other app has a window open").font(ARCTheme.caption).foregroundStyle(ARCTheme.textTertiary)
            }
            ForEach(picks) { pick in
                Button {
                    pickerShown = false
                    Task { @MainActor in
                        if capture.isRunning { await capture.stop() }
                        guard await windowSource.attach(pick) else { return }
                        await switcher.prepare(.window)
                    }
                } label: {
                    HStack {
                        Text(pick.label).font(ARCTheme.mono(12, .regular)).lineLimit(1).truncationMode(.middle)
                        if !pick.isOnScreen {
                            // Another Space or full screen: the capture still delivers it (measured 2026-09-18).
                            Text("OTHER SPACE").font(ARCTheme.mono(9, .heavy)).foregroundStyle(ARCTheme.ink)
                                .padding(.horizontal, 4).padding(.vertical, 1).background(RoundedRectangle(cornerRadius: 3).fill(ARCTheme.warn))
                        }
                        Spacer()
                        Text("\(Int(pick.frame.width))×\(Int(pick.frame.height))").font(ARCTheme.mono(10, .regular)).foregroundStyle(ARCTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 360)
        .background(ARCTheme.ink)
    }

    // MARK: - Tiles

    private var programTile: some View {
        let frozen = ArcPresenterApp.sharedZoom.sourceState == .frozen && switcher.liveSource == .window
        return tile(title: "PROGRAM", badge: frozen ? "FROZEN" : (switcher.liveSource == .window ? "WINDOW" : (switcher.isPowerPointLive ? "POWERPOINT" : "DECK")), badgeColor: ARCTheme.liveRed) {
            if switcher.isPowerPointLive {
                if switcher.powerPointBlack {
                    Color.black
                } else {
                    CaptureMirrorView(capture: capture)
                }
            } else {
                let live = ArcPresenterApp.sharedLiveEngine
                if live.isBlack {
                    Color.black
                } else {
                    SlideThumbnailView(image: ArcPresenterApp.sharedLiveCache.imageFor(page: live.currentIndex),
                                       pageNumber: live.currentPage)
                }
            }
        }
    }

    private var powerPointTile: some View {
        if armedIsWindow { return AnyView(windowTile) }
        return AnyView(powerPointTileBody)
    }

    private var windowTile: some View {
        let (badge, color): (String, Color) = {
            if switcher.isPowerPointLive { return ("ON AIR", ARCTheme.liveRed) }
            switch windowSource.phase {
            case .idle: return ("EMPTY", ARCTheme.textTertiary)
            case .lost: return ("LOST", ARCTheme.liveRed)
            case .attached: return capture.isRunning ? ("READY", ARCTheme.readyGreen) : ("NO PICTURE", ARCTheme.warn)
            }
        }()
        return tile(title: "UNDER SHIELD", badge: badge, badgeColor: color) {
            if windowSource.phase == .attached, capture.isRunning || capture.seeded {
                CaptureMirrorView(capture: capture)
            } else {
                ZStack {
                    ARCTheme.surface
                    Text(windowSource.pick?.label ?? "no window parked")
                        .font(ARCTheme.caption)
                        .foregroundStyle(ARCTheme.textTertiary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var powerPointTileBody: some View {
        let (badge, color): (String, Color) = {
            if switcher.isPowerPointLive { return ("ON AIR", ARCTheme.liveRed) }
            switch powerPoint.phase {
            case .idle: return ("EMPTY", ARCTheme.textTertiary)
            case .opening, .starting: return ("OPENING", ARCTheme.warn)
            case .failed: return ("FAILED", ARCTheme.liveRed)
            case .parked: return powerPoint.isReady ? (capture.isRunning ? "READY" : "NO PICTURE", capture.isRunning ? ARCTheme.readyGreen : ARCTheme.warn) : ("CHECK", ARCTheme.warn)
            }
        }()
        return tile(title: "UNDER SHIELD", badge: badge, badgeColor: color) {
            if powerPoint.phase == .parked, capture.isRunning || capture.seeded {
                CaptureMirrorView(capture: capture)
            } else {
                ZStack {
                    ARCTheme.surface
                    Text(powerPoint.phase == .idle ? "no PowerPoint parked" : powerPoint.phase.rawValue.uppercased())
                        .font(ARCTheme.caption)
                        .foregroundStyle(ARCTheme.textTertiary)
                }
            }
        }
    }

    private func tile<Content: View>(title: String, badge: String, badgeColor: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                    .font(ARCTheme.mono(11, .bold))
                    .foregroundStyle(ARCTheme.textSecondary)
                Spacer()
                Text(badge)
                    .font(ARCTheme.mono(10, .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(badgeColor)
                    .cornerRadius(3)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(ARCTheme.line, lineWidth: 1))
        }
    }

    // MARK: - Status

    private var statusLine: String {
        if armedIsWindow {
            if let err = windowSource.error { return err }
            guard let pick = windowSource.pick else { return "Pick a window to park it under the program output" }
            let pic = capture.isRunning ? "picture live" : (capture.seeded ? "picture seeded" : "no picture yet")
            return switcher.liveSource == .window ? "\(pick.label) — ON AIR, \(pic)" : "\(pick.label) — parked, \(pic), ready to take"
        }
        if let err = powerPoint.error { return err }
        if let problem = powerPoint.problems.first { return problem }
        if let err = switcher.lastError, powerPoint.phase == .parked { return err }
        switch powerPoint.phase {
        case .idle: return "Open a PowerPoint to park it under the program output"
        case .opening: return powerPoint.progress ?? "Opening in PowerPoint…"
        case .starting: return "Starting the slideshow…"
        case .failed: return "Open failed"
        case .parked:
            let name = powerPoint.file?.lastPathComponent ?? "PowerPoint"
            let pic = capture.isRunning ? "picture live" : (capture.seeded ? "picture seeded" : "no picture yet")
            return switcher.isPowerPointLive ? "\(name) — ON AIR, \(pic)" : "\(name) — parked, \(pic), ready to take"
        }
    }

    private var statusColor: Color {
        if armedIsWindow { return windowSource.error != nil ? ARCTheme.warn : (windowSource.isReady ? ARCTheme.readyGreen : ARCTheme.text2) }
        if powerPoint.error != nil || !powerPoint.problems.isEmpty { return ARCTheme.warn }
        return powerPoint.isReady ? ARCTheme.readyGreen : ARCTheme.text2
    }

    private var statusHelp: String {
        var lines = [statusLine]
        lines.append(contentsOf: powerPoint.problems)
        if let e = capture.lastError { lines.append(e) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Actions

    private func openPowerPoint() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.pptTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a PowerPoint to run natively under the program output"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await capture.stop()
                await powerPoint.close()
                await powerPoint.open(url)
                if powerPoint.isReady { await switcher.prepare() }
            }
        }
    }

    private func chip(_ label: String, tint: Color = ARCTheme.textPrimary, fill: Color? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(ARCTheme.mono(11, .bold))
                .foregroundStyle(fill == nil ? tint : .white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(fill ?? ARCTheme.appGrey)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(fill ?? ARCTheme.line, lineWidth: 1))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

/// The SOURCES window: the module on the app ground, sized to its content.
struct SourcesWindowView: View {
    var body: some View {
        VStack(spacing: ARCTheme.railPad) {
            SourcesControlView()
                .arcModule(title: "SOURCES", tint: ARCTheme.secBlue)   // IN: red is the mark and LIVE, never a section (brand roles, 2026-09-18)
            // ZOOM under SOURCES (2026-09-20): readiness, PICK / TAKE / RETURN / LET GO, glyph -> the Zoom window.
            ZoomModuleView()
                .padding(ARCTheme.modulePad)
                .arcModule(title: "ZOOM", tint: ARCTheme.secBlue)
        }
        .padding(ARCTheme.railPad)
        .frame(width: ARCTheme.railW)
        .background(ARCTheme.ink)
    }
}

/// A second view of the capture stream (the program output owns the first).
/// One mirror per view identity, kept in a box so SwiftUI rebuilds don't leak.
private struct CaptureMirrorView: NSViewRepresentable {
    let capture: WindowCapture
    @State private var box = MirrorBox()
    final class MirrorBox { var view: CaptureLayerView? }

    func makeNSView(context: Context) -> CaptureLayerView {
        if let v = box.view { return v }
        let v = capture.makeMirror()
        box.view = v
        return v
    }
    func updateNSView(_ view: CaptureLayerView, context: Context) {}
}
