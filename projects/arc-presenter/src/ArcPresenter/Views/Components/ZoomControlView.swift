//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import ARCStyle

/// The ZOOM module under SOURCES in the Sources window (2026-09-20: "zoom to have its own
/// control sub window under the sources expanded control"): the readiness line, PICK / TAKE / RETURN /
/// LET GO, and the expand glyph that opens the floating Zoom window (the glyph ALWAYS opens a window).
struct ZoomModuleView: View {
    @Environment(ZoomSource.self) private var zoom
    @Environment(SwitchEngine.self) private var switcher
    @Environment(WindowSource.self) private var windowSource
    @Environment(ShareOutput.self) private var share

    var body: some View {
        VStack(spacing: 6) {
            ZoomReadinessRow()
            HStack(spacing: 8) {
                ZoomButtons(compact: true)
                Spacer(minLength: 4)
            }
            SidecarRow()
            HStack(spacing: 8) {
                SidecarButtons()
                Spacer(minLength: 4)
            }
        }
    }
}

/// The floating Zoom window: the checklist in full, the live thumbnail, the buttons, the runbook.
struct ZoomWindowView: View {
    @Environment(ZoomSource.self) private var zoom
    @Environment(WindowCapture.self) private var capture
    @Environment(ShareOutput.self) private var share

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZoomChecklist()
            HStack(alignment: .top, spacing: 10) {
                ZoomMirrorTile()
                    .frame(width: 256, height: 144)
                VStack(alignment: .leading, spacing: 8) {
                    ZoomButtons(compact: false)
                    if let e = zoom.lastError {
                        Text(e).font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("ARC ZOOM (SIDECAR)").font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.textSecondary)
                SidecarRow()
                SidecarButtons()
                SidecarDetail()
            }
            runbook
        }
        .padding(ARCTheme.modulePad)
        .arcModule(title: "ZOOM", tint: ARCTheme.secBlue)
        .padding(ARCTheme.railPad)
        .frame(width: 620)
        .background(ARCTheme.ink)
    }

    private var runbook: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RUNBOOK").font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.textSecondary)
            Group {
                Text("Zoom once per account: Use dual monitors ON (Settings > Meetings & webinars > In-meeting experience > Display), Hide self view, participant names OFF, Participants panel closed.")
                Text("Per show: SHARE, then in Zoom share the window \"\(ShareOutput.title)\" with Share sound ticked; PICK; TAKE. Arrows and space keep driving the deck; RETURN never mutes Zoom.")
                Text("Who fills program: right-click a tile in Zoom's second window, Pin to second screen, Speaker view. Three or more participants, or the second window shows you.")
                Text("Phones and tablets in the room: Disconnect Audio.")
            }
            .font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Pieces

/// One line: four dots and words, fixed width per item so nothing moves.
private struct ZoomReadinessRow: View {
    @Environment(ZoomSource.self) private var zoom
    @Environment(ShareOutput.self) private var share

    var body: some View {
        HStack(spacing: 10) {
            item("MEETING", on: zoom.snapshot.inMeeting, warn: zoom.snapshot.running && !zoom.snapshot.inMeeting,
                 help: zoom.snapshot.running ? (zoom.snapshot.inMeeting ? "Zoom has a meeting window" : "Zoom is running, no meeting window") : "Zoom is not running")
            item("DUAL", on: zoom.snapshot.dualMonitors, warn: zoom.snapshot.inMeeting && !zoom.snapshot.dualMonitors,
                 help: "Use dual monitors: Zoom's second meeting window is the only source that survives a share start")
            item("SHARE", on: zoom.snapshot.sharingOurs, warn: zoom.snapshot.sharing && !zoom.snapshot.sharingOurs,
                 help: zoom.snapshot.sharingOurs ? "Zoom is sharing \"\(ShareOutput.title)\"" : zoom.snapshot.sharing ? "Zoom is sharing something else" : share.isOpen ? "Share window open, Zoom not sharing it yet" : "Share window closed")
            sourceItem
            Spacer(minLength: 0)
        }
        .frame(height: 16)
    }

    private var sourceItem: some View {
        let s = zoom.sourceState
        let colour: Color = s == .frozen || s == .lost ? ARCTheme.liveRed : s == .live ? ARCTheme.live : s == .ready ? ARCTheme.readyGreen : ARCTheme.textTertiary
        return HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Text(s == .none ? "NO SOURCE" : s.rawValue.uppercased()).font(ARCTheme.mono(11, .bold)).foregroundStyle(colour)
        }
        .help(zoom.chip.detail)
    }

    private func item(_ name: String, on: Bool, warn: Bool, help: String) -> some View {
        let colour: Color = on ? ARCTheme.readyGreen : warn ? ARCTheme.warn : ARCTheme.textTertiary
        return HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Text(name).font(ARCTheme.mono(11, .bold)).foregroundStyle(on ? ARCTheme.text0 : ARCTheme.textSecondary)
        }
        .help(help)
    }
}

/// The full checklist rows for the floating window.
private struct ZoomChecklist: View {
    @Environment(ZoomSource.self) private var zoom
    @Environment(ShareOutput.self) private var share

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("ZOOM", zoom.snapshot.running ? "RUNNING" : "NOT RUNNING", zoom.snapshot.running ? .ok : .off)
            row("MEETING", zoom.snapshot.inMeeting ? "UP" : "NONE", zoom.snapshot.inMeeting ? .ok : (zoom.snapshot.running ? .warn : .off))
            row("DUAL MONITORS", zoom.snapshot.dualMonitors ? "ON (\(zoom.snapshot.meetingWindows.count) windows)" : (zoom.snapshot.inMeeting ? "OFF, one window" : "UNKNOWN"),
                zoom.snapshot.dualMonitors ? .ok : (zoom.snapshot.inMeeting ? .warn : .off))
            row("SHARE WINDOW", share.isOpen ? "OPEN \"\(ShareOutput.title)\"" : "CLOSED", share.isOpen ? .ok : .warn)
            row("ZOOM SHARING", zoom.snapshot.sharingOurs ? "THE PROGRAM PICTURE" : (zoom.snapshot.sharing ? "SOMETHING ELSE" : "NOT SHARING"),
                zoom.snapshot.sharingOurs ? .ok : (zoom.snapshot.sharing ? .warn : .off))
            row("SOURCE", zoom.chip.state, zoom.chip.level)
        }
    }

    private func row(_ name: String, _ state: String, _ level: HealthMonitor.Level) -> some View {
        let colour: Color = level == .ok ? ARCTheme.readyGreen : level == .warn ? ARCTheme.warn : level == .bad ? ARCTheme.liveRed : ARCTheme.textTertiary
        return HStack(spacing: 8) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Text(name).font(ARCTheme.mono(12, .bold)).foregroundStyle(ARCTheme.text0).frame(width: 130, alignment: .leading)
            Text(state).font(ARCTheme.mono(12, .regular)).foregroundStyle(colour).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// PICK / TAKE or RETURN / LET GO / SHARE, one set for both views.
private struct ZoomButtons: View {
    let compact: Bool
    @Environment(ZoomSource.self) private var zoom
    @Environment(SwitchEngine.self) private var switcher
    @Environment(WindowSource.self) private var windowSource
    @Environment(ShareOutput.self) private var share
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var zoomArmed: Bool { windowSource.pick?.bundleID == ZoomSource.bundleID && windowSource.phase == .attached }
    private var zoomLive: Bool { switcher.liveSource == .window && windowSource.pick?.bundleID == ZoomSource.bundleID }

    var body: some View {
        HStack(spacing: 8) {
            chip(share.isOpen ? "SHARE OPEN" : "SHARE", tint: share.isOpen ? ARCTheme.readyGreen : ARCTheme.text0) {
                if share.isOpen { share.close() } else { Task { await share.open() } }
            }
            .help(share.isOpen ? "The program picture is open as \"\(ShareOutput.title)\" for Zoom to share; click to close" : "Open the program picture as a window Zoom can share")

            chip("PICK", tint: zoom.snapshot.secondWindowID != nil ? ARCTheme.text0 : ARCTheme.textTertiary) { Task { await zoom.pick() } }
                .disabled(zoom.isBusy || windowSource.isBusy || switcher.isBusy || zoomLive)
                .help("Attach Zoom's dual-monitor second window, park it on the control monitor, arm it")

            if zoomLive {
                chip("RETURN TO DECK", fill: ARCTheme.liveRed) { Task { await zoom.returnToDeck() } }
                    .disabled(switcher.isBusy)
                    .help("Fade through black back to the deck; Zoom stays unmuted")
            } else {
                chip("TAKE", tint: zoomArmed && windowSource.isReady ? ARCTheme.readyGreen : ARCTheme.textTertiary) { Task { await zoom.take() } }
                    .disabled(!zoomArmed || !windowSource.isReady || switcher.isBusy)
                    .help(zoomArmed ? "Fade through black to Zoom's window on the program output" : "PICK first")
            }

            chip("LET GO") { Task { await zoom.letGo() } }
                .disabled(!zoomArmed || zoomLive || windowSource.isBusy)
                .help("Give the window back to Zoom (nothing is closed)")

            if compact {
                ARCExpandButton(tip: "Zoom: checklist, picture, runbook; click again to close", on: ControlWindow.isOpen(title: "Zoom")) {
                    ControlWindow.toggle(id: "zoom", title: "Zoom", open: openWindow, dismiss: dismissWindow)
                }
            }
        }
    }

    private func chip(_ label: String, tint: Color = ARCTheme.text0, fill: Color? = nil, action: @escaping () -> Void) -> some View {
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

/// The picked window's picture, a mirror of the capture (the program output owns the first view).
private struct ZoomMirrorTile: View {
    @Environment(ZoomSource.self) private var zoom
    @Environment(WindowCapture.self) private var capture

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if zoom.sourceState != .none {
                ZoomMirrorView(capture: capture)
            } else {
                Text("PICK to see Zoom's window here").font(ARCTheme.mono(10, .regular)).foregroundStyle(ARCTheme.textTertiary)
            }
            if zoom.sourceState == .frozen {
                Text("FROZEN").font(ARCTheme.mono(14, .heavy)).foregroundStyle(.white)
                    .padding(6).background(ARCTheme.liveRed).cornerRadius(4)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(zoom.sourceState == .live ? ARCTheme.live : ARCTheme.line, lineWidth: zoom.sourceState == .live ? 2 : 1))
        .cornerRadius(4)
    }
}

private struct ZoomMirrorView: NSViewRepresentable {
    let capture: WindowCapture
    @State private var box = Box()
    final class Box { var view: CaptureLayerView? }
    func makeNSView(context: Context) -> CaptureLayerView {
        if let v = box.view { return v }
        let v = capture.makeMirror(); box.view = v; return v
    }
    func updateNSView(_ view: CaptureLayerView, context: Context) {}
}


// MARK: - The sidecar (ARC Zoom over 8766), controls plan A5

/// One line: SIDECAR · MEETING · PROGRAM · HOST, words not colours alone.
private struct SidecarRow: View {
    @Environment(SidecarLink.self) private var sidecar

    var body: some View {
        let s = sidecar.snapshot
        let c = sidecar.chip
        HStack(spacing: 10) {
            item("SIDECAR", on: s.reachable, warn: false, help: s.reachable ? "ARC Zoom answering on 8766 (\(s.engine))" : "ARC Zoom not running")
            item("MEETING", on: s.inMeeting, warn: s.reachable && !s.inMeeting && s.state != "idle", help: "the sidecar's meeting state: \(s.state.isEmpty ? "unknown" : s.state)")
            item("PROGRAM", on: s.programOpen, warn: s.inMeeting && !s.programOpen, help: s.programName.map { "sidecar program shows \($0)" } ?? "no program window")
            item("HOST", on: s.amHost, warn: s.coHostNeeded, help: s.coHostNeeded ? "CO-HOST NEEDED: ask the host to promote ARC Zoom" : (s.amHost ? "ARC Zoom is the host" : "not in a meeting"))
            HStack(spacing: 5) {
                Circle().fill(c.level == .bad ? ARCTheme.liveRed : c.level == .warn ? ARCTheme.warn : c.level == .ok ? ARCTheme.readyGreen : ARCTheme.textTertiary).frame(width: 8, height: 8)
                Text(c.state).font(ARCTheme.mono(11, .bold)).foregroundStyle(c.level == .off ? ARCTheme.textSecondary : ARCTheme.text0)
            }
            .help(c.detail)
            Spacer(minLength: 0)
        }
        .frame(height: 16)
    }

    private func item(_ name: String, on: Bool, warn: Bool, help: String) -> some View {
        let colour: Color = on ? ARCTheme.readyGreen : warn ? ARCTheme.warn : ARCTheme.textTertiary
        return HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Text(name).font(ARCTheme.mono(11, .bold)).foregroundStyle(on ? ARCTheme.text0 : ARCTheme.textSecondary)
        }
        .help(help)
    }
}

/// SCREEN and ROOM AUDIO only (2026-09-20): ATTACH / LET GO, and the call's return level into the
/// room. TAKE and RETURN are the switcher's buttons above. Everything about the meeting itself is in
/// ARC Zoom's own window; LAUNCH only appears when the sidecar is not running.
private struct SidecarButtons: View {
    @Environment(SidecarLink.self) private var sidecar
    @Environment(SwitchEngine.self) private var switcher
    @Environment(WindowSource.self) private var windowSource

    private var attached: Bool { windowSource.pick?.bundleID == SidecarLink.bundleID && windowSource.phase == .attached }
    private var live: Bool { switcher.liveSource == .window && windowSource.pick?.bundleID == SidecarLink.bundleID }

    var body: some View {
        let s = sidecar.snapshot
        HStack(spacing: 8) {
            if !s.reachable {
                chip("LAUNCH ARC ZOOM", tint: ARCTheme.readyGreen) { Task { await sidecar.launch() } }
                    .help("Open /Applications/ARC Zoom.app; the meeting is started from its window")
            }
            if attached {
                chip("LET GO") { Task { await sidecar.letGo() } }
                    .disabled(live || windowSource.isBusy)
                    .help("Detach the sidecar's program window; auto-attach stays off until ATTACH")
            } else {
                chip("ATTACH", tint: s.programOpen ? ARCTheme.text0 : ARCTheme.textTertiary) { Task { await sidecar.attach() } }
                    .disabled(!s.programOpen || windowSource.isBusy || switcher.isBusy)
                    .help("Attach the sidecar's program window as the window source and arm it (happens on its own while auto-attach is on)")
            }
            if s.inMeeting, s.audioConfig != "split" {
                Text("ROOM RETURN").font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.textSecondary)
                chip("\u{2212}") { Task { await sidecar.returnLevel(delta: -10) } }
                Text(s.speakerVolume < 0 ? "--" : "\(Int(s.speakerVolume))").font(ARCTheme.mono(11, .bold)).foregroundStyle(s.speakerOutput ? ARCTheme.text0 : ARCTheme.textTertiary).frame(width: 26)
                    .help("The call's return level into the room (the sidecar's speaker output), BASIC and CONSOLE configs")
                chip("+") { Task { await sidecar.returnLevel(delta: 10) } }
                chip(s.speakerOutput ? "MUTE" : "UNMUTE", fill: s.speakerOutput ? nil : ARCTheme.liveRed) { Task { await sidecar.returnMute(s.speakerOutput) } }
                    .help(s.speakerOutput ? "Silence the call in the room" : "The call is silenced in the room; click to restore")
            }
        }
    }

    private func chip(_ label: String, tint: Color = ARCTheme.text0, fill: Color? = nil, action: @escaping () -> Void) -> some View {
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

private struct SidecarDetail: View {
    @Environment(SidecarLink.self) private var sidecar

    var body: some View {
        let s = sidecar.snapshot
        VStack(alignment: .leading, spacing: 2) {
            Text(sidecar.chip.detail).font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary)
            if s.inMeeting {
                Text("\(s.participants) in the meeting · program \(s.programName ?? "nobody") · uplink \(s.uplink ?? "?") · audio \(s.audioConfig.uppercased()) · \(s.preset.uppercased())")
                    .font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary)
            }
            if let e = sidecar.lastError {
                Text(e).font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.warn)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
