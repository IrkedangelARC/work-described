//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import UniformTypeIdentifiers

/// The MUSIC module's expanded controls in a floating window (2026-09-19:
/// "revamp the audio/music panel to be more intuitive and clear in its layout
/// and allow for an expanded config/control"; "add loadable and selectable
/// audio files to the expanded control window"). Per channel: the source and
/// its cue bank. CHIME: its own bank, one chosen, its own level. OUTPUT &
/// TIMING: the device, the fade, where FADE IN lands, how far a duck goes.
/// Everything here is set once per show; the rail keeps what is touched live.
struct MusicWindowView: View {
    @Environment(MusicEngine.self) private var music
    /// A slider writes only while held: SwiftUI's Slider writes its value back on appearance and
    /// teardown (seen on the layout panel 2026-09-19), which here would reset a level as the window closed.
    @State private var editing: String?

    private func held(_ key: String, get: @escaping () -> Float, set: @escaping (Float) -> Void) -> Binding<Float> {
        Binding(get: get, set: { if editing == key { set($0) } })
    }

    var body: some View {
        @Bindable var music = music
        ScrollView(.vertical) {
            VStack(spacing: ARCTheme.paddingSmall) {
                HStack(alignment: .top, spacing: ARCTheme.paddingSmall) {
                    ForEach(music.channels, id: \.id) { channel in
                        MusicChannelConfigView(channel: channel)
                            .frame(maxWidth: .infinity)
                    }
                }

                // CHIME
                VStack(spacing: 8) {
                    if music.chimeBank.isEmpty {
                        Text("No chime files yet. ADD FILES… then choose one; PLAY CHIME on the rail fires it.")
                            .font(ARCTheme.caption).foregroundStyle(ARCTheme.text2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(music.chimeBank) { cue in
                        HStack(spacing: 8) {
                            Button {
                                music.selectChime(cue)
                            } label: {
                                Image(systemName: music.chime?.id == cue.id ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 14)).foregroundStyle(music.chime?.id == cue.id ? ARCTheme.warn : ARCTheme.text2)
                            }
                            .buttonStyle(.plain).help("Make this the chime")
                            Text(cue.name).font(ARCTheme.mono(13, .bold)).foregroundStyle(ARCTheme.textPrimary).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Self.duration(cue.duration)).font(ARCTheme.mono(11, .bold)).foregroundStyle(ARCTheme.text1).monospacedDigit()
                            chip("PLAY", fill: music.isChimePlaying && music.chime?.id == cue.id ? ARCTheme.readyGreen : nil) { music.selectChime(cue); music.playChime() }
                            chip("REMOVE") { music.removeChime(cue) }
                        }
                    }
                    HStack(spacing: 8) {
                        chip("ADD FILES\u{2026}") { pick(files: true) { music.addChimes(from: $0) } }
                        chip("STOP") { music.stopChime() }.disabled(!music.isChimePlaying)
                        Spacer(minLength: 8)
                        Text("LEVEL").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.text1)
                        Slider(value: held("chime", get: { music.chimeLevel }, set: { music.chimeLevel = $0 }), in: 0...1, onEditingChanged: { editing = $0 ? "chime" : nil }).tint(ARCTheme.accent).controlSize(.small).frame(width: 160)
                        readout(MusicEngine.dbLabel(music.chimeLevel))
                    }
                }
                .padding(ARCTheme.modulePad)
                .arcModule(title: "Chime", tint: ARCTheme.warn, badge: music.chime.map { ARCBandBadge(text: $0.name.uppercased(), fill: ARCTheme.text0) })

                // OUTPUT & TIMING
                VStack(spacing: 8) {
                    row("OUTPUT") {
                        outputMenu
                        if music.followsDefaultOutput { Text("following the system default").font(ARCTheme.caption).foregroundStyle(ARCTheme.text2) }
                        Spacer(minLength: 0)
                        chip("REFRESH") { music.refreshOutputs(); music.refreshSources() }
                    }
                    row("PFL OUT") {
                        pflMenu
                        Text(music.pflOutput == nil ? "pre-fade listen: pick headphones or a second interface" : (music.pflAvailable ? "pre-fader, the room never hears it" : "same device as the main output: PFL off"))
                            .font(ARCTheme.caption).foregroundStyle(music.pflOutput != nil && !music.pflAvailable ? ARCTheme.warn : ARCTheme.text2).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("PFL LEVEL").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.text1)
                        Slider(value: held("pfl", get: { music.pflLevel }, set: { music.pflLevel = $0 }), in: 0...1, onEditingChanged: { editing = $0 ? "pfl" : nil }).tint(ARCTheme.secBlue).controlSize(.small).frame(width: 140)
                        readout(MusicEngine.dbLabel(music.pflLevel))
                    }
                    row("FADE TIME") {
                        Slider(value: Binding(get: { music.fadeSeconds }, set: { if editing == "fade" { music.fadeSeconds = ($0 * 2).rounded() / 2 } }), in: 0.5...15, onEditingChanged: { editing = $0 ? "fade" : nil }).tint(ARCTheme.secBlue).controlSize(.small)
                        readout("\(MusicControlView.format(music.fadeSeconds)) s")
                    }
                    .help("FADE IN, FADE OUT and X-FADE all take this long")
                    row("FADE IN TO") {
                        Slider(value: held("fadeIn", get: { music.fadeInLevel }, set: { music.fadeInLevel = $0 }), in: 0...1, onEditingChanged: { editing = $0 ? "fadeIn" : nil }).tint(ARCTheme.readyGreen).controlSize(.small)
                        readout(MusicEngine.dbLabel(music.fadeInLevel))
                    }
                    .help("Where FADE IN lands")
                    row("DUCK TO") {
                        Slider(value: held("duck", get: { music.duckLevel }, set: { music.duckLevel = $0 }), in: 0...1, onEditingChanged: { editing = $0 ? "duck" : nil }).tint(ARCTheme.warn).controlSize(.small)
                        readout(MusicEngine.dbLabel(music.duckLevel))
                        chip("AUTO DUCK", fill: music.autoDuck ? ARCTheme.secBlue : nil) { music.autoDuck.toggle() }
                    }
                    .help("How far the other channel drops under a cue")
                    if !music.heldNames.isEmpty {
                        row("HELD SILENT") {
                            Text(music.heldNames.joined(separator: ", ")).font(ARCTheme.mono(12, .bold)).foregroundStyle(ARCTheme.warn).lineLimit(1)
                            Spacer(minLength: 0)
                            chip("RELEASE TO APPS") { music.releaseHolds() }
                                .help("Let the held apps play on their own again")
                        }
                    }
                }
                .padding(ARCTheme.modulePad)
                .arcModule(title: "Output & timing", tint: ARCTheme.line)
            }
            .padding(ARCTheme.paddingMedium)
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(ARCTheme.background)
    }

    private func readout(_ text: String) -> some View {
        Text(text).font(ARCTheme.mono(12, .heavy)).foregroundStyle(ARCTheme.textPrimary).monospacedDigit().lineLimit(1).fixedSize().frame(width: 84, alignment: .trailing)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.text1).frame(width: 96, alignment: .leading)
            content()
        }
    }

    private var outputMenu: some View {
        Menu {
            Button("System default") { music.select(output: nil) }
            Divider()
            ForEach(music.outputs) { out in Button(out.name) { music.select(output: out) } }
        } label: {
            HStack(spacing: 6) {
                Text(music.selectedOutput?.name ?? "DEFAULT").font(ARCTheme.mono(12, .bold)).foregroundStyle(ARCTheme.textPrimary).lineLimit(1).frame(maxWidth: 220)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(ARCTheme.textSecondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(ARCTheme.surfaceLight)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
            .cornerRadius(4)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Output device the channels and the chime play through")
    }

    private var pflMenu: some View {
        Menu {
            Button("None") { music.select(pflOutput: nil) }
            Divider()
            ForEach(music.outputs) { out in Button(out.name) { music.select(pflOutput: out) } }
        } label: {
            HStack(spacing: 6) {
                Text(music.pflOutput?.name ?? "NONE").font(ARCTheme.mono(12, .bold)).foregroundStyle(ARCTheme.textPrimary).lineLimit(1).frame(maxWidth: 220)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(ARCTheme.textSecondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(ARCTheme.surfaceLight)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
            .cornerRadius(4)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("The device PFL plays through: headphones, or a second interface")
    }

    private func chip(_ label: String, fill: Color? = nil, action: @escaping () -> Void) -> some View {
        MusicChip(label: label, tint: fill == nil ? ARCTheme.textPrimary : ARCTheme.ink, fill: fill, action: action)
    }

    static func duration(_ s: Double) -> String {
        guard s > 0 else { return "?" }
        let m = Int(s) / 60, sec = Int(s) % 60
        return m > 0 ? String(format: "%d:%02d", m, sec) : String(format: "%.1f s", s)
    }

    /// Files or a folder of sound files, through the open panel.
    static func pick(files: Bool, message: String, add: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = files
        panel.canChooseDirectories = !files
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.message = message
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(url) }
    }
    private func pick(files: Bool, add: (URL) -> Void) {
        Self.pick(files: files, message: files ? "Choose chime files (mp3, wav, aiff, m4a)" : "Choose a folder of chimes", add: add)
    }
}

/// One channel's configuration: its source and its cue bank.
struct MusicChannelConfigView: View {
    @Environment(MusicEngine.self) private var music
    let channel: MusicChannel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("SOURCE").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.text1).frame(width: 64, alignment: .leading)
                sourceMenu
                VStack(spacing: 2) {
                    AudioMeterBars(peakL: channel.peakL, peakR: channel.peakR, compact: true)
                    AudioMeterBars(peakL: channel.signalL, peakR: channel.signalR, compact: true, mono: ARCTheme.text1)
                }
                .frame(width: 120)
                .help("Coloured: post-fade, what the room gets. Grey: pre-fade, the source.")
                Spacer(minLength: 0)
                MusicChip(label: "LOOP", tint: channel.loop ? ARCTheme.ink : ARCTheme.textPrimary, fill: channel.loop ? ARCTheme.secBlue : nil) { channel.loop.toggle() }
                    .help("Play a cue again when it ends (a music bed from a file)")
            }
            Rectangle().fill(ARCTheme.line).frame(height: 1)
            if channel.cues.isEmpty {
                Text("No sound files. ADD FILES… or ADD FOLDER…; each becomes a button on the rail.")
                    .font(ARCTheme.caption).foregroundStyle(ARCTheme.text2).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(channel.cues) { cue in
                HStack(spacing: 8) {
                    Text(cue.name).font(ARCTheme.mono(13, .bold)).foregroundStyle(ARCTheme.textPrimary).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(MusicWindowView.duration(cue.duration)).font(ARCTheme.mono(11, .bold)).foregroundStyle(ARCTheme.text1).monospacedDigit()
                    MusicChip(label: channel.playingCue?.id == cue.id ? "STOP" : "PLAY", tint: channel.playingCue?.id == cue.id ? ARCTheme.ink : ARCTheme.textPrimary,
                              fill: channel.playingCue?.id == cue.id ? ARCTheme.readyGreen : nil) { channel.toggle(cue) }
                    MusicChip(label: "REMOVE") { channel.removeCue(cue) }
                }
            }
            HStack(spacing: 8) {
                MusicChip(label: "ADD FILES\u{2026}") { MusicWindowView.pick(files: true, message: "Choose sound files for channel \(channel.name)") { channel.addCues(from: $0) } }
                MusicChip(label: "ADD FOLDER\u{2026}") { MusicWindowView.pick(files: false, message: "Choose a folder of sound files for channel \(channel.name)") { channel.addCues(from: $0) } }
                Spacer(minLength: 0)
                MusicChip(label: "CLEAR") { channel.clearCues() }.disabled(channel.cues.isEmpty)
            }
        }
        .padding(ARCTheme.modulePad)
        .arcModule(title: "Channel \(channel.name)", tint: channel.id == .a ? ARCTheme.secBlue : ARCTheme.secGreen,
                   badge: ARCBandBadge(text: channel.hasSignal ? (channel.isUp ? "SIGNAL  UP" : "SIGNAL  NOT HEARD") : (channel.isUp ? "SILENT  UP" : "SILENT  DOWN"),
                                       fill: channel.hasSignal ? (channel.isUp ? ARCTheme.readyGreen : ARCTheme.warn) : ARCTheme.text0))
    }

    private var sourceMenu: some View {
        Menu {
            Section("Apps") {
                ForEach(music.sources) { src in
                    Button { channel.select(source: src) } label: { src.isRunningOutput ? Label(src.name, systemImage: "waveform") : Label(src.name, systemImage: "") }
                }
                if music.sources.isEmpty { Text("No apps with audio running") }
            }
            Divider()
            Button("None (keep the app silent)") { channel.select(source: nil) }.disabled(channel.source == nil)
            Button("Release to app (audible on its own)") { channel.select(source: nil); music.releaseHolds() }.disabled(channel.source == nil && music.heldNames.isEmpty)
            Button("Refresh") { music.refreshSources() }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(channel.isRunning ? ARCTheme.readyGreen : ARCTheme.text2).frame(width: 7, height: 7)
                Text(channel.source?.name ?? "NONE").font(ARCTheme.mono(12, .bold)).foregroundStyle(ARCTheme.textPrimary).lineLimit(1).frame(maxWidth: 200)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(ARCTheme.textSecondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(ARCTheme.surfaceLight)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
            .cornerRadius(4)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("The app this channel takes music from (Music, Chrome, QuickTime…)")
    }
}
