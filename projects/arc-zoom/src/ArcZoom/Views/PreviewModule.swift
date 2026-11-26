//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ARCStyle

/// PREVIEW, in the OUTPUTS panel beside WINDOWS and OWN FEED (2026-09-24: the panel had "lots of unused
/// space"; "i would like a way to preview the camera before sharing. this should apply to the video file
/// playback as well"). The pane on the left is what SHARE THIS sends; the controls on the right in three rows:
/// SOURCE + SHARE, then the transport (file) or the AUDIO IN (camera), then the scrubber (file) or the input's
/// level (camera). The sound meter is the bar along the pane's foot; ON AIR sits on the pane while it is shared.
/// No sub-group label: the row is 21 % of the window and a label would cost the pane its height at 1512.
struct PreviewModule: View {
    @Environment(Sidecar.self) private var sidecar

    #if DEBUG
    /// What the controls column was given, and the pane (WindowSizingTests reads them after a layout pass).
    nonisolated(unsafe) static var lastControls: CGSize = .zero
    nonisolated(unsafe) static var lastPane: CGSize = .zero
    #endif

    var body: some View {
        let p = sidecar.preview
        // The pane is 16:9 at the height the row gives, never so wide that the controls get under their 200 pt;
        // the controls take the rest. Sized here, not by aspectRatio(.fit) inside a flexible frame: that frame
        // stretched while the picture letterboxed inside it (WindowSizingTests caught it, 2026-09-24).
        GeometryReader { g in
            let gap = ARCTheme.s(8), controlsMin = ARCTheme.s(200)
            let paneW = max(ARCTheme.s(96), min(g.size.height * 16 / 9, g.size.width - controlsMin - gap)).rounded(.down)
            HStack(alignment: .top, spacing: gap) {
                PreviewPaneBox()
                    .frame(width: paneW, height: (paneW * 9 / 16).rounded(.down))
                    #if DEBUG
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { Self.lastPane = $0 }
                    #endif
                PreviewControls()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    #if DEBUG
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { Self.lastControls = $0 }
                    #endif
            }
        }
        .frame(minWidth: ARCTheme.s(96 + 8 + 200), maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .arcSubGroup()
        .help(p.note ?? "")
    }
}

/// The pane with its overlays: PREVIEW tag, ON AIR, the centre word, the sound meter along the foot.
struct PreviewPaneBox: View {
    @Environment(Sidecar.self) private var sidecar
    var body: some View { pane(sidecar.preview) }


    // MARK: The pane

    private func pane(_ p: PreviewPlayer) -> some View {
        PreviewPane(player: p, source: p.source)
            .overlay(alignment: .topLeading) {
                Text("PREVIEW").font(ARCTheme.ui(10, .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, ARCTheme.s(5)).padding(.vertical, ARCTheme.s(1))
                    .background(Color.black.opacity(0.6)).cornerRadius(3).padding(ARCTheme.s(4)).fixedSize()
            }
            .overlay(alignment: .topTrailing) {
                if p.onAir {
                    Text("ON AIR").font(ARCTheme.ui(11, .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, ARCTheme.s(6)).padding(.vertical, ARCTheme.s(2))
                        .background(ARCTheme.liveRed).cornerRadius(3).padding(ARCTheme.s(4)).fixedSize()
                        .help(p.shareMode == "file-sdk" ? "Shared: Zoom is playing the file itself, the transport here does not reach the call" : "Shared: the call sees this picture")
                }
            }
            .overlay { centreWord(p) }
            .overlay(alignment: .bottom) {
                // The sound meter along the foot: the file's track, or the camera's AUDIO IN (what the call gets).
                GeometryReader { g in
                    Rectangle().fill(p.level > 0.94 ? ARCTheme.liveRed : (p.level > 0.76 ? ARCTheme.warn : ARCTheme.readyGreen))
                        .frame(width: g.size.width * CGFloat(p.level), height: ARCTheme.s(4))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(p.onAir ? ARCTheme.liveRed : ARCTheme.line, lineWidth: p.onAir ? 2 : 1))
            .cornerRadius(4)
            .help(p.note ?? "What SHARE THIS sends")
    }

    @ViewBuilder private func centreWord(_ p: PreviewPlayer) -> some View {
        let word: String? = {
            switch p.transport.phase {
            case .loading, .converting: return p.transport.word
            case .failed: return p.note ?? "FAILED"
            default:
                if case .off = p.source { return "NO SOURCE" }
                if case .camera = p.source, !p.cameraRunning { return p.note ?? "CAMERA OFF" }
                return nil
            }
        }()
        if case .file = p.source, p.transport.isLoaded { EmptyView() }
        else if let word {
            VStack(spacing: ARCTheme.s(6)) {
                Text(word).font(ARCTheme.ui(12, .bold)).foregroundStyle(ARCTheme.text0).multilineTextAlignment(.center)
                    .lineLimit(3)
                if p.isConverting { arcChip("CANCEL", fill: ARCTheme.liveRed) { p.cancelConvert() }.help("Stop ffmpeg and drop the partial file") }
            }
            .padding(ARCTheme.s(6))
        }
    }

}

/// SOURCE + SHARE, then the transport (file) or the AUDIO IN (camera), then the scrubber or the camera's line.
struct PreviewControls: View {
    @Environment(Sidecar.self) private var sidecar
    @State private var cameras: [(id: String, name: String)] = []
    @State private var inputs: [(id: String, name: String)] = []
    @State private var scrub: Double?

    var body: some View {
        let p = sidecar.preview
        VStack(alignment: .leading, spacing: ARCTheme.s(5)) {
            ViewThatFits(in: .horizontal) {
                topRow(p, both: true)
                topRow(p, both: false)
            }
            switch p.source {
            case .file: transportRow(p); scrubRow(p)
            case .camera: audioInRow(p); cameraInfoRow(p)
            case .off:
                Text("Pick a camera or a video file: it plays here first, SHARE THIS sends exactly this picture.")
                    .font(ARCTheme.ui(10, .regular)).foregroundStyle(ARCTheme.textSecondary)
                    .lineLimit(3)
            }
        }
        .onAppear(perform: refreshDevices)
        .onHover { if $0 { refreshDevices() } }
    }

    private func refreshDevices() {
        // The SDK's list (what the SHARE module uses) once the SDK is up; AVFoundation's before that.
        let sdkCams = (sidecar.engine as? SDKZoomEngine).flatMap { $0.didInit ? $0.cameraList() : nil } ?? []
        cameras = sdkCams.isEmpty ? PreviewPlayer.availableCameras().map { ($0.uniqueID, $0.localizedName) } : sdkCams.map { ($0.deviceID, $0.name) }
        inputs = PreviewPlayer.availableAudioInputs().map { ($0.uniqueID, $0.localizedName) }
    }

    // MARK: Row 1: source and share

    private func topRow(_ p: PreviewPlayer, both: Bool) -> some View {
        let inMeeting = sidecar.state == .inMeeting
        let ready: Bool = {
            switch p.source {
            case .off: return false
            case .camera: return true
            case .file: return p.transport.isLoaded
            }
        }()
        let sharing = sidecar.isSharing || p.onAir
        let asVideo: Bool = { if case .camera = p.source { return p.sendAsVideo } else { return false } }()
        return HStack(spacing: ARCTheme.s(6)) {
            sourceMenu(p)
            Spacer(minLength: 0)
            if both || !p.onAir {
                arcChip(asVideo ? "GO LIVE" : "SHARE THIS", tint: ARCTheme.readyGreen) { Task { _ = await sidecar.sharePreview() } }
                    .disabled(!inMeeting || !ready || p.onAir)
                    .opacity(!inMeeting || !ready || p.onAir ? 0.5 : 1)
                    .help(!inMeeting ? "SHARE THIS works in a meeting" : (asVideo ? "Send this camera as ARC Zoom's own video, spotlighted (low delay)" : (sharing && !p.onAir ? "Replaces what this Mac is sharing now with this picture" : "Share exactly this picture into the meeting")))
            }
            if both || p.onAir {
                arcChip(p.shareMode == "camera-video" ? "STOP VIDEO" : "STOP SHARE", fill: sharing ? ARCTheme.liveRed : nil) { Task { await sidecar.stopPreviewShare() } }
                    .disabled(!sharing)
                    .opacity(sharing ? 1 : 0.5)
                    .help("Stop sharing into the meeting")
            }
        }
    }

    private func sourceMenu(_ p: PreviewPlayer) -> some View {
        Menu {
            Section("CAMERA") {
                ForEach(cameras, id: \.id) { cam in
                    Button {
                        p.previewCamera(id: cam.id, name: cam.name)
                    } label: {
                        if case .camera(let id, _) = p.source, id == cam.id { Label(cam.name, systemImage: "checkmark") } else { Text(cam.name) }
                    }
                }
                if cameras.isEmpty { Text("no cameras") }
            }
            Divider()
            Button("Video file\u{2026}") { Self.pickFile { p.loadFile($0) } }
            if case .file(let u) = p.source { Text("now: \(u.lastPathComponent)") }
            Divider()
            Button("Off (release the camera)") { p.previewOff() }
        } label: {
            Text(sourceWord(p) + " \u{25BE}").font(ARCTheme.ui(11, .bold)).foregroundStyle(ARCTheme.text0).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: ARCTheme.s(70), maxWidth: ARCTheme.s(220), alignment: .leading)
        .padding(.horizontal, ARCTheme.s(8)).padding(.vertical, ARCTheme.s(4))
        .background(ARCTheme.appGrey)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
        .cornerRadius(4)
        .layoutPriority(-1)
        .help("SOURCE: a camera (the list the SHARE module uses) or a video file. Off releases the camera.")
    }

    private func sourceWord(_ p: PreviewPlayer) -> String {
        switch p.source {
        case .off: return "SOURCE"
        case .camera(_, let name): return name
        case .file(let u): return u.lastPathComponent
        }
    }

    // MARK: Rows 2 and 3, FILE

    private func transportRow(_ p: PreviewPlayer) -> some View {
        let loaded = p.transport.isLoaded
        return HStack(spacing: ARCTheme.s(4)) {
            icon("backward.end.fill", help: "Restart from the top") { p.restart() }.disabled(!loaded)
            icon(p.transport.isPlaying ? "pause.fill" : "play.fill", on: p.transport.isPlaying, help: p.transport.isPlaying ? "Pause (the share holds this frame)" : "Play") { p.toggle() }.disabled(!loaded)
            icon("repeat", on: p.loop, help: "Loop: back to the top at the end and keep playing") { p.loop.toggle() }
            monitorControls(p, help: "Local monitor on this Mac only: never changes what the call hears")
        }
    }

    private func scrubRow(_ p: PreviewPlayer) -> some View {
        let d = max(p.transport.duration, 0.01)
        let pos = scrub ?? p.position
        return HStack(spacing: ARCTheme.s(4)) {
            Text(PreviewTime.clock(pos)).font(ARCTheme.ui(10, .bold)).foregroundStyle(ARCTheme.text0).monospacedDigit().fixedSize()
            Slider(value: Binding(get: { min(pos, d) }, set: { scrub = $0 }), in: 0...d) { editing in
                if !editing, let t = scrub { p.seek(to: t); scrub = nil }
            }
            .controlSize(.mini).tint(ARCTheme.secBlue)
            .frame(minWidth: ARCTheme.s(60))
            .disabled(!p.transport.isLoaded)
            Text(PreviewTime.remaining(position: pos, duration: p.transport.duration)).font(ARCTheme.ui(10, .bold)).foregroundStyle(ARCTheme.textSecondary).monospacedDigit().fixedSize()
        }
        .help(p.note ?? "\(p.transport.word) · elapsed / remaining")
    }

    // MARK: Rows 2 and 3, CAMERA

    /// AUDIO IN can change ON AIR (2026-09-24: "camera does not offer audio": it was greyed out once
    /// the camera was shared). Picture-only and picture + sound are different share paths (Zoom's camera
    /// share vs the raw source), so on air the change re-shares: SHARE THIS again replaces the running share.
    private func chooseAudio(_ p: PreviewPlayer, _ id: String?) {
        guard id != p.cameraAudioID else { return }
        let wasOnAir = p.onAir
        p.setCameraAudio(id: id)
        if wasOnAir {
            ShowLog.log("preview: AUDIO IN changed on air; re-sharing the camera \(id == nil ? "picture only" : "with its sound")")
            Task { _ = await sidecar.sharePreview() }
        }
    }

    private func audioInRow(_ p: PreviewPlayer) -> some View {
        HStack(spacing: ARCTheme.s(4)) {
            Menu {
                Button { chooseAudio(p, nil) } label: {
                    if p.cameraAudioID == nil { Label("None (video only)", systemImage: "checkmark") } else { Text("None (video only)") }
                }
                Divider()
                ForEach(inputs, id: \.id) { i in
                    Button { chooseAudio(p, i.id) } label: {
                        if p.cameraAudioID == i.id { Label(i.name, systemImage: "checkmark") } else { Text(i.name) }
                    }
                }
            } label: {
                Text((p.cameraAudioName ?? "VIDEO ONLY") + " \u{25BE}").font(ARCTheme.ui(10, .bold)).foregroundStyle(p.cameraAudioID == nil ? ARCTheme.textSecondary : ARCTheme.text0).lineLimit(1).truncationMode(.middle)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(ARCTheme.text1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: ARCTheme.s(60), maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ARCTheme.s(6)).padding(.vertical, ARCTheme.s(3))
            .background(ARCTheme.appGrey).cornerRadius(4)
            .layoutPriority(-1)
            .help("AUDIO IN for this camera, remembered per camera. NONE: picture only (Zoom's camera share). An input (an ATEM Mini's USB audio): picture and that sound go out together as one share, 48 kHz stereo, no processing." + (p.onAir ? " ON AIR: changing it re-shares the camera the new way (about a second)." : ""))
            if p.cameraAudioID != nil {
                monitorControls(p, help: "Local monitor of the AUDIO IN on this Mac only, OFF by default (feedback); never changes what the call hears")
            }
        }
    }

    private func cameraInfoRow(_ p: PreviewPlayer) -> some View {
        let size = p.naturalSize.width > 0 ? "\(Int(p.naturalSize.width))x\(Int(p.naturalSize.height))" : "--"
        let how = p.cameraAudioID == nil ? "picture only" : "+ sound"
        return HStack(spacing: ARCTheme.s(4)) {
            // SEND AS: a SHARE (content, but Zoom buffers it: ~3 s) or VIDEO (ARC Zoom's own camera, spotlighted:
            // well under a second). 2026-09-24. Locked on air: switching means stopping first.
            ForEach([false, true], id: \.self) { v in
                Button { p.sendAsVideo = v } label: {
                    Text(v ? "AS VIDEO" : "AS SHARE").font(ARCTheme.ui(10, .heavy))
                        .foregroundStyle(p.sendAsVideo == v ? .white : ARCTheme.text0)
                        .padding(.horizontal, ARCTheme.s(5)).padding(.vertical, ARCTheme.s(2))
                        .background(p.sendAsVideo == v ? ARCTheme.secBlue : ARCTheme.appGrey).cornerRadius(3)
                }
                .buttonStyle(.plain).disabled(p.onAir).fixedSize()
                .help(v ? "AS VIDEO: ARC Zoom's own camera (and AUDIO IN as its mic, MUSIC preset), spotlighted. Low delay; a participant tile, not content. STOP puts every setting back."
                        : "AS SHARE: a content share. Viewers can pop it out and recordings treat it as content, but Zoom buffers shares: about 3 s of delay.")
            }
            Text(p.note ?? "\(size) · \(how)")
                .font(ARCTheme.ui(10, .regular)).foregroundStyle(p.note == nil ? ARCTheme.textSecondary : ARCTheme.warn)
                .lineLimit(1).truncationMode(.tail)
                .help(p.note ?? "The camera at \(size); \(how)")
        }
    }

    // MARK: Shared pieces

    private func monitorControls(_ p: PreviewPlayer, help: String) -> some View {
        // PFL, mute, level; when the column is too narrow the level slider gives way first (PFL and mute never do).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ARCTheme.s(4)) { pflMenu(p); muteIcon(p, help: help); levelSlider(p, help: help) }
            HStack(spacing: ARCTheme.s(4)) { pflMenu(p); muteIcon(p, help: help) }
        }
    }

    private func muteIcon(_ p: PreviewPlayer, help: String) -> some View {
        icon(p.monitorMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", on: !p.monitorMuted, help: help) { p.monitorMuted.toggle() }
    }

    private func levelSlider(_ p: PreviewPlayer, help: String) -> some View {
        Slider(value: Binding(get: { Double(p.monitorVolume) }, set: { p.monitorVolume = Float($0) }), in: 0...1)
            .controlSize(.mini).tint(ARCTheme.text1)
            .frame(minWidth: ARCTheme.s(44), maxWidth: ARCTheme.s(120))
            .disabled(p.monitorMuted)
            .help(help)
    }

    /// PFL: where the local listen goes. OFF until chosen; the room speaker is marked, since picking it puts
    /// the preview in the room (the echo this was built to end).
    private func pflMenu(_ p: PreviewPlayer) -> some View {
        let room = (sidecar.engine as? SDKZoomEngine)?.soundSample.speaker
        let current = p.pflUID.flatMap(AudioOutputs.name(uid:))
        let isRoom = current != nil && current == room
        return Menu {
            Button("OFF: no local listening") { p.pflUID = nil }
            Divider()
            ForEach(AudioOutputs.all()) { d in
                Button(d.name == room ? "\(d.name)  (THE ROOM: the call plays here)" : d.name) { p.pflUID = d.id }
            }
        } label: {
            // Short on the chip (the file controls share one narrow column); the device is in the menu and the tooltip.
            Text(p.pflUID == nil ? "PFL OFF" : (current == nil ? "PFL ??" : (isRoom ? "PFL ROOM" : "PFL ON")))
                .font(ARCTheme.ui(11, .heavy)).lineLimit(1)
                .foregroundStyle(p.pflUID == nil ? ARCTheme.textSecondary : (isRoom || current == nil ? ARCTheme.liveRed : ARCTheme.readyGreen))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: true, vertical: false)
        .help(isRoom ? "PFL is \(current ?? "the room speaker"), the ROOM: the room hears the preview. Pick headphones."
              : (p.pflUID == nil ? "PFL: the output you listen to sources on before they go live. OFF = silent here; the call is never affected."
                 : "PFL: \(current ?? "a device that is unplugged"). The call is never affected."))
    }

    private func icon(_ name: String, on: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: ARCTheme.s(11), weight: .bold))
                .foregroundStyle(on ? .white : ARCTheme.text0)
                .frame(width: ARCTheme.s(26), height: ARCTheme.s(20))
                .background(on ? ARCTheme.secBlue : ARCTheme.appGrey)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? ARCTheme.secBlue : ARCTheme.line, lineWidth: 1))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The open panel for a video: every movie type, plus mkv / webm (ffmpeg converts those).
    static func pickFile(_ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        var types: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .avi, .video]
        for ext in ["mkv", "webm", "flv", "wmv", "ts", "mts", "m2ts", "mpg", "mpeg", "ogv"] { if let t = UTType(filenameExtension: ext) { types.append(t) } }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video for PREVIEW. \(PreviewFormats.sayWhatWorks)."
        panel.begin { r in
            guard r == .OK, let url = panel.url else { return }
            Task { @MainActor in done(url) }
        }
    }
}

/// The pane: the capture preview layer for a camera, the player layer for a file, black otherwise.
struct PreviewPane: NSViewRepresentable {
    let player: PreviewPlayer
    let source: PreviewPlayer.Source

    func makeNSView(context: Context) -> PreviewPaneView { PreviewPaneView() }
    func updateNSView(_ v: PreviewPaneView, context: Context) {
        switch source {
        case .camera: v.show(player.cameraLayer)
        case .file: v.show(player.playerLayer)
        case .off: v.show(nil)
        }
    }
}

final class PreviewPaneView: NSView {
    private var current: CALayer?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ l: CALayer?) {
        guard l !== current else { return }
        current?.removeFromSuperlayer()
        current = l
        if let l {
            l.removeFromSuperlayer()
            l.frame = bounds
            layer?.addSublayer(l)
        }
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        current?.frame = bounds
        CATransaction.commit()
    }
}

extension PreviewModule {
    /// The video open panel (the SHARE module's VIDEO FILE… uses it too).
    static func pickFile(_ done: @escaping (URL) -> Void) { PreviewControls.pickFile(done) }
}
