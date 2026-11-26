//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import UniformTypeIdentifiers

/// MUSIC module (rail, below MESSAGE): two channels, A and B. Each has a
/// source app and/or a bank of sound cues (files), a fader with dB readout,
/// a zoned meter, MUTE, FADE IN / FADE OUT. Below them: X-FADE
/// between the channels, AUTO DUCK, the output device and the fade time.
/// Everything acts on MusicEngine's gain stages over a process tap or the
/// cue player; the presentation's own audio path is untouched.
struct MusicControlView: View {
    @Environment(MusicEngine.self) private var music

    /// The rail keeps what an operator touches mid-show; everything set once per
    /// show (output device, fade time, levels, the banks) lives in the MUSIC window
    /// behind the band's expand button (2026-09-19).
    var body: some View {
        VStack(spacing: 4) {
            ForEach(music.channels, id: \.id) { channel in
                MusicChannelView(channel: channel)
                if channel.id == .a {
                    Rectangle().fill(ARCTheme.line).frame(height: 1)
                }
            }

            // Module row: X-FADE, AUTO DUCK ……… PLAY CHIME
            HStack(spacing: 8) {
                chip("X-FADE", tint: ARCTheme.secBlue) { music.crossfade() }
                    .help(xfadeHelp)
                chip("AUTO DUCK", fill: music.autoDuck ? ARCTheme.secBlue : nil) { music.autoDuck.toggle() }
                    .help("A cue fired on one channel ducks the other to \(MusicEngine.dbLabel(music.duckLevel)) while it plays")

                // The hint rides in the button row (2026-09-23): its own line was 18 pt the rail needed.
                // Full text on hover; warnings keep their colour.
                Text(captionLine)
                    .font(ARCTheme.mono(10, .regular))   // the legible floor, 12 pt at standard console text
                    .foregroundStyle(captionIsWarning ? ARCTheme.warn : ARCTheme.text2)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 30)                   // fixed: a module that changes height moves the whole rail
                    .help(captionLine)

                // Its own player: never interrupts a bed, never ducks anything (2026-09-19: "a separate play chime button").
                chip("PLAY CHIME", tint: music.chime == nil ? ARCTheme.text2 : ARCTheme.ink, fill: music.chime == nil ? nil : (music.isChimePlaying ? ARCTheme.readyGreen : ARCTheme.warn)) { music.playChime() }
                    .disabled(music.chime == nil)
                    .help(music.chime.map { "Play \"\($0.name)\" from the top at \(MusicEngine.dbLabel(music.chimeLevel))" } ?? "No chime chosen yet: MUSIC window › CHIME")
            }
        }
    }

    private var xfadeHelp: String {
        let up = music.channels.first { $0.isUp }
        let other = music.channels.first { !$0.isUp }
        if let up, let other { return "Fade \(up.name) out and \(other.name) in over \(Self.format(music.fadeSeconds)) s" }
        return "Fade the up channel out and the other in over \(Self.format(music.fadeSeconds)) s"
    }

    // MARK: - Helpers

    private var captionIsWarning: Bool {
        music.status != nil || music.chimeStatus != nil || music.channels.contains(where: { $0.status != nil })
    }

    private var captionLine: String {
        if let status = music.status { return status }
        for ch in music.channels { if let s = ch.status { return "\(ch.name): \(s)" } }
        if let s = music.chimeStatus { return "CHIME: \(s)" }
        if !music.heldNames.isEmpty { return "Holding \(music.heldNames.joined(separator: ", ")) silent. Release in the MUSIC window." }
        if music.a.source == nil && music.a.cues.isEmpty && music.b.source == nil && music.b.cues.isEmpty {
            return "Pick the app playing music, or load sound files in the MUSIC window. Apps go silent on their own and play through the fader."
        }
        return " "
    }

    static func format(_ s: Double) -> String {
        s == s.rounded() ? String(Int(s)) : String(format: "%.1f", s)
    }

    private func chip(_ label: String, tint: Color = ARCTheme.textPrimary, fill: Color? = nil,
                      action: @escaping () -> Void) -> some View {
        MusicChip(label: label, tint: tint, fill: fill, action: action)
    }
}

// MARK: - One channel

struct MusicChannelView: View {
    @Environment(MusicEngine.self) private var music
    let channel: MusicChannel

    var body: some View {
        // Two rows per channel, sized so A + B + the module row fit beside a
        // NEXT at its minimum on a 1080-high display (rail budget measured
        // 2026-09-16: about 170 pt for this module's content).
        VStack(spacing: 4) {
            // Row 1: [A] SOURCE ……… mute, fader (meter underneath), dB
            HStack(spacing: 8) {
                Text(channel.name)
                    .font(ARCTheme.mono(11, .heavy))
                    .foregroundStyle(ARCTheme.ink)
                    .frame(width: 18, height: 18)
                    .background(channel.isUp ? ARCTheme.readyGreen : ARCTheme.text1)
                    .cornerRadius(3)
                    .help(channel.isUp ? "Channel \(channel.name) is up (audible)" : "Channel \(channel.name)")
                // SIG: the source is putting out sound, before the fader. Green = and the room hears it;
                // amber = and it does not (muted or down); dim = silence at the source (2026-09-19).
                Text("SIG")
                    .font(ARCTheme.mono(9, .heavy))
                    .foregroundStyle(channel.hasSignal ? ARCTheme.ink : ARCTheme.text2)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(channel.hasSignal ? (channel.isUp ? ARCTheme.readyGreen : ARCTheme.warn) : ARCTheme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(channel.hasSignal ? Color.clear : ARCTheme.line, lineWidth: 1))
                    .help(channel.hasSignal ? (channel.isUp ? "Signal present and audible" : "Signal present but NOT audible: \(channel.muted ? "muted" : "fader down")") : "No signal at the source")
                sourceMenu

                Button {
                    channel.toggleMute()
                } label: {
                    Image(systemName: channel.muted ? "speaker.slash.fill" : (channel.level < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                        .font(.system(size: 13))
                        .foregroundStyle(channel.muted ? ARCTheme.liveRed : ARCTheme.textPrimary)
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .help(channel.muted ? "Unmute \(channel.name)" : "Mute \(channel.name) (level is kept)")

                VStack(spacing: 1) {
                    Slider(value: Binding(
                        get: { channel.level },
                        set: { channel.setLevel($0) }
                    ), in: 0...1)
                    .tint(ARCTheme.accent)
                    .controlSize(.small)
                    .help("Channel \(channel.name) level at the output device")
                    AudioMeterBars(peakL: channel.peakL, peakR: channel.peakR, compact: true)
                        .padding(.horizontal, 4)
                    // PRE-FADE, grey: what the source puts out, whatever the fader does (2026-09-19).
                    AudioMeterBars(peakL: channel.signalL, peakR: channel.signalR, compact: true, mono: ARCTheme.text1)
                        .padding(.horizontal, 4)
                        .padding(.top, 1)
                        .help("Pre-fade level: the source before the fader (grey). The coloured meter above is what the room gets.")
                }

                Text(MusicEngine.dbLabel(channel.level))
                    .font(ARCTheme.mono(12, .heavy))
                    .foregroundStyle(channel.muted || channel.level == 0 ? ARCTheme.liveRed : ARCTheme.textPrimary)
                    .lineLimit(1).fixedSize()
                    // "-60.0 dB" at the legible size: 60 pt was measured for 12 pt text and wrapped at 14.
                    .frame(width: (ARCTheme.legible(12) * 0.62 * 8).rounded(), alignment: .trailing)
                    .monospacedDigit()
            }

            // Row 2: FADE IN / FADE OUT ……… the cue bank, LOOP
            HStack(spacing: 6) {
                MusicChip(label: "FADE IN", tint: ARCTheme.readyGreen) { channel.fadeIn() }
                    .help("Fade \(channel.name) up to \(MusicEngine.dbLabel(music.fadeInLevel)) over \(fadeLabel)")
                MusicChip(label: "FADE OUT", tint: ARCTheme.liveRed) { channel.fadeOut() }
                    .help("Fade \(channel.name) to silence over \(fadeLabel)")
                // PFL: this channel before its fader, on the PFL device, one channel at a time (2026-09-19).
                MusicChip(label: "PFL", tint: music.isPFL(channel) ? ARCTheme.ink : (music.pflAvailable ? ARCTheme.textPrimary : ARCTheme.text2),
                          fill: music.isPFL(channel) ? ARCTheme.secBlue : nil) { music.togglePFL(channel.id) }
                    .disabled(!music.pflAvailable)
                    .help(music.pflAvailable ? "Pre-fade listen to \(channel.name) on \(music.pflOutput?.name ?? "the PFL output") at \(MusicEngine.dbLabel(music.pflLevel)); the room hears no change"
                                             : "Choose a PFL output in the MUSIC window (a device other than the main output)")
                // No DUCK button (2026-09-17). AUTO DUCK still lowers a channel
                // under a cue on the other one, and a fader that sits low with no
                // word why is a trap on a live console: say so while it lasts.
                if channel.isDucked {
                    Text("DUCKED")
                        .font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.ink)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(ARCTheme.warn))
                        .help(channel.autoDucked ? "Lowered to \(MusicEngine.dbLabel(music.duckLevel)) under a cue on the other channel; it comes back when the cue ends" : "Lowered to \(MusicEngine.dbLabel(music.duckLevel)) over the control API (POST /music/duck)")
                }
                if channel.cues.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    Rectangle().fill(ARCTheme.line).frame(width: 1, height: 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(channel.cues) { cue in
                                MusicChip(label: cue.name, tint: ARCTheme.textPrimary,
                                          fill: channel.playingCue?.id == cue.id ? ARCTheme.readyGreen : nil) { channel.toggle(cue) }
                                    .help("\(cue.name) (\(Self.duration(cue.duration))). Press to fire from the top, press again to stop.")
                                    .contextMenu {
                                        Button("Remove \(cue.name)") { channel.removeCue(cue) }
                                    }
                            }
                        }
                    }
                    if channel.loop {
                        Text("LOOP").font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.ink)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(ARCTheme.secBlue))
                            .help("This channel's cues loop (set in the MUSIC window)")
                    }
                }
            }
        }
    }

    private var fadeLabel: String {
        let s = music.fadeSeconds
        return (s == s.rounded() ? String(Int(s)) : String(format: "%.1f", s)) + " s"
    }

    private static func duration(_ s: Double) -> String {
        guard s > 0 else { return "?" }
        let m = Int(s) / 60, sec = Int(s) % 60
        return m > 0 ? String(format: "%d:%02d", m, sec) : String(format: "%.1f s", s)
    }

    private var sourceMenu: some View {
        Menu {
            Section("Apps") {
                ForEach(music.sources) { src in
                    Button {
                        channel.select(source: src)
                    } label: {
                        if src.isRunningOutput {
                            Label(src.name, systemImage: "waveform")
                        } else {
                            Text(src.name)
                        }
                    }
                }
                if music.sources.isEmpty {
                    Text("No apps with audio running")
                }
            }
            Divider()
            Button("None (keep the app silent)") { channel.select(source: nil) }
                .disabled(channel.source == nil)
            Button("Release to app (audible on its own)") { channel.select(source: nil); music.releaseHolds() }
                .disabled(channel.source == nil && music.heldNames.isEmpty)
            Button("Refresh") { music.refreshSources() }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(channel.isRunning ? ARCTheme.readyGreen : ARCTheme.text2)
                    .frame(width: 7, height: 7)
                Text(sourceLabel)
                    .font(ARCTheme.mono(12, .bold))
                    .foregroundStyle(ARCTheme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: 150)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ARCTheme.textSecondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(ARCTheme.surfaceLight)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
            .cornerRadius(4)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("App to take music from (Music, Chrome, QuickTime…); sound files are loaded in the MUSIC window")
    }

    private var sourceLabel: String {
        if let s = channel.source { return s.name }
        if let c = channel.playingCue { return c.name }
        if !channel.cues.isEmpty { return "\(channel.cues.count) CUES" }
        return "NONE"
    }

}

// MARK: - Chip

struct MusicChip: View {
    let label: String
    var tint: Color = ARCTheme.textPrimary
    var fill: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(ARCTheme.mono(11, .bold))
                .foregroundStyle(fill == nil ? tint : .white)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(fill ?? ARCTheme.appGrey)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(fill ?? ARCTheme.line, lineWidth: 1))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}
