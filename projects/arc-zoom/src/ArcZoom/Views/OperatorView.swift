//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import ARCStyle

/// The operator page. One rule from ARC Presenter carried over: every state the operator needs is a
/// word, not a colour alone, and every control says what it will do to the ROOM as against the MEETING.
///
/// LAYOUT (2026-09-23, the sizing pass after Presenter 5.5.0 and Capture 3.3.0). By how often it is touched:
/// the HEADER holds what is set once and then only read (the status tiles, the PGM / MON display chips, the log
/// tail, the link health); the PICTURE ROW holds the three previews and what goes out live (WINDOWS, OWN FEED);
/// the three RAILS hold the modules. Text never shrinks below the design size (`ARCTheme.ui` is grow-only);
/// below it the console reflows (`OperatorLayout`) and a rail scrolls as the last resort.
struct OperatorView: View {
    @Environment(Sidecar.self) private var sidecar
    @Environment(DisplayManager.self) private var displays
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var uiScale: CGFloat = ARCTheme.uiScale
    /// The OUTPUTS column's natural height, measured: the picture row is never shorter than it.
    @State private var outputsH: CGFloat = 0
    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if let sdk = sidecar.engine as? SDKZoomEngine, sdk.browserSignInSince != nil {
                // A browser consent is out: without this the window looked frozen for the 5 minute wait.
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.key.fill").foregroundStyle(ARCTheme.warn)
                    Text("Waiting for Zoom sign-in in your browser. Sign in there as \(sdk.browserSignInExpected ?? "ARC Tech"), not another account, then Allow.")
                        .font(ARCTheme.ui(12, .bold)).foregroundStyle(ARCTheme.text0)
                    Spacer(minLength: 0)
                    arcChip("CANCEL", fill: ARCTheme.arcRed) { LocalCallbackServer.cancelPending() }
                }
                .padding(.vertical, 6).padding(.horizontal, 12)
                .background(ARCTheme.surfaceLight)
            }
            if let message = displays.statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(message).font(ARCTheme.ui(12, .regular)).foregroundStyle(ARCTheme.text0)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6).padding(.horizontal, 12)
                .background(ARCTheme.surfaceLight)
            }
            // ARC layout law (STYLE_GUIDE, "no accidental negative space"): ONE given, the window. The picture row
            // is as tall as the OUTPUTS column needs, or 21 % of the space, whichever is more (the operator prefers small previews;
            // at 1512 every point the row gives up is a point the rails needed, measured 2026-09-23); the previews
            // are 16:9 in that height; OUTPUTS takes the rest of the width. The rails get everything below.
            GeometryReader { g in
                let pad = ARCTheme.railPad
                let rowH = max(outputsH, (g.size.height * 0.21).rounded())
                let titleH = ARCTheme.s(28)
                // OUTPUTS holds PREVIEW now (2026-09-24): ~390 pt of chips plus a 16:9 pane and its controls. At 1512
                // the three pictures give up ~50 pt each for it (217 -> 197 wide) (the operator prefers small previews); from 1710 up the
                // height, not this floor, sets the pictures and nothing changes.
                let panelMin = ARCTheme.s(880)
                let previewW = max(ARCTheme.s(160), min((rowH - titleH) * 16 / 9, (g.size.width - panelMin - 5 * pad) / 3).rounded())
                let railsH = max(0, g.size.height - rowH - 2 * pad - ARCTheme.s(1))
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: pad) {
                        // The title is WHERE THE VIDEO GOES (2026-09-21), the outlined button is the layout,
                        // and the right of the bar is what that layout currently holds.
                        picture(.program, title: "PROGRAM", live: displays.isProgramConnected, compact: previewW < ARCTheme.s(300))
                            .frame(width: previewW)
                        picture(.gallery, title: "MON", live: displays.isConfidenceConnected, compact: previewW < ARCTheme.s(300))
                            .frame(width: previewW)
                        picture(.strip, title: "PREVIEW", live: false, compact: previewW < ARCTheme.s(300))
                            .frame(width: previewW)
                        // Drawn filling the row (no dead space under OWN FEED); measured at its natural height by
                        // a hidden copy, which is what sets the row.
                        OutputsModule(fill: true)
                            .frame(maxWidth: .infinity, maxHeight: rowH, alignment: .topLeading)
                            .background(alignment: .topLeading) {
                                OutputsModule(fill: false)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .hidden()
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in if abs(h - outputsH) > 1 { outputsH = h } }
                            }
                            .clipped()
                    }
                    .padding(pad)
                    .frame(height: rowH + 2 * pad)
                    ARCTheme.divider.frame(height: ARCTheme.s(1))
                    OperatorRails()
                        .environment(\.operatorLayout, OperatorLayout(size: CGSize(width: g.size.width, height: railsH)))
                }
            }
        }
        // Variable resolution: the whole console is rebuilt (`.id`) whenever the window crosses a scale step.
        .id(uiScale)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { applyScale(g.size) }
                .onChange(of: g.size) { _, size in applyScale(size) }
        })
        .frame(minWidth: ARCTheme.consoleMinW, minHeight: ARCTheme.consoleMinH, alignment: .topLeading)
        .background(ARCTheme.ink)
        .onAppear { WindowPlacement.install() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleWindow)) { n in
            guard let id = n.object as? String else { return }
            let title = id.prefix(1).uppercased() + id.dropFirst()
            ControlWindow.toggle(id: id, title: title, open: openWindow, dismiss: dismissWindow)
        }
    }

    /// The last lines of the show log, newest last, in the header; the glyph opens the whole log.
    private var headerLog: some View {
        let lines = ShowLog.recent(2)
        return HStack(alignment: .center, spacing: ARCTheme.s(6)) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    Text(HealthModule.trim(line))
                        .font(ARCTheme.ui(10, line.contains("ERROR") ? .bold : .regular))
                        .foregroundStyle(line.contains("ERROR") ? ARCTheme.liveRed : (i == lines.count - 1 ? ARCTheme.text0 : ARCTheme.textSecondary))
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ARCExpandButton(tip: "The whole show log, newest last; click again to close", on: ControlWindow.isOpen(title: "Log")) {
                ControlWindow.toggle(id: "log", title: "Log", open: openWindow, dismiss: dismissWindow)
            }
        }
        .padding(.horizontal, ARCTheme.s(8)).padding(.vertical, ARCTheme.s(3))
        .frame(maxWidth: .infinity)
        .background(ARCTheme.subGroup)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
        .cornerRadius(4)
    }

    /// The window against the 1920 x 1050 design, grow-only; quantised so text fields keep their state between
    /// small drags. The static is what every `ui(_:)` and `s(_:)` reads; the @State forces the rebuild.
    private func applyScale(_ size: CGSize) {
        let k = ARCTheme.scale(for: size)
        guard k != uiScale else { return }
        ARCTheme.uiScale = k
        uiScale = k
        ShowLog.log(String(format: "ui scale %.2f for %.0fx%.0f", k, size.width, size.height))
    }

    // MARK: - Header: what is set once and then only read

    private var headerBar: some View {
        VStack(spacing: 0) {
            // One row when it all fits (1710 up); otherwise the display chips drop to a second row under the tiles
            // and the log keeps the rest of the first. The tiles are fixed to their widest content, so nothing moves.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ARCTheme.s(10)) {
                    brandAndTiles
                    OutputAssignmentView()
                    headerLog.frame(minWidth: ARCTheme.s(260), idealWidth: ARCTheme.s(260), maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: ARCTheme.s(6)) {
                    HStack(spacing: ARCTheme.s(10)) {
                        brandAndTiles
                        headerLog.frame(minWidth: ARCTheme.s(200), idealWidth: ARCTheme.s(200), maxWidth: .infinity)
                    }
                    OutputAssignmentView()
                }
            }
            .padding(.horizontal, ARCTheme.s(12)).padding(.vertical, ARCTheme.s(8))
            if let sdk = sidecar.engine as? SDKZoomEngine {
                ARCTheme.divider.frame(height: ARCTheme.s(1))
                ViewThatFits(in: .horizontal) {
                    HealthStrip(sdk: sdk)
                    HealthStrip(sdk: sdk, wraps: true)
                }
                .padding(.horizontal, ARCTheme.s(12)).padding(.vertical, ARCTheme.s(5))
            }
        }
        .background(ARCTheme.surface)
    }

    private var brandAndTiles: some View {
        HStack(spacing: ARCTheme.s(8)) {
            Text("ARC ZOOM").font(ARCTheme.ui(16, .heavy)).foregroundStyle(ARCTheme.text0).fixedSize()
            ARCStatusTile(name: "ENGINE", state: sidecar.engineKind.uppercased(),
                          level: sidecar.engineKind == "sdk" ? .ok : .warn, widest: ("ENGINE", "FAKE"))
                .help(sidecar.engineKind == "sdk" ? "The Zoom Meeting SDK: real meetings" : "The rehearsal engine: synthetic participants, nothing reaches Zoom")
            ARCStatusTile(name: "MEETING", state: stateWord, level: stateLevel, widest: ("MEETING", "RECONNECTING"))
                .help("OUT: no meeting · JOINING · IN · RECONNECTING: the network dropped, the SDK is getting it back · FAILED: see the log")
            ARCStatusTile(name: "SHARE", state: sidecar.isSharing ? "SENDING" : "OFF", level: sidecar.isSharing ? .ok : .off, widest: ("SHARE", "SENDING"))
                .help("Whether ARC Zoom is sharing into the meeting (SHARE module)")
            if let sdk = sidecar.engine as? SDKZoomEngine {
                ARCStatusTile(name: "REC", state: sdk.recordingStatus, level: sdk.recordingStatus == "REC" ? .bad : (sdk.recordingStatus == "OFF" ? .off : .warn), widest: ("REC", "CONVERTING"))
                    .help("Recording: REC / CLOUD REC / PAUSED / CONVERTING, or OFF (MEETING > RECORD)")
                ARCStatusTile(name: "HOST", state: sdk.amHost ? "ARC ZOOM" : (sdk.amCoHost ? "CO-HOST" : (sdk.coHostNeeded ? "NEEDED" : "--")),
                              level: sdk.amHost || sdk.amCoHost ? .ok : (sdk.coHostNeeded ? .warn : .off), widest: ("HOST", "ARC ZOOM"))
                    .help("ARC ZOOM: the sidecar hosts · CO-HOST: promoted in someone else's meeting · NEEDED: ask the host to promote ARC Zoom")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Pictures (what the room gets, drawn from the same frames as the windows)

    /// `compact`: a preview under 300 pt (a 1512 MacBook gives ~200). The layout menu drops its "LAYOUT" prefix
    /// and gives way to the width, truncating the preset's name, so the bar never pushes the next preview along
    /// (2026-09-23: "MON LAYOUT SHARE + STRIP" was 250 pt over a 200 pt preview).
    private func picture(_ kind: LayoutWindow.Kind, title: String, live: Bool, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: ARCTheme.s(6)) {
                Text(title).font(ARCTheme.ui(12, .heavy)).foregroundStyle(live ? ARCTheme.live : ARCTheme.text0).fixedSize()
                    .help("\(title): \(layoutInfo(kind))")
                sceneMenu(kind, compact: compact)
                Spacer(minLength: 0)
                // Whole or not at all: on a 1512 MacBook it came out as "no s…" (2026-09-23). The tooltip always has it.
                ViewThatFits(in: .horizontal) {
                    Text(layoutInfo(kind))
                        .font(ARCTheme.ui(11, .regular)).foregroundStyle(ARCTheme.textSecondary)
                        .lineLimit(1).fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                .layoutPriority(-1)
            }
            TileMirror(kind: kind)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(live ? ARCTheme.live : ARCTheme.line, lineWidth: live ? 2 : 1))
                .overlay(alignment: .topTrailing) {
                    if live { Text("ON AIR").font(ARCTheme.ui(11, .heavy)).foregroundStyle(.white).padding(.horizontal, ARCTheme.s(6)).padding(.vertical, ARCTheme.s(2)).background(ARCTheme.liveRed).cornerRadius(3).fixedSize().padding(8) }
                }
                .cornerRadius(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What the chosen layout holds right now, for the right end of the bar: the speaker's name, how
    /// many are in the gallery or strip, whether anyone is sharing. One entry per element, in the
    /// layout's own order, so the text reads as the picture does.
    private func layoutInfo(_ kind: LayoutWindow.Kind) -> String {
        var seen = Set<OutputScene.Element>()
        return sidecar.scene(for: kind).elements.filter { seen.insert($0).inserted }.map { element -> String in
            let ids = sidecar.people(for: element)
            switch element {
            case .speaker:
                return ids.first.flatMap { id in sidecar.roster.first { $0.id == id }?.displayName } ?? "no speaker"
            case .gallery: return "\(ids.count) in gallery"
            case .strip: return "\(ids.count) in strip"
            case .share: return ids.isEmpty ? "no share" : "share on"
            case .selfView: return ids.isEmpty ? "camera off" : "self view"
            case .spotlight: return ids.isEmpty ? "nobody spotlit" : "\(ids.count) spotlit"
            }
        }.joined(separator: " · ")
    }

    /// The layout, as one clearly outlined button carrying the current preset's name. The title
    /// beside it says where the picture goes; the text at the far end says what the preset holds.
    private func sceneMenu(_ kind: LayoutWindow.Kind, compact: Bool) -> some View {
        // Its own width when that fits, else whatever the bar has left (never under 60 pt, the name truncates).
        // The width goes on the MENU: AppKit draws a borderless menu's label and ignores a frame on it.
        ViewThatFits(in: .horizontal) {
            sceneMenuBox(kind, compact: compact, width: nil)
            sceneMenuBox(kind, compact: compact, width: .infinity)
        }
        .layoutPriority(1)
    }

    private func sceneMenuBox(_ kind: LayoutWindow.Kind, compact: Bool, width: CGFloat?) -> some View {
        Menu {
            ForEach(OutputScene.presets) { sc in
                Button {
                    sidecar.setScene(sc.name, for: kind)
                } label: {
                    HStack { if sidecar.scene(for: kind) == sc { Image(systemName: "checkmark") }; Text(sc.name) }
                }
            }
        } label: {
            // ONE Text: the borderless menu style flattens its label to a title, so a second Text or
            // any background on the label never draws (measured: "LAYOUT" alone, no box, no name).
            Text(compact ? sidecar.scene(for: kind).name : "LAYOUT  \(sidecar.scene(for: kind).name)")
                .font(ARCTheme.ui(11, .bold)).foregroundStyle(ARCTheme.text0).lineLimit(1).truncationMode(.tail)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).tint(ARCTheme.text1)
        .fixedSize(horizontal: width == nil, vertical: true)
        .frame(minWidth: width == nil ? nil : ARCTheme.s(60), maxWidth: width, alignment: .leading)
        // The box goes on the MENU, not the label: that is what makes it read as a button.
        .padding(.horizontal, ARCTheme.s(8)).padding(.vertical, ARCTheme.s(3))
        .background(ARCTheme.subGroup)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.text1, lineWidth: 1))
        .cornerRadius(4)
        .help("Choose what this picture shows: the speaker, the gallery, the strip, the share, or a combination")
    }

    private var stateWord: String {
        switch sidecar.state {
        case .idle: return "OUT"
        case .joining: return "JOINING"
        case .inMeeting: return "IN"
        case .reconnecting: return "RECONNECTING"
        case .failed: return "FAILED"
        }
    }

    private var stateLevel: ARCStatusLevel {
        switch sidecar.state {
        case .inMeeting: return .ok
        case .joining, .reconnecting: return .warn
        case .failed: return .bad
        case .idle: return .off
        }
    }

}

/// The three rails, dealt by `OperatorLayout`. Every rail ends in the module whose CONTENT grows (a list, a
/// transcript), declared with `railTail` so the fit test reads its useful minimum, not its whole list.
struct OperatorRails: View {
    #if DEBUG
    /// What the rails were last given, rails area only (WindowSizingTests reads it after a layout pass).
    nonisolated(unsafe) static var lastSize: CGSize = .zero
    #endif
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                if i > 0 { ARCTheme.divider.frame(width: ARCTheme.s(1)) }
                OperatorRail(column: i)
                    .padding(ARCTheme.railPad)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        #if DEBUG
        .onGeometryChange(for: CGSize.self) { $0.size } action: { Self.lastSize = $0 }
        #endif
    }
}

struct OperatorRail: View {
    let column: Int
    /// false: the bare column, for the fit test to measure (a scrolling rail always "fits").
    var scrolls = true
    @Environment(Sidecar.self) private var sidecar
    @Environment(\.operatorLayout) private var layout

    var body: some View {
        let stack = VStack(alignment: .leading, spacing: ARCTheme.railPad) { modules }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        if scrolls { stack.scrollsWhenShort() } else { stack }
    }

    /// Wide (rails of 600 pt and up): people · what goes out · settings and sound, as designed on 2026-09-20.
    /// Narrow (a 1512 or 1710 MacBook; measured 2026-09-23, WindowSizingTests): SETTINGS + SOUND alone fill the
    /// third rail (~530 of ~570 pt), so VIDEO moves under SHARE with a short RECEIVING list and CAPTIONS closes
    /// that rail. CHAT is a meeting's: before one it is not drawn, and PARTICIPANTS needs less room.
    @ViewBuilder private var modules: some View {
        if let sdk = sidecar.engine as? SDKZoomEngine {
            let inMeeting = sidecar.state == .inMeeting
            switch (column, layout.narrow) {
            case (0, _):
                MeetingModule()
                if inMeeting || !layout.narrow { ChatModule(sdk: sdk) }
                RosterModule().railTail(Self.rosterTail)
            case (1, false):
                ShareModule(sdk: sdk)
                CaptionsModule(sdk: sdk, flexible: true).railTail(Self.captionsTail)
            case (1, true):
                ShareModule(sdk: sdk)
                VideoModule(sdk: sdk, flexible: false)
                CaptionsModule(sdk: sdk, flexible: true).railTail(Self.captionsTail)
            case (_, false):
                SettingsQuickRow(sdk: sdk)
                SoundModule(sdk: sdk)
                // VIDEO settings and the camera pick take the tail of this rail (2026-09-21); its
                // RECEIVING list is the content that grows.
                VideoModule(sdk: sdk).railTail(Self.videoTail)
            default:
                SettingsQuickRow(sdk: sdk)
                // No list in this rail: SOUND's bracket runs to the bottom rather than leave a dead tail.
                SoundModule(sdk: sdk, fills: true)
            }
        } else if column == 0 {
            MeetingModule()
            RosterModule().railTail(Self.rosterTail)
            if let e = sidecar.errorLine, !e.isEmpty {
                Text(e).font(ARCTheme.ui(11, .regular)).foregroundStyle(ARCTheme.warn).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension OperatorRail {
    /// Each tail's useful minimum: never less than the module's own minimum (its header rows, the list at nil),
    /// or the fit test believes a rail that then runs past the window. WindowSizingTests checks each one.
    static var rosterTail: CGFloat { ARCTheme.s(150) }
    static var captionsTail: CGFloat { ARCTheme.s(120) }
    static var videoTail: CGFloat { ARCTheme.s(190) }
}

extension View {
    /// A rail's last module: takes the height left, and tells the fit test `minimum` is enough to be useful.
    func railTail(_ minimum: CGFloat) -> some View {
        frame(minHeight: minimum, idealHeight: minimum, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - OUTPUTS (beside the previews): what leaves this Mac live

/// The windows on the displays and our own feed into the call. The display ASSIGNMENT is set once per show and
/// sits in the header now (2026-09-23); this module is only what the operator flips during it.
struct OutputsModule: View {
    /// Drawn filling the picture row (true), or at its natural height for the measurement (false).
    var fill: Bool
    @Environment(Sidecar.self) private var sidecar
    @Environment(DisplayManager.self) private var displays

    var body: some View {
        // WINDOWS and OWN FEED at their natural width on the left; PREVIEW takes the rest of the panel (
        // 2026-09-24: "lots of unused space"). Only the left column is measured (fill: false): PREVIEW fills
        // whatever height the row has and never sets it, so the rails keep every point they had.
        HStack(alignment: .top, spacing: ARCTheme.s(8)) {
            // A set width, not fixedSize: FlowRow's ideal width under fixedSize came out ~620 pt for ~420 pt of chips and
            // pushed the console past the window (2026-09-24 shots). 430 holds the widest OWN FEED row on one line.
            outputsColumn.frame(width: Self.columnW)
            if fill { PreviewModule().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
        }
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .arcModule(title: "OUTPUTS", tint: ARCTheme.secCrimson, scale: ARCTheme.uiScale)
    }

    static var columnW: CGFloat { ARCTheme.s(430) }

    private var outputsColumn: some View {
        VStack(alignment: .leading, spacing: ARCTheme.s(6)) {
            FlowRow(spacing: ARCTheme.s(6)) {
                ForEach(LayoutWindow.Kind.allCases, id: \.self) { kind in
                    let open = sidecar.isOpen(kind), black = sidecar.isBlack(kind)
                    let held = kind == .program ? displays.isProgramConnected : (kind == .gallery ? displays.isConfidenceConnected : false)
                    let word = held ? (black ? "BLACK" : "ON AIR") : (open ? "OPEN" : "OFF")
                    arcChip("\(kind.rawValue.uppercased())  \(word)",
                            tint: held ? (black ? .white : ARCTheme.live) : (open ? ARCTheme.readyGreen : ARCTheme.text0),
                            fill: held && black ? ARCTheme.liveRed : nil) {
                        (open && !black) ? sidecar.close(kind) : sidecar.open(kind)
                    }
                    .help("\(kind.title): \(Self.help(for: kind)) Held on a display: OFF is BLACK in place.")
                }
            }
            .arcSubGroup("windows")
            selfFeedRow
                .frame(maxHeight: fill ? .infinity : nil, alignment: .topLeading)
                .arcSubGroup("own feed into the call")
                .frame(maxHeight: fill ? .infinity : nil, alignment: .top)
        }
        .frame(maxHeight: fill ? .infinity : nil, alignment: .topLeading)
    }

    /// The sidecar's own feed into the call: SELF VIEW (its tile in GALLERY / STRIP and the previews),
    /// MIC, CAMERA, BLUR. State is read back from the roster and the SDK's background list, never assumed.
    private var selfFeedRow: some View {
        let sdk = sidecar.engine as? SDKZoomEngine
        let inMeeting = sidecar.state == .inMeeting
        let me = sidecar.roster.first { $0.isMe }
        let joined = me?.audioJoined == true, micOn = joined && me?.audioOn == true, camOn = me?.videoOn == true, blur = sdk?.soundSample.blur ?? false
        return FlowRow(spacing: ARCTheme.s(6)) {
            arcChip(sidecar.selfViewOn ? "SELF VIEW ON" : "SELF VIEW OFF", fill: sidecar.selfViewOn ? ARCTheme.secBlue : nil) { sidecar.selfViewOn.toggle() }
                .help("Our own camera in GALLERY / STRIP and the previews. Costs one more video subscription while on.")
            if let sdk, inMeeting {
                // Three states, not two: NO AUDIO (never joined the meeting audio: nothing in, nothing out),
                // MIC MUTED (joined, muted), MIC OPEN. "Not muted" alone lit MIC OPEN on a silent sidecar.
                arcChip(!joined ? "NO AUDIO" : (micOn ? "MIC OPEN" : "MIC MUTED"), tint: micOn ? ARCTheme.readyGreen : ARCTheme.text0, fill: micOn ? nil : ARCTheme.liveRed) { _ = sdk.setOwnAudio(on: !micOn) }
                    .help(!joined ? "The sidecar has not joined the meeting audio: join it and open the mic" : (micOn ? "Mute the sidecar's microphone in the call" : "Open the sidecar's microphone into the call"))
                arcChip(camOn ? "CAMERA ON" : "CAMERA OFF", tint: camOn ? ARCTheme.readyGreen : ARCTheme.text0, fill: camOn ? nil : ARCTheme.liveRed) { _ = sdk.setOwnVideo(on: !camOn) }
                    .help(camOn ? "Stop sending the sidecar's camera" : "Send the sidecar's camera")
                arcChip(blur ? "BLUR ON" : "BLUR OFF", fill: blur ? ARCTheme.secBlue : nil) { _ = sdk.setBlur(!blur) }
                    .help("Background blur on the sidecar's own camera (Zoom's virtual background); remembered per meeting")
                    .disabled(!sdk.blurSupported)
            }
        }
    }

    static func help(for kind: LayoutWindow.Kind) -> String {
        switch kind {
        case .program: return "one participant, whoever PROGRAM points at. This is the window Presenter takes for the room's screen."
        case .gallery: return "every remote with video, tiled as large as they fit."
        case .strip:   return "every remote in one wide row, for a band across the top of Presenter's program."
        }
    }

}

// MARK: - MEETING (rail 0): host, join, pre-flight; in a meeting the invite, RECORD and END

struct MeetingModule: View {
    @State private var endArmed = false
    @Environment(Sidecar.self) private var sidecar
    @Environment(\.operatorLayout) private var layout
    @State private var meeting = ""
    @State private var passcode = ""
    @State private var displayName = "ARC Tech"
    @FocusState private var joinFocused: Bool

    var body: some View { meetingModule.onReceive(NotificationCenter.default.publisher(for: .focusJoin)) { _ in joinFocused = true } }

    private var meetingModule: some View {
        let sdk = sidecar.engine as? SDKZoomEngine
        return VStack(alignment: .leading, spacing: 6) {
            if sidecar.engineKind == "fake" {
                Text("Rehearsal engine: the participants below are synthetic. CREATE MEETING switches to the Zoom SDK and starts the ARC Tech meeting as host.")
                    .font(ARCTheme.ui(11, .regular)).foregroundStyle(ARCTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if sidecar.state == .inMeeting, let sdk, let n = sdk.invite.number {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 12) {
                            HStack(spacing: 6) { arcLabel("MEETING"); Text(Self.grouped(n)).font(ARCTheme.ui(14, .bold)).foregroundStyle(ARCTheme.text0).textSelection(.enabled).fixedSize() }
                            if let pc = sdk.invite.passcode {
                                HStack(spacing: 6) { arcLabel("PASSCODE"); Text(pc).font(ARCTheme.ui(14, .bold)).foregroundStyle(ARCTheme.text0).textSelection(.enabled).fixedSize() }
                            }
                            Spacer(minLength: 0)
                            chip("COPY") {
                                let text = "ARC Tech Zoom\nMeeting \(n)\(sdk.invite.passcode.map { "\nPasscode \($0)" } ?? "")\(sdk.invite.url.map { "\n\($0)" } ?? "")"
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                            }
                            .help("Meeting number, passcode and link to the clipboard")
                        }
                        if let url = sdk.invite.url {
                            Text(url).font(ARCTheme.ui(10, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }
                .arcSubGroup("invite")
                recordRow(sdk).arcSubGroup("record")
                HStack(spacing: 8) {
                    // Two clicks: the first arms for 3 s, the second ends for everyone (audit P1).
                    chip(endArmed ? "CONFIRM END" : "END MEETING", fill: ARCTheme.liveRed) {
                        if endArmed { endArmed = false; Task { await sidecar.endMeeting() } }
                        else { endArmed = true; DispatchQueue.main.asyncAfter(deadline: .now() + 3) { endArmed = false } }
                    }
                    .help("Ends the meeting for every participant and stops any cloud recording; click twice")
                    Spacer(minLength: 0)
                }
            } else {
                // HOST and JOIN on the left; PRE-FLIGHT on the right (2026-09-21): the two audio
                // checks that only make sense BEFORE the meeting, since in one the mic and speaker
                // carry the call.
                ThisMacModule()
                // Narrow rail (a 1512 MacBook): PRE-FLIGHT goes under JOIN, one row wide; beside it, JOIN's three
                // fields wrapped to three lines in a 200 pt column.
                let beside = !layout.narrow
                (beside ? AnyLayout(HStackLayout(alignment: .top, spacing: ARCTheme.s(6))) : AnyLayout(VStackLayout(alignment: .leading, spacing: ARCTheme.s(6)))) {
                    VStack(alignment: .leading, spacing: ARCTheme.s(6)) {
                        HStack(spacing: 8) {
                            chip(sidecar.isCreatingMeeting ? "CREATING\u{2026}" : "CREATE MEETING", tint: ARCTheme.readyGreen) { Task { _ = await sidecar.createMeeting() } }
                                .disabled(sidecar.isCreatingMeeting || sidecar.state == .joining)
                                .help("Start the ARC Tech personal meeting with ARC Zoom as host, on the Zoom SDK")
                            Text(sidecar.state == .joining ? "joining\u{2026}" : "ARC Tech's personal meeting, ARC Zoom as host").font(ARCTheme.ui(11, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .arcSubGroup("host")
                        FlowRow(spacing: ARCTheme.s(8)) {
                            field("MEETING NUMBER", text: $meeting, width: 140).focused($joinFocused)
                            field("PASSCODE", text: $passcode, width: 90)
                            field("AS", text: $displayName, width: 110)
                            chip("JOIN") {
                                Task { _ = await sidecar.engine.join(meeting: meeting, passcode: passcode.isEmpty ? nil : passcode, displayName: displayName) }
                            }
                            .disabled(sidecar.state == .joining || meeting.isEmpty)
                            .help("Join someone else's meeting; the host makes ARC Zoom co-host once it is in")
                        }
                        .arcSubGroup("join someone else's meeting")
                    }
                    preflightBox(row: !beside)
                        .frame(width: beside ? ARCTheme.s(250) : nil)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcModule(title: "MEETING", tint: ARCTheme.secBlue, scale: ARCTheme.uiScale)
    }

    /// TEST MIC and TEST AUDIO OUT, each a timed sequence (AudioCheck): the running one reads STOP, the
    /// other waits; the meter shows the live level; the line beneath is the step, then the result.
    /// `row`: the two chips and the meter on one line (a narrow rail, where the box sits full width).
    private func preflightBox(row: Bool) -> some View {
        let check = sidecar.audioCheck
        return VStack(alignment: .leading, spacing: ARCTheme.s(6)) {
            HStack(spacing: ARCTheme.s(6)) {
                chip(check.isRunning(.mic) ? "STOP" : "TEST MIC", fill: check.isRunning(.mic) ? ARCTheme.liveRed : nil) {
                    if check.isRunning(.mic) { check.stop() } else { check.start(.mic, sidecar: sidecar) }
                }
                .disabled(check.isRunning(.out))
                .help("Listen on the call's mic for \(AudioCheck.listenSeconds) s with the meter, then play it back on the call's speaker. Pass = the mic heard you above −40 dBFS")
                chip(check.isRunning(.out) ? "STOP" : "TEST AUDIO OUT", fill: check.isRunning(.out) ? ARCTheme.liveRed : nil) {
                    if check.isRunning(.out) { check.stop() } else { check.start(.out, sidecar: sidecar) }
                }
                .disabled(check.isRunning(.mic))
                .help("Zoom's test tone on the call's speaker for \(AudioCheck.toneSeconds) s (our own 1 kHz tone if the SDK refuses). The room hearing it is the pass; this check cannot listen to the room")
                if row { Meter(level: check.level).frame(height: ARCTheme.s(8)).frame(maxWidth: .infinity) }
            }
            if !row { Meter(level: check.level).frame(height: ARCTheme.s(8)) }
            Text(check.step.isEmpty ? (check.result ?? "run both before the meeting: the mic and speaker the call will use") : check.step)
                .font(ARCTheme.ui(10, .regular))
                .foregroundStyle(resultColour(check))
                .fixedSize(horizontal: false, vertical: true)
        }
        .arcSubGroup("pre-flight")
    }

    private func resultColour(_ check: AudioCheck) -> SwiftUI.Color {
        switch check.phase {
        case .running: return ARCTheme.text0
        case .done(_, let pass): return pass ? ARCTheme.readyGreen : ARCTheme.warn
        case .idle: return ARCTheme.textSecondary
        }
    }

    /// Recording, in MEETING: it is a meeting-level fact (was its own module with a dead tail).
    private func recordRow(_ sdk: SDKZoomEngine) -> some View {
        let st = sdk.recordingStatus
        let active = st == "REC" || st == "CLOUD REC" || st == "PAUSED"
        return HStack(spacing: 8) {
            if active {
                chip("STOP", fill: ARCTheme.liveRed) { _ = sdk.stopRecording() }
                chip(st == "PAUSED" ? "RESUME" : "PAUSE") { _ = st == "PAUSED" ? sdk.resumeRecording() : sdk.pauseRecording() }
            } else {
                chip("REC", tint: ARCTheme.liveRed) { _ = sdk.startRecording() }.disabled(st == "CONVERTING")
                    .help("Cloud recording while the outputs run raw video (the SDK's local recorder is busy with it); local MP4 only with the outputs closed")
            }
            HStack(spacing: 5) {
                Circle().fill(st == "REC" || st == "CLOUD REC" ? ARCTheme.liveRed : (st == "PAUSED" || st == "CONVERTING" ? ARCTheme.warn : (st == "FAIL" || st == "DISK FULL" ? ARCTheme.liveRed : ARCTheme.textTertiary))).frame(width: ARCTheme.s(8), height: ARCTheme.s(8))
                Text(st + (st == "CONVERTING" && sdk.mp4Progress >= 0 ? " \(sdk.mp4Progress)%" : "")).font(ARCTheme.ui(11, .heavy)).foregroundStyle(st == "REC" || st == "CLOUD REC" ? ARCTheme.liveRed : ARCTheme.text0).fixedSize()
            }
            Text(sdk.lastRecordingPath.map { ($0 as NSString).lastPathComponent } ?? "cloud, to the house account").font(ARCTheme.ui(10, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                .help(sdk.lastRecordingPath ?? "Cloud recording needs the portal's Recording > Cloud recording ON")
            Spacer(minLength: 0)
        }
    }

    /// Ten digits in groups of 3, 3 and 4, the way Zoom prints it.
    static func grouped(_ n: String) -> String {
        let d = n.filter(\.isNumber)
        guard d.count == 10 || d.count == 11 else { return n }
        let a = d.prefix(3), b = d.dropFirst(3).prefix(3), c = d.dropFirst(6)
        return "\(a) \(b) \(c)"
    }

    private func field(_ label: String, text: Binding<String>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(ARCTheme.ui(9, .heavy)).foregroundStyle(ARCTheme.textSecondary)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(ARCTheme.ui(13, .regular))
                .foregroundStyle(ARCTheme.text0)
                .padding(.horizontal, ARCTheme.s(8)).padding(.vertical, ARCTheme.s(5))
                .background(ARCTheme.appGrey)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
                .cornerRadius(4)
                .frame(width: width)
        }
    }

    private func chip(_ label: String, tint: Color = ARCTheme.text0, fill: Color? = nil, action: @escaping () -> Void) -> some View { arcChip(label, tint: tint, fill: fill, action: action) }
}

// MARK: - PARTICIPANTS (rail 0's tail)

struct RosterModule: View {
    @Environment(Sidecar.self) private var sidecar
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View { rosterModule }

    private var rosterModule: some View {
        let people = sidecar.orderedRoster
        let rowH: CGFloat = ARCTheme.s(26), gap: CGFloat = ARCTheme.s(6)
        let sdk = sidecar.engine as? SDKZoomEngine
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                arcLabel("PROGRAM FOLLOWS")
                ForEach(Sidecar.ProgramMode.allCases, id: \.self) { mode in
                    chip(mode.rawValue.uppercased(), fill: sidecar.programMode == mode ? ARCTheme.secBlue : nil) { sidecar.setProgramMode(mode) }
                }
                Spacer(minLength: 0)
                Text("\(people.count) IN").font(ARCTheme.ui(10, .heavy)).foregroundStyle(ARCTheme.textSecondary).fixedSize()
                ARCExpandButton(tip: "All participants: VIP pins, co-host, waiting room; click again to close", on: ControlWindow.isOpen(title: "Participants")) {
                    ControlWindow.toggle(id: "participants", title: "Participants", open: openWindow, dismiss: dismissWindow)
                }
                if sidecar.engineKind == "fake", sidecar.state == .inMeeting {
                    chip("ADD PERSON") { (sidecar.engine as? FakeZoomEngine)?.addParticipant() }
                }
            }
            .arcSubGroup()
            if let sdk, !sdk.waitingRoomIDs.isEmpty {
                let waiting = sdk.waitingRoom()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(waiting) { p in
                        HStack(spacing: 8) {
                            Circle().fill(ARCTheme.warn).frame(width: ARCTheme.s(8), height: ARCTheme.s(8))
                            Text(p.displayName).font(ARCTheme.ui(13, .bold)).foregroundStyle(ARCTheme.text0).frame(width: ARCTheme.s(208), alignment: .leading).lineLimit(1).truncationMode(.middle)
                            chip("ADMIT", tint: ARCTheme.readyGreen) { Task { _ = await sdk.admit(p.id) } }
                            Spacer(minLength: 0)
                        }
                        .frame(height: rowH)
                    }
                    chip("ADMIT ALL", tint: ARCTheme.readyGreen) { Task { _ = await sdk.admit(nil) } }
                }
                .arcSubGroup("waiting room  \(waiting.count)")
            }
            // The list takes the rail's remaining height: a big meeting scrolls here, never pushes anything.
            Group {
                if people.isEmpty {
                    Text(sidecar.state == .inMeeting ? "nobody else in the meeting yet" : "not in a meeting")
                        .font(ARCTheme.ui(11, .regular)).foregroundStyle(ARCTheme.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: gap) { ForEach(people) { p in rosterRow(p) } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .arcSubGroup("in the meeting")
            if let sdk, !sdk.handQueue.isEmpty || !sdk.reactions.filter({ Date().timeIntervalSince($0.time) < 20 }).isEmpty {
                FlowRow(spacing: ARCTheme.s(6)) {
                    ForEach(Array(sdk.handQueue.enumerated()), id: \.element.id) { i, h in
                        HStack(spacing: 4) {
                            Text("\(i + 1). \(sdk.participants.first { $0.id == h.id }?.displayName ?? "\(h.id)")").font(ARCTheme.ui(11, .bold)).foregroundStyle(ARCTheme.text0).lineLimit(1).frame(maxWidth: ARCTheme.s(160))
                            chip("LOWER") { _ = sdk.lowerHand(h.id) }
                        }
                    }
                    if !sdk.handQueue.isEmpty { chip("LOWER ALL") { _ = sdk.lowerAllHands() } }
                    let recent = sdk.reactions.filter { Date().timeIntervalSince($0.time) < 20 }
                    if !recent.isEmpty {
                        Text(recent.suffix(8).map(\.type).joined(separator: " ")).font(.system(size: 14)).fixedSize()
                            .help(recent.suffix(8).map { "\($0.name) \($0.type)" }.joined(separator: ", "))
                    }
                }
                .arcSubGroup("hands  \(sdk.handQueue.count)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .arcModule(title: "PARTICIPANTS", tint: ARCTheme.secBlue, scale: ARCTheme.uiScale)
    }

    private func rosterRow(_ p: Participant) -> some View {
        let isProgram = p.id == sidecar.programID
        let sdk = sidecar.engine as? SDKZoomEngine
        let talking = sdk?.talking.contains(p.id) ?? false
        let tag = p.isHost ? "HOST" : (p.isMe ? "ME" : (p.isCoHost ? "CO-HOST" : (talking ? "TALKING" : (sidecar.isVIP(p.id) ? "★ VIP" : ""))))
        return HStack(spacing: ARCTheme.s(6)) {
            Circle().fill(talking ? ARCTheme.readyGreen : (p.videoOn ? ARCTheme.text0 : ARCTheme.textTertiary)).frame(width: ARCTheme.s(8), height: ARCTheme.s(8))
            Text(p.displayName)
                .font(ARCTheme.ui(13, .bold))
                .foregroundStyle(ARCTheme.text0)
                .lineLimit(1).truncationMode(.middle)
                // The NAME gives, never the verbs: a fixed 150 pt name made the row 530 pt, wider than a
                // 1512 MacBook's rail (2026-09-23); the chips stay whole and the name truncates in the middle.
                .frame(minWidth: ARCTheme.s(64), idealWidth: ARCTheme.s(170), maxWidth: ARCTheme.s(200), alignment: .leading)
                .layoutPriority(-1)
                .help(p.displayName)
            Text(tag)
                .font(ARCTheme.ui(10, .heavy)).foregroundStyle(talking ? ARCTheme.readyGreen : (tag == "★ VIP" ? ARCTheme.secOrange : ARCTheme.textSecondary))
                .frame(width: ARCTheme.s(58), alignment: .leading).lineLimit(1)

            chip(isProgram ? "ON PROGRAM" : "TO PROGRAM",
                 fill: isProgram ? ARCTheme.liveRed : nil) { sidecar.setProgram(p.id) }
                .disabled(p.isMe)
                .help(p.isMe ? "The room does not need to see the operator" : "Put \(p.displayName) on the room's program monitor. Local: the meeting is not told.")

            chip(p.isSpotlighted ? "SPOTLIT" : "SPOTLIGHT",
                 fill: p.isSpotlighted ? ARCTheme.secBlue : nil) {
                Task { await sidecar.spotlight(p.id, on: !p.isSpotlighted) }
            }
            .help("Spotlight in the MEETING: every attendee sees \(p.displayName), not just the room.")

            chip(p.audioOn ? "MUTE" : "UNMUTE") { Task { _ = await sidecar.engine.mute(p.id, on: p.audioOn) } }

            Spacer(minLength: 0)
        }
        .frame(height: ARCTheme.s(26))
    }

    private func chip(_ label: String, tint: Color = ARCTheme.text0, fill: Color? = nil, action: @escaping () -> Void) -> some View { arcChip(label, tint: tint, fill: fill, action: action) }
}


/// A preview of one output kind, the Sidecar's own TileHostView drawn from the same frames.
struct TileMirror: NSViewRepresentable {
    let kind: LayoutWindow.Kind
    @Environment(Sidecar.self) private var sidecar
    func makeNSView(context: Context) -> TileHostView { sidecar.mirror(for: kind) }
    func updateNSView(_ view: TileHostView, context: Context) {}
}


struct SelfMirror: NSViewRepresentable {
    @Environment(Sidecar.self) private var sidecar
    func makeNSView(context: Context) -> TileHostView { sidecar.selfMirror() }
    func updateNSView(_ view: TileHostView, context: Context) {}
}
