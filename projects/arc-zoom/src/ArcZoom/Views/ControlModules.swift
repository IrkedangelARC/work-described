//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AVFoundation
import ARCStyle
import ZoomSDK
import UniformTypeIdentifiers

// The Zoom operator's controls live HERE (2026-09-20: "the control of the zoom should stay in the
// stand alone app"). Three modules on the engine's one-second samples: HEALTH, SETTINGS, SOUND. Every
// control names what it does to the MEETING as against the ROOM.

/// The rail's growing tail on the settings side: the show log, taking whatever height is left (
/// 2026-09-20: "no reason for all this negative space"). Link lamps, ours and per participant, live on
/// the header strip.
struct HealthModule: View {
    let sdk: SDKZoomEngine
    var flexible = false
    var body: some View {
        let h = sdk.health
        VStack(alignment: .leading, spacing: 6) {
            if let w = sdk.lastWarning {
                Text("ZOOM WARNS: \(w)").font(ARCTheme.ui(11, .heavy)).foregroundStyle(ARCTheme.liveRed).fixedSize(horizontal: false, vertical: true)
            }
            if sdk.coHostNeeded {
                Text("CO-HOST NEEDED: ask the meeting's host to promote ARC Zoom").font(ARCTheme.ui(11, .heavy)).foregroundStyle(ARCTheme.warn)
            }
            // The last lines that fit, newest at the bottom, no scrolling: a log tail, not a document.
            GeometryReader { g in
                let n = max(3, Int(g.size.height / 14.5))
                let lines = ShowLog.recent(n)
                VStack(alignment: .leading, spacing: 1) {
                    Spacer(minLength: 0)
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(Self.trim(line))
                            .font(ARCTheme.ui(10, line.contains("ERROR") ? .bold : .regular))
                            .foregroundStyle(line.contains("ERROR") ? ARCTheme.liveRed : (i == lines.count - 1 ? ARCTheme.text0 : ARCTheme.textSecondary))
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .bottomLeading)
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: flexible ? .infinity : 90)
            .arcSubGroup(h.dataCenter.isEmpty ? nil : "newest last · \(h.dataCenter.replacingOccurrences(of: "You are connected to Zoom Global Network via data centers in ", with: "zoom via ").lowercased())")
        }
        .frame(maxWidth: .infinity, maxHeight: flexible ? .infinity : nil, alignment: .topLeading)
        .arcModule(title: "SHOW LOG", tint: ARCTheme.secGreen, scale: ARCTheme.uiScale)
    }
    /// "2026-09-20 17:45:12.123 message" -> "17:45:12 message"
    static func trim(_ line: String) -> String {
        guard line.count > 24, line.dropFirst(4).first == "-" else { return line }
        return String(line.dropFirst(11).prefix(8)) + " " + String(line.dropFirst(24))
    }
    private func colour(_ q: String) -> SwiftUI.Color {
        switch q {
        case "Excellent", "Good": return ARCTheme.readyGreen
        case "Normal": return ARCTheme.text0
        case "NotGood": return ARCTheme.warn
        case "Bad", "VeryBad": return ARCTheme.liveRed
        default: return ARCTheme.textTertiary
        }
    }
}

struct SettingsModule: View {
    let sdk: SDKZoomEngine

    var body: some View {
        let s = sdk.settingsSample
        let inMeeting = sdk.state == .inMeeting
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                chip(sdk.meetingLocked ? "LOCKED" : "LOCK", fill: sdk.meetingLocked ? ARCTheme.liveRed : nil) { _ = sdk.setLock(!sdk.meetingLocked) }
                    .help("Lock the meeting: nobody new can join. Flag follows the command; the SDK has no lock getter.")
                chip("MUTE ALL") { _ = sdk.muteAll(true) }
                    .help("Mute every participant in the MEETING; they may unmute themselves while ALLOW UNMUTE is on")
                chip(s.allowUnmute ? "ALLOW UNMUTE" : "NO SELF-UNMUTE", fill: s.allowUnmute ? nil : ARCTheme.warn) { _ = sdk.allowUnmuteBySelf(!s.allowUnmute) }
                chip("LOWER HANDS") { _ = sdk.lowerAllHands() }
                    .help("Lower every raised hand" + (sdk.raisedHands.isEmpty ? "" : " (\(sdk.raisedHands.count) up)"))
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                chip(s.waitingRoom ? "WAITING ROOM ON" : "WAITING ROOM OFF", fill: s.waitingRoom ? ARCTheme.secBlue : nil) { _ = sdk.setWaitingRoomOnEntry(!s.waitingRoom) }
                    .help("New arrivals wait for ADMIT")
                chip(s.muteOnEntry ? "MUTE ON ENTRY" : "OPEN ON ENTRY", fill: s.muteOnEntry ? ARCTheme.secBlue : nil) { _ = sdk.setMuteOnEntry(!s.muteOnEntry, allowUnmute: s.allowUnmute) }
                Text("SHARE").font(ARCTheme.ui(10, .heavy)).foregroundStyle(ARCTheme.textSecondary).fixedSize()
                ForEach(["hostOnly", "anyone", "multi"], id: \.self) { name in
                    let label = name == "hostOnly" ? "HOST ONLY" : name.uppercased()
                    chip(label, fill: s.share == label ? ARCTheme.secBlue : nil) { _ = sdk.setSharePolicy(name) }
                }
                Spacer(minLength: 0)
            }
            if !sdk.waitingRoomIDs.isEmpty {
                HStack(spacing: 8) {
                    Text("\(sdk.waitingRoomIDs.count) WAITING").font(ARCTheme.ui(11, .heavy)).foregroundStyle(ARCTheme.warn)
                    chip("ADMIT ALL", tint: ARCTheme.readyGreen) { Task { _ = await sdk.admit(nil) } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcModule(title: "SETTINGS", tint: ARCTheme.secBlue, scale: ARCTheme.uiScale)
        .disabled(!inMeeting)
        .opacity(inMeeting ? 1 : 0.5)
    }

    private func chip(_ label: String, tint: SwiftUI.Color = ARCTheme.text0, fill: SwiftUI.Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(ARCTheme.ui(11, .bold)).lineLimit(1).fixedSize()
                .foregroundStyle(fill == nil ? tint : .white)
                .padding(.horizontal, ARCTheme.s(10)).padding(.vertical, ARCTheme.s(5))
                .background(fill ?? ARCTheme.appGrey)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(fill ?? ARCTheme.line, lineWidth: 1))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

struct SoundModule: View {
    let sdk: SDKZoomEngine
    /// The last module in its rail: the bracket runs to the rail's bottom (its content stays at the top).
    var fills = false
    @Environment(Sidecar.self) private var sidecar
    @Environment(\.operatorLayout) private var layout
    /// Picker, meter and slider widths: on a 1512 MacBook's rail one device line fits with 180 / 80 / 90
    /// (2026-09-23); the roomy widths wrap the slider to a second line there.
    private var pickerW: CGFloat { ARCTheme.s(layout.narrow ? 160 : 210) }
    private var meterW: CGFloat { ARCTheme.s(layout.narrow ? 60 : 110) }
    private var sliderW: CGFloat { ARCTheme.s(layout.narrow ? 80 : 110) }
    var body: some View {
        let so = sdk.soundSample
        let inMeeting = sdk.state == .inMeeting
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                FlowRow(spacing: ARCTheme.s(8)) {
                    arcLabel("IN").frame(width: ARCTheme.s(26), alignment: .leading).help("IN: the mic the call hears")
                    deviceMenu(mic: true, current: so.mic)
                    LiveMeter(meter: sidecar.micMeter).frame(width: meterW, height: ARCTheme.s(10))
                        .help(sidecar.micMeter.error ?? "Live level of \(sidecar.micMeter.deviceLabel)")
                    Slider(value: Binding(get: { so.micVolume < 0 ? 100 : so.micVolume }, set: { _ = sdk.setVolume(mic: true, Float($0)) }), in: 0...100)
                        .frame(width: sliderW).tint(ARCTheme.secBlue)
                    Text(so.micVolume < 0 ? "--" : "\(Int(so.micVolume))").font(ARCTheme.ui(11, .bold)).foregroundStyle(ARCTheme.text0).frame(width: ARCTheme.s(26))
                    if sdk.micMutedBySlider {
                        Text("MUTED AT 0").font(ARCTheme.ui(11, .heavy)).foregroundStyle(ARCTheme.liveRed)
                            .help("The slider at 0 muted the sidecar in the call; raise it to open the mic again")
                    } else if sdk.micGainIgnored {
                        Text("NO HARDWARE GAIN").font(ARCTheme.ui(11, .heavy)).foregroundStyle(ARCTheme.warn)
                            .help("This mic ignores its level setting (common on USB webcams). Use MIC OPEN / MUTED in OUTPUTS, or set the level at the console. 0 still mutes.")
                    }
                }
                FlowRow(spacing: ARCTheme.s(8)) {
                    arcLabel("OUT").frame(width: ARCTheme.s(26), alignment: .leading).help("OUT: the call into the room")
                    deviceMenu(mic: false, current: so.speaker)
                    Meter(level: Float(sdk.speakerLevel) / 15).frame(width: meterW, height: ARCTheme.s(10))
                        .help("Level only during a speaker test; the SDK has no playback meter")
                    Slider(value: Binding(get: { so.speakerVolume < 0 ? 100 : so.speakerVolume }, set: { _ = sdk.setVolume(mic: false, Float($0)) }), in: 0...100)
                        .frame(width: sliderW).tint(ARCTheme.secBlue)
                    Text(so.speakerVolume < 0 ? "--" : "\(Int(so.speakerVolume))").font(ARCTheme.ui(11, .bold)).foregroundStyle(sdk.speakerOutputOn ? ARCTheme.text0 : ARCTheme.textTertiary).frame(width: ARCTheme.s(26))
                    arcChip(sdk.speakerOutputOn ? "MUTE" : "UNMUTE", fill: sdk.speakerOutputOn ? nil : ARCTheme.liveRed) { _ = sdk.setSpeakerOutput(!sdk.speakerOutputOn) }
                        .help("The call's playback into the room from this Mac (BASIC). CONSOLE and SPLIT keep it off. Needs a meeting: it is the call's audio.")
                        .disabled(!inMeeting).opacity(inMeeting ? 1 : 0.5)
                }
            }
            // Narrow: the IN / OUT explanation rides on the tooltips instead of a second label line.
            .arcSubGroup((layout.narrow ? "devices" : "devices · in: the mic the call hears · out: the call into the room") + (so.heldCamera.map { " · \($0) held open for the mic" } ?? ""))
            HStack(alignment: .top, spacing: 6) {
                HStack(spacing: ARCTheme.s(6)) {
                    ForEach(["basic", "console", "split"], id: \.self) { name in
                        arcChip(name.uppercased(), fill: sdk.audioConfig == name ? ARCTheme.secBlue : nil) { sdk.applyAudioConfig(name, mixMinus: nil) }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)   // three chips; PRESET takes the rest so its flags keep one line
                .arcSubGroup("config")
                FlowRow(spacing: ARCTheme.s(6)) {
                    arcChip("SPEECH", fill: sdk.soundPreset == "speech" ? ARCTheme.secBlue : nil) { _ = sdk.applyPreset("speech") }
                    arcChip("MUSIC", fill: sdk.soundPreset == "music" ? ARCTheme.secBlue : nil) { _ = sdk.applyPreset("music") }
                        .help("Original sound, hi-fi, stereo, no gain riding, noise LOW. Refused in BASIC unless the mic is asserted mix-minus (SETTINGS)")
                    flag("ORIG", so.original); flag("HI-FI", so.hifi); flag("ST", so.stereo); flag("AGC", so.agc)
                    HStack(spacing: 4) { arcLabel("NS"); Text(so.noise).font(ARCTheme.ui(11, .bold)).foregroundStyle(ARCTheme.text0).fixedSize() }
                }
                .arcSubGroup("preset")
                // Original sound is a meeting-audio control, so a preset applied with no meeting up would
                // be half a preset. The devices, volumes and config above are SETTINGS-service calls and
                // work before the meeting (2026-09-21: "is there any way to get this configured
                // before connecting?"), which is the whole point of doing it then.
                .disabled(!inMeeting).opacity(inMeeting ? 1 : 0.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
        .arcModule(title: "SOUND", tint: ARCTheme.secBlue, scale: ARCTheme.uiScale)
    }

    /// A standard menu picker, not the borderless Menu: that one drew but could not be operated in
    /// the meeting (2026-09-21: "no ability to change the audio devices"). The selection is the
    /// composite id, so "Same as system" and the device it stands for stay two rows.
    private func deviceMenu(mic: Bool, current: String) -> some View {
        let list = sdk.audioDeviceList(mic: mic)
        let selected = list.first { $0.selected && $0.name != "Same as system" } ?? list.first { $0.selected }
        return Picker("", selection: Binding(get: { selected?.id ?? "" }, set: { id in _ = sdk.selectAudio(mic: mic, id: id) })) {
            ForEach(list) { d in Text(d.name).tag(d.id) }
        }
        .pickerStyle(.menu).labelsHidden().tint(ARCTheme.text0)
        .frame(width: pickerW)
        .help(mic ? "Microphone the SDK sends" : "Speaker the SDK plays the call on")
    }
    private func flag(_ name: String, _ on: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(on ? ARCTheme.readyGreen : ARCTheme.textTertiary).frame(width: ARCTheme.s(7), height: ARCTheme.s(7))
            Text(name).font(ARCTheme.ui(10, .heavy)).foregroundStyle(on ? ARCTheme.text0 : ARCTheme.textSecondary).fixedSize()
        }
    }
}

/// The mic meter as its own view: it is the only thing that re-renders at the tap's rate, not the whole
/// SOUND module (audit P2).
struct LiveMeter: View {
    let meter: MicMeter
    var body: some View { Meter(level: meter.level) }
}

/// A horizontal meter: green to -12, amber to -3, red above, on a 0...1 scale.
struct Meter: View {
    let level: Float
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(ARCTheme.appGrey)
                RoundedRectangle(cornerRadius: 2)
                    .fill(level > 0.94 ? ARCTheme.liveRed : (level > 0.76 ? ARCTheme.warn : ARCTheme.readyGreen))
                    .frame(width: max(0, g.size.width * CGFloat(min(1, level))))
            }
        }
    }
}

/// The four settings an operator hits during a show, plus the glyph that opens all of them.
struct SettingsQuickRow: View {
    let sdk: SDKZoomEngine
    @Environment(Sidecar.self) private var sidecar
    @Environment(\.operatorLayout) private var layout
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        VStack(alignment: .leading, spacing: ARCTheme.s(6)) {
            meetingPolicies
                .disabled(sdk.state != .inMeeting)
                .opacity(sdk.state == .inMeeting ? 1 : 0.5)
            // PAGES on its OWN ROW. Beside the groups it either squeezed their chips (clipped) or, with
            // the groups fixedSize, blew the rail up to FlowRow's unwrapped width (measured 2026-09-21:
            // the whole right rail ran off the window). The row's height is affordable now that the
            // show log lives in the header and VIDEO's list is the rail's flexible tail.
            HStack(spacing: ARCTheme.s(6)) {
                arcWrappingChip("MEETING SETTINGS", width: ARCTheme.s(200),
                                fill: ControlWindow.isOpen(title: "Settings") ? ARCTheme.secBlue : nil) {
                    ControlWindow.toggle(id: "settings", title: "Settings", open: openWindow, dismiss: dismissWindow)
                }
                .help("Everything this meeting's policies, share, audio routing, devices and network can be set to. In-meeting: it acts on the meeting that is up.")
                arcWrappingChip("ZOOM PORTAL SETTINGS", width: ARCTheme.s(200),
                                fill: ControlWindow.isOpen(title: "Portal") ? ARCTheme.secBlue : nil) {
                    ControlWindow.toggle(id: "portal", title: "Portal", open: openWindow, dismiss: dismissWindow)
                }
                .help("ARC Tech ACCOUNT settings over REST: captions, recording, co-host, sharing, streaming. Not in the meeting and not visible from it - closed captioning OFF is why transcription delivered no text. They apply to NEW meetings only.")
                Spacer(minLength: 0)
            }
            .arcSubGroup("pages")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcModule(title: "SETTINGS", tint: ARCTheme.secBlue, scale: ARCTheme.uiScale)
    }

    /// The in-meeting policies: nothing here works outside a meeting.
    private var meetingPolicies: some View {
        // Three groups in one row need ~500 pt of rail ("WAITING ROOM OFF" is the widest chip); on a 1512
        // MacBook's rail DOOR takes its own row and the other two share the next (2026-09-23).
        Group {
            if layout.narrow {
                VStack(alignment: .leading, spacing: ARCTheme.s(6)) {
                    door
                    HStack(alignment: .top, spacing: ARCTheme.s(6)) { microphones; whoMayShare }
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)   // DOOR soaked up the rail's spare height without it
            } else {
                HStack(alignment: .top, spacing: ARCTheme.s(6)) { door; microphones; whoMayShare }
                    .fixedSize(horizontal: false, vertical: true)   // as tall as its tallest group; the others stretch to it
            }
        }
    }

    private var door: some View {
        let s = sdk.settingsSample
        return FlowRow(spacing: ARCTheme.s(6)) {
                arcChip(sdk.meetingLocked ? "LOCKED" : "LOCK", fill: sdk.meetingLocked ? ARCTheme.liveRed : nil) { _ = sdk.setLock(!sdk.meetingLocked) }
                    .help("Lock the meeting: nobody new can join. Flag follows the command; the SDK has no lock getter.")
                arcChip(s.waitingRoom ? "WAITING ROOM ON" : "WAITING ROOM OFF", fill: s.waitingRoom ? ARCTheme.secBlue : nil) { _ = sdk.setWaitingRoomOnEntry(!s.waitingRoom) }
                    .help("New arrivals wait for ADMIT")
                arcChip(s.muteOnEntry ? "MUTE ON ENTRY" : "OPEN ON ENTRY", fill: s.muteOnEntry ? ARCTheme.secBlue : nil) { _ = sdk.setMuteOnEntry(!s.muteOnEntry, allowUnmute: s.allowUnmute) }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .arcSubGroup("door")
    }

    private var microphones: some View {
        let s = sdk.settingsSample
        return FlowRow(spacing: ARCTheme.s(6)) {
                arcChip("MUTE ALL") { _ = sdk.muteAll(true) }
                    .help("Mute every participant in the MEETING; they may unmute themselves while ALLOW UNMUTE is on")
                arcChip(s.allowUnmute ? "ALLOW UNMUTE" : "NO SELF-UNMUTE", fill: s.allowUnmute ? nil : ARCTheme.warn) { _ = sdk.allowUnmuteBySelf(!s.allowUnmute) }
                arcChip("LOWER HANDS") { _ = sdk.lowerAllHands() }
                    .help("Lower every raised hand" + (sdk.raisedHands.isEmpty ? "" : " (\(sdk.raisedHands.count) up)"))
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .arcSubGroup("microphones")
    }

    private var whoMayShare: some View {
        let s = sdk.settingsSample
        return FlowRow(spacing: ARCTheme.s(6)) {
                ForEach(["hostOnly", "anyone", "multi"], id: \.self) { name in
                    let label = name == "hostOnly" ? "HOST ONLY" : name.uppercased()
                    arcChip(label, fill: s.share == label ? ARCTheme.secBlue : nil) { _ = sdk.setSharePolicy(name) }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .arcSubGroup("who may share")
    }
}

/// VIDEO: the camera the sidecar sends and how, plus what is coming in (2026-09-21: "a video
/// settings and camera select section" where the log was). CAMERA is a standard picker, pinned across
/// launches. QUALITY is the SDK's capture preferences. SENDING is our feed as the SDK reports it.
/// RECEIVING lists every participant with video and the size the sidecar pulls (the program participant
/// at 720p, the rest at 360p: the HD budget is one subscription), and is the content that grows.
struct VideoModule: View {
    let sdk: SDKZoomEngine
    /// false: not a rail's tail (a narrow rail puts CAPTIONS under it), so RECEIVING is a short fixed list.
    var flexible = true
    @Environment(Sidecar.self) private var sidecar
    @Environment(\.operatorLayout) private var layout

    var body: some View {
        let h = sdk.health
        let inMeeting = sdk.state == .inMeeting
        VStack(alignment: .leading, spacing: 6) {
            // ONE row: the picker and SEND ON JOIN, then QUALITY. CAMERA ON and BLUR are not repeated
            // here; they are OUTPUTS > OWN FEED. Three chip rows in this module ran the rail off the
            // window (measured 2026-09-21).
            // Side by side needs ~600 pt; a 1512 MacBook's rail stacks CAMERA over QUALITY (2026-09-23: the row ran
            // 90 pt past the rail and QUALITY was cut off).
            (layout.narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: ARCTheme.s(6))) : AnyLayout(HStackLayout(alignment: .top, spacing: ARCTheme.s(6)))) {
                HStack(spacing: ARCTheme.s(6)) {
                    cameraPicker
                    arcChip(sdk.sendsOwnVideo ? "SEND ON JOIN" : "OFF ON JOIN", fill: sdk.sendsOwnVideo ? ARCTheme.secBlue : nil) { sdk.sendsOwnVideo.toggle() }
                        .help("Whether the sidecar's camera starts sending the moment it joins or starts a meeting")
                }
                .arcSubGroup("camera · on/off and blur are in OUTPUTS > OWN FEED")
                HStack(spacing: ARCTheme.s(6)) {
                    arcChip(sdk.hdCapture ? "HD CAPTURE" : "SD CAPTURE", fill: sdk.hdCapture ? ARCTheme.secBlue : nil) { sdk.hdCapture.toggle() }
                        .help("Capture our camera at 720p and up. A viewer only gets it large if they show us large.")
                    arcChip(sdk.smoothVideo ? "SMOOTH 24-30" : "SHARPNESS", fill: sdk.smoothVideo ? ARCTheme.secBlue : nil) { sdk.smoothVideo.toggle() }
                        .help("Motion (24-30 fps) or detail: the SDK's video quality preference for what we send")
                }
                .fixedSize(horizontal: true, vertical: false)
                .arcSubGroup("quality")
            }
            receiving(sending: h.sendKbps > 0 ? "\(h.sendW)x\(h.sendH) \(h.sendFps) fps \(HealthStrip.rate(h.sendKbps))" : nil)
        }
        .frame(maxWidth: .infinity, maxHeight: flexible ? .infinity : nil, alignment: .topLeading)
        .arcModule(title: "VIDEO", tint: ARCTheme.secBlue, scale: ARCTheme.uiScale)
    }

    private var cameraPicker: some View {
        let list = sdk.cameraList()
        let selected = list.first { $0.selected }
        return HStack(spacing: ARCTheme.s(6)) {
            Picker("", selection: Binding(get: { selected?.id ?? "" }, set: { id in _ = sdk.selectCamera(id: id) })) {
                ForEach(list) { d in Text(d.name).tag(d.id) }
            }
            .pickerStyle(.menu).labelsHidden().tint(ARCTheme.text0)
            .frame(minWidth: ARCTheme.s(160), idealWidth: ARCTheme.s(240), maxWidth: ARCTheme.s(240))
            .help("The camera the sidecar sends into the call. Pinned across launches.")
            if let held = sdk.soundSample.heldCamera {
                Text("\(held) held for the mic").font(ARCTheme.ui(10, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1).layoutPriority(-1)
            }
        }
    }

    /// Everyone with video on and the size the sidecar pulls them at. Grows with the meeting. Our own
    /// send stats ride on the label: a row of their own cost 35 pt the rail did not have.
    private func receiving(sending: String?) -> some View {
        let people = sidecar.roster.filter { $0.videoOn }
        // A ScrollView, not a VStack of rows: rows have a height of their own and three of them pushed
        // the module past the window's edge (2026-09-21). A scroll view takes the space the rail
        // has left and scrolls the rest.
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 3) {
                if people.isEmpty {
                    Text(sdk.state == .inMeeting ? "nobody is sending video" : "not in a meeting").font(ARCTheme.ui(10, .regular)).foregroundStyle(ARCTheme.textSecondary)
                }
                ForEach(people) { p in
                    HStack(spacing: ARCTheme.s(8)) {
                        Circle().fill(ARCTheme.readyGreen).frame(width: ARCTheme.s(7), height: ARCTheme.s(7))
                        Text(p.displayName + (p.isMe ? " (self)" : "")).font(ARCTheme.ui(11, .bold)).foregroundStyle(ARCTheme.text0).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(p.isMe ? "own camera" : (sdk.hdID == p.id ? "720p" : "360p")).font(ARCTheme.ui(10, .regular)).foregroundStyle(ARCTheme.textSecondary).fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, minHeight: flexible ? nil : ARCTheme.s(40), maxHeight: flexible ? .infinity : ARCTheme.s(40), alignment: .topLeading)
        .arcSubGroup("receiving · program 720p, rest 360p" + (sending.map { " · sending \($0)" } ?? ""))
    }
}

/// HEALTH on the top strip: lamps, network, send stats, warnings, per-participant dots. One line.
struct HealthStrip: View {
    let sdk: SDKZoomEngine
    /// The narrow form (2026-09-23): the same items in a FlowRow, so a long SEND / SHARE line or a warning takes a
    /// second line instead of setting the window's minimum width. The header picks it when one line does not fit.
    var wraps = false

    var body: some View {
        if wraps {
            FlowRow(spacing: ARCTheme.s(12)) { items; peers }
        } else {
            HStack(spacing: ARCTheme.s(14)) { items; Spacer(minLength: 0); peers }
        }
    }

    @ViewBuilder private var items: some View {
        let h = sdk.health
            lamp("UPLINK", h.videoUp); lamp("AUDIO", h.audioUp); lamp("DOWN", h.videoDown)
            stat("NET", h.network.isEmpty ? "--" : "\(h.connection) · \(h.network)", level: h.network == "WIFI" ? .warn : .ok)
                .help(h.advice.isEmpty ? "Connection type and the interface Zoom is using" : h.advice)
            // Our camera going out. The SDK reports bits per second; receivers set the resolution they pull.
            stat("SEND", h.sendKbps > 0 ? "\(h.sendW)x\(h.sendH) \(h.sendFps)fps \(Self.rate(h.sendKbps))" : "--",
                 level: h.sendKbps == 0 ? .off : (h.sendFps < 10 ? .bad : (h.sendFps < 20 || h.sendH < 720 ? .warn : .ok)))
                .help("Our camera as sent. 360p means no viewer is pulling us large yet; 720p needs HD CAPTURE on (SETTINGS > DEVICES) and a viewer showing us large. Amber under 20 fps or under 720p, red under 10 fps.")
            if h.shareKbps > 0 {
                stat("SHARE", "\(h.shareW)x\(h.shareH) \(h.shareFps)fps \(Self.rate(h.shareKbps))", level: h.shareFps < 5 ? .warn : .ok)
                    .help("Our screen share as sent. Static content goes at a few fps by design; OPTIMISE FOR VIDEO in SHARE raises it to 30 for moving pictures.")
            }
            stat("RTT", h.sendRTT > 0 ? "\(h.sendRTT) ms" : "--", level: h.sendRTT == 0 ? .off : (h.sendRTT > 250 ? .bad : (h.sendRTT > 120 ? .warn : .ok)))
            stat("LOSS", String(format: "%.1f%% / %.1f%%", h.sendLoss, h.recvLoss), level: max(h.sendLoss, h.recvLoss) > 5 ? .bad : (max(h.sendLoss, h.recvLoss) > 1.5 ? .warn : .ok))
            if let w = sdk.lastWarning { Text("ZOOM: \(w)").font(ARCTheme.ui(11, .heavy)).foregroundStyle(ARCTheme.liveRed).fixedSize() }
            if sdk.coHostNeeded { Text("CO-HOST NEEDED").font(ARCTheme.ui(11, .heavy)).foregroundStyle(ARCTheme.warn).fixedSize() }
    }

    /// Per-participant uplink dots. Names truncate (they are the one thing here that may), up to eight.
    private var peers: some View {
        HStack(spacing: 8) {
            ForEach(sdk.participants.filter { !$0.isMe }.prefix(8)) { p in
                let q = sdk.userQuality[p.id]?["video.up"] ?? "Unknown"
                HStack(spacing: 4) {
                    Circle().fill(colour(q)).frame(width: ARCTheme.s(7), height: ARCTheme.s(7))
                    Text(p.displayName).font(ARCTheme.ui(10, .bold)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1)
                        .frame(minWidth: ARCTheme.s(40), maxWidth: ARCTheme.s(110), alignment: .leading)
                }
                .help("\(p.displayName) uplink \(q)")
            }
        }
    }

    private func colour(_ q: String) -> SwiftUI.Color {
        switch q {
        case "Excellent", "Good": return ARCTheme.readyGreen
        case "Normal": return ARCTheme.text0
        case "NotGood": return ARCTheme.warn
        case "Bad", "VeryBad": return ARCTheme.liveRed
        default: return ARCTheme.textTertiary
        }
    }
    private func lamp(_ name: String, _ q: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(colour(q)).frame(width: ARCTheme.s(8), height: ARCTheme.s(8))
            Text(name).font(ARCTheme.ui(10, .heavy)).foregroundStyle(ARCTheme.textSecondary).fixedSize()
            Text(q.isEmpty ? "--" : q.uppercased()).font(ARCTheme.ui(11, .bold)).foregroundStyle(colour(q)).fixedSize()
        }
    }
    enum Level { case ok, warn, bad, off }
    private func stat(_ name: String, _ value: String, level: Level) -> some View {
        let colour: SwiftUI.Color = level == .ok ? ARCTheme.readyGreen : (level == .warn ? ARCTheme.warn : (level == .bad ? ARCTheme.liveRed : ARCTheme.textTertiary))
        return HStack(spacing: 4) {
            Circle().fill(colour).frame(width: ARCTheme.s(7), height: ARCTheme.s(7))
            Text(name).font(ARCTheme.ui(10, .heavy)).foregroundStyle(ARCTheme.textSecondary).fixedSize()
            Text(value).font(ARCTheme.ui(11, .bold)).foregroundStyle(level == .off ? ARCTheme.textTertiary : ARCTheme.text0).lineLimit(1).fixedSize()
        }
    }
    /// bits per second, as the SDK reports it, to a number a person reads.
    static func rate(_ bps: Int) -> String { bps >= 1_000_000 ? String(format: "%.1f Mb/s", Double(bps) / 1_000_000) : "\(bps / 1000) kb/s" }
}

/// Sharing FROM the sidecar: everything the SDK can send into the meeting, and the settings that go with
/// it. Presenter's program is one item; a window, a display, a video file, a camera or audio alone are the
/// rest. Nobody opens Zoom's picker.
struct ShareModule: View {
    let sdk: SDKZoomEngine
    @Environment(Sidecar.self) private var sidecar
    @Environment(DisplayManager.self) private var displays
    @State private var windows: [SDKZoomEngine.ShareableWindow] = []
    var body: some View {
        let inMeeting = sdk.state == .inMeeting
        VStack(alignment: .leading, spacing: 6) {
            FlowRow(spacing: ARCTheme.s(6)) {
                if sdk.isSharing {
                    arcChip("STOP SHARE", fill: ARCTheme.liveRed) { Task { await sdk.stopShare() } }
                    arcChip("PAUSE") { _ = sdk.pauseShare(true) }
                    arcChip("RESUME") { _ = sdk.pauseShare(false) }
                    Text(sdk.shareDescription ?? "sharing").font(ARCTheme.ui(11, .bold)).foregroundStyle(ARCTheme.readyGreen).lineLimit(1).truncationMode(.middle)
                } else {
                    arcChip("PRESENTER'S PROGRAM", tint: ARCTheme.readyGreen) { Task { _ = await sdk.startShare(windowTitle: Sidecar.presenterShareWindow, withSound: sdk.shareSound) } }
                        .help("Share the window \"\(Sidecar.presenterShareWindow)\" (ARC Presenter's SHARE window)")
                    Menu {
                        ForEach(windows.filter { !$0.elsewhere }) { w in
                            Button("\(w.app): \(w.title.isEmpty ? "(untitled)" : w.title)  \(w.width)x\(w.height)") { _ = sdk.shareWindow(w.id, label: "\(w.app): \(w.title)") }
                        }
                        if windows.isEmpty { Text("no shareable windows") }
                        let elsewhere = windows.filter(\.elsewhere)
                        if !elsewhere.isEmpty {
                            Section("ON OTHER DESKTOPS OR MINIMISED") {
                                ForEach(elsewhere) { w in
                                    Button("\(w.app): \(w.title)  \(w.width)x\(w.height)") { _ = sdk.shareWindow(w.id, label: "\(w.app): \(w.title)") }
                                }
                            }
                        }
                        Divider()
                        Button("Refresh list") { windows = sdk.shareableWindows() }
                    } label: { menuLabel("WINDOW") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    // Re-listed when the pointer reaches the button (a Menu has no "opening" hook) and on appear,
                    // plus Refresh list: a window opened after the rail drew was missing until REFRESH. No timer
                    // (2026-09-24): nothing runs in a show unless someone reaches for the menu.
                    .onAppear { windows = sdk.shareableWindows() }
                    .onHover { if $0 { windows = sdk.shareableWindows() } }
                    Menu {
                        ForEach(displays.availableScreens) { sc in
                            Button("\(sc.localizedName) (\(sc.resolution))") { _ = sdk.shareDisplay(sc.id, label: "display \(sc.localizedName)") }
                        }
                    } label: { menuLabel("DISPLAY") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    arcChip("VIDEO FILE\u{2026}") { pickVideo() }
                        .help("Load a video into PREVIEW (OUTPUTS panel): play it there, then SHARE THIS sends it with a live transport. POST /share?file= is Zoom's own file share, no transport")
                    Menu {
                        let cams = ((ZoomSDK.shared().getSettingService()?.getVideoSetting()?.getCameraList() as? [SDKDeviceInfo]) ?? []).map { ($0.getDeviceID() + "|" + $0.getDeviceName(), $0.getDeviceID(), $0.getDeviceName()) }
                        ForEach(cams, id: \.0) { cam in
                            Button(cam.2) { _ = sdk.shareCamera(cam.1, label: cam.2) }
                        }
                    } label: { menuLabel("CAMERA") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    arcChip("AUDIO ONLY") { _ = sdk.shareAudioOnly() }
                }
            }
            .arcSubGroup(sdk.isSharing ? "sharing" : "source")
            FlowRow(spacing: ARCTheme.s(6)) {
                arcChip("SHARE SOUND", fill: sdk.shareSound ? ARCTheme.secBlue : nil) { sdk.shareSound.toggle() }
                    .help("Send the Mac's audio with the share (a video's soundtrack). Applied at share start, and live when the SDK allows")
                arcChip("OPTIMISE FOR VIDEO", fill: sdk.shareOptimizeVideo ? ARCTheme.secBlue : nil) { sdk.shareOptimizeVideo.toggle() }
                    .help("Smooth motion over sharp text: for a video clip, not for slides")
                arcChip("STEREO", fill: sdk.shareStereo ? ARCTheme.secBlue : nil) { sdk.shareStereo.toggle() }
                    .help("Stereo share audio (mono is the default)")
            }
            .arcSubGroup("options")
            // A share is going out or coming in, and nothing on this Mac draws it: the far end sees it,
            // the room does not, and the operator cannot tell (2026-09-21: "when I share the
            // screen it's invisible"). Say so, with where the fix is.
            if sidecar.shareSourceID != nil, !LayoutWindow.Kind.allCases.contains(where: { sidecar.scene(for: $0).elements.contains(.share) }) {
                Text("A share is up (the far end sees it) but no layout on this Mac shows it: LAYOUT › SHARE, SHARE + STRIP or SHARE + SPOTLIGHT SIDE on PROGRAM or MON")
                    .font(ARCTheme.ui(10, .regular)).foregroundStyle(ARCTheme.warn).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcModule(title: "SHARE", tint: ARCTheme.secCrimson, scale: ARCTheme.uiScale)
        .disabled(!inMeeting)
        .opacity(inMeeting ? 1 : 0.5)
    }
    /// VIDEO FILE… loads PREVIEW (2026-09-24, the operator: "share video file has no way to play?"): the file plays in
    /// the OUTPUTS panel first and SHARE THIS sends it with pause / seek / loop live. Zoom's own file share
    /// stays as PREVIEW's fallback and as `POST /share?file=`.
    private func pickVideo() {
        let preview = sidecar.preview
        PreviewModule.pickFile { preview.loadFile($0) }
    }
    private func menuLabel(_ t: String) -> some View {
        Text("\(t) \u{25BE}").font(ARCTheme.ui(11, .bold)).foregroundStyle(ARCTheme.text0).lineLimit(1).fixedSize()
            .padding(.horizontal, ARCTheme.s(10)).padding(.vertical, ARCTheme.s(5))
            .background(ARCTheme.appGrey)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
            .cornerRadius(4)
    }
}

/// CHAT in the rail: the last three lines and a composer to everyone; the glyph opens the full window with
/// private messages and the waiting room.
struct ChatModule: View {
    let sdk: SDKZoomEngine
    var flexible = false
    @State private var draft = ""
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// One line (2026-09-20 17:50): the last message, a composer to everyone, SEND, the unread
    /// count, and the glyph that opens the full chat window. History lives in the window.
    var body: some View {
        HStack(spacing: 8) {
            if let m = sdk.chatMessages.last {
                HStack(spacing: 5) {
                    Text(m.mine ? "ARC ZOOM" : m.sender.uppercased()).font(ARCTheme.ui(10, .heavy)).foregroundStyle(m.mine ? ARCTheme.secBlue : ARCTheme.readyGreen).lineLimit(1).fixedSize()
                    Text(m.text).font(ARCTheme.ui(11, .regular)).foregroundStyle(ARCTheme.text0).lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: ARCTheme.s(220), alignment: .leading)
                .help(m.text)
            }
            TextField("message to everyone", text: $draft)
                .textFieldStyle(.plain).font(ARCTheme.ui(12, .regular)).foregroundStyle(ARCTheme.text0)
                .padding(.horizontal, ARCTheme.s(8)).padding(.vertical, ARCTheme.s(5))
                .background(ARCTheme.appGrey)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
                .cornerRadius(4)
                .onSubmit { send() }
            arcChip("SEND", tint: ARCTheme.readyGreen) { send() }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            if sdk.unreadChat > 0 {
                Text("\(sdk.unreadChat) NEW").font(ARCTheme.ui(10, .heavy)).foregroundStyle(.white).padding(.horizontal, ARCTheme.s(6)).padding(.vertical, ARCTheme.s(2)).background(ARCTheme.liveRed).cornerRadius(3).fixedSize()
            }
            ARCExpandButton(tip: "Chat window: history, everyone, private, waiting room; click again to close", on: ControlWindow.isOpen(title: "Chat")) {
                sdk.markChatRead()
                ControlWindow.toggle(id: "chat", title: "Chat", open: openWindow, dismiss: dismissWindow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcModule(title: "CHAT", tint: ARCTheme.secOrange, scale: ARCTheme.uiScale)
        .disabled(sdk.state != .inMeeting)
        .opacity(sdk.state == .inMeeting ? 1 : 0.5)
    }
    private func send() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if sdk.sendChat(t) { draft = "" }
    }
}

/// The full chat: history, a recipient menu (everyone, one person, the waiting room), a composer.
struct ChatWindowView: View {
    @Environment(Sidecar.self) private var sidecar
    @State private var draft = ""
    @State private var recipient: UInt32? = nil
    @State private var toWaiting = false

    var body: some View {
        let sdk = sidecar.engine as? SDKZoomEngine
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sdk?.chatMessages ?? []) { m in
                            HStack(alignment: .top, spacing: 8) {
                                Text(Self.clock(m.time)).font(ARCTheme.ui(10, .regular)).foregroundStyle(ARCTheme.textTertiary).frame(width: ARCTheme.s(44), alignment: .leading)
                                Text(m.mine ? "ARC ZOOM" : m.sender.uppercased()).font(ARCTheme.ui(11, .heavy)).foregroundStyle(m.mine ? ARCTheme.secBlue : ARCTheme.readyGreen).frame(width: ARCTheme.s(130), alignment: .leading).lineLimit(1)
                                VStack(alignment: .leading, spacing: 1) {
                                    if !m.toAll { Text("private → \(m.receiver)").font(ARCTheme.ui(10, .regular)).foregroundStyle(ARCTheme.textTertiary) }
                                    Text(m.text).font(ARCTheme.ui(12, .regular)).foregroundStyle(ARCTheme.text0).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                }
                                Spacer(minLength: 0)
                            }
                            .id(m.id)
                        }
                    }
                    .padding(ARCTheme.s(ARCTheme.modulePad))
                }
                .onChange(of: sdk?.chatMessages.count ?? 0) { _, _ in if let last = sdk?.chatMessages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .frame(maxHeight: .infinity)
            .background(ARCTheme.surface).cornerRadius(4)
            HStack(spacing: 8) {
                Menu {
                    Button("Everyone") { recipient = nil; toWaiting = false }
                    Button("Waiting room") { recipient = nil; toWaiting = true }
                    Divider()
                    ForEach(sidecar.remotes) { p in Button(p.displayName) { recipient = p.id; toWaiting = false } }
                } label: {
                    Text("TO  \(toWaiting ? "WAITING ROOM" : (recipient.flatMap { r in sidecar.roster.first { $0.id == r }?.displayName } ?? "EVERYONE"))")
                        .font(ARCTheme.ui(11, .bold)).foregroundStyle(ARCTheme.text0).lineLimit(1).frame(width: ARCTheme.s(170), alignment: .leading)
                        .padding(.horizontal, ARCTheme.s(8)).padding(.vertical, ARCTheme.s(5)).background(ARCTheme.appGrey)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1)).cornerRadius(4)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                TextField("message", text: $draft)
                    .textFieldStyle(.plain).font(ARCTheme.ui(12, .regular)).foregroundStyle(ARCTheme.text0)
                    .padding(.horizontal, ARCTheme.s(8)).padding(.vertical, ARCTheme.s(5)).background(ARCTheme.appGrey)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1)).cornerRadius(4)
                    .onSubmit { send(sdk) }
                Button { send(sdk) } label: {
                    Text("SEND").font(ARCTheme.ui(11, .bold)).foregroundStyle(.white).padding(.horizontal, ARCTheme.s(12)).padding(.vertical, ARCTheme.s(5)).background(ARCTheme.secBlue).cornerRadius(4)
                }
                .buttonStyle(.plain).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(ARCTheme.railPad)
        .frame(minWidth: 520, minHeight: 360)
        .background(ARCTheme.ink)
        .onAppear { sdk?.markChatRead() }
    }

    private func send(_ sdk: SDKZoomEngine?) {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let sdk else { return }
        if sdk.sendChat(t, to: recipient, toWaitingRoom: toWaiting) { draft = "" }
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}


/// CAPTIONS: start and stop live transcription, the last two lines, and the glyph to the transcript window.
struct CaptionsModule: View {
    let sdk: SDKZoomEngine
    var flexible = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let on = sdk.transcriptionStatus == "ON"
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                chip(on ? "STOP TRANSCRIPTION" : "START TRANSCRIPTION", fill: on ? ARCTheme.liveRed : nil, tint: on ? .white : ARCTheme.readyGreen) { _ = on ? sdk.stopTranscription() : sdk.startTranscription() }
                    .disabled(!sdk.captionsSupported)
                    .help(sdk.captionsSupported ? "Zoom's live transcription for the meeting; text arrives per speaker" : "Live transcription is not enabled on this account")
                Text(sdk.transcriptionStatus).font(ARCTheme.ui(11, .heavy)).foregroundStyle(on ? ARCTheme.readyGreen : ARCTheme.textSecondary).fixedSize()
                Text(sdk.spokenLanguage).font(ARCTheme.ui(11, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
                ARCExpandButton(tip: "Transcript window: every line, the language, the vendor URL; click again to close", on: ControlWindow.isOpen(title: "Captions")) {
                    ControlWindow.toggle(id: "captions", title: "Captions", open: openWindow, dismiss: dismissWindow)
                }
            }
            .arcSubGroup("zoom live transcription")
            if sdk.captionsWaiting {
                Text("ON but no text: Zoom's caption service has not attached (clients say \"looking for a service\"). Portal: Settings > Meeting > In Meeting (Advanced) > Automated captions ON.")
                    .font(ARCTheme.ui(11, .regular)).foregroundStyle(ARCTheme.warn).fixedSize(horizontal: false, vertical: true)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(flexible ? sdk.captions : Array(sdk.captions.suffix(2))) { c in
                            HStack(alignment: .top, spacing: 6) {
                                Text(c.speaker.uppercased()).font(ARCTheme.ui(10, .heavy)).foregroundStyle(ARCTheme.readyGreen).frame(width: ARCTheme.s(110), alignment: .leading).lineLimit(1)
                                Text(c.text).font(ARCTheme.ui(11, .regular)).foregroundStyle(c.final ? ARCTheme.text0 : ARCTheme.textSecondary).lineLimit(flexible ? 4 : 2).fixedSize(horizontal: false, vertical: flexible)
                                Spacer(minLength: 0)
                            }
                            .id(c.id)
                        }
                        if sdk.captions.isEmpty, !sdk.captionsWaiting {
                            Text(sdk.transcriptionStatus == "ON" ? "listening" : "transcript appears here").font(ARCTheme.ui(11, .regular)).foregroundStyle(ARCTheme.textTertiary)
                        }
                    }
                }
                .frame(maxHeight: flexible ? .infinity : 44, alignment: .top)
                .onChange(of: sdk.captions.count) { _, _ in if let last = sdk.captions.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .frame(maxHeight: flexible ? .infinity : nil, alignment: .top)
        .arcModule(title: "CAPTIONS", tint: ARCTheme.secGreen, scale: ARCTheme.uiScale)
        .disabled(sdk.state != .inMeeting)
        .opacity(sdk.state == .inMeeting ? 1 : 0.5)
    }

    private func chip(_ label: String, fill: SwiftUI.Color? = nil, tint: SwiftUI.Color = ARCTheme.text0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(ARCTheme.ui(11, .bold)).lineLimit(1).fixedSize()
                .foregroundStyle(fill == nil ? tint : .white)
                .padding(.horizontal, ARCTheme.s(10)).padding(.vertical, ARCTheme.s(5))
                .background(fill ?? ARCTheme.appGrey)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(fill ?? ARCTheme.line, lineWidth: 1))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

struct CaptionsWindowView: View {
    @Environment(Sidecar.self) private var sidecar
    var body: some View {
        let sdk = sidecar.engine as? SDKZoomEngine
        VStack(alignment: .leading, spacing: 8) {
            if let sdk {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(sdk.spokenLanguages()) { l in Button(l.name) { _ = sdk.setSpokenLanguage(l.id) } }
                    } label: {
                        Text("SPOKEN  \(sdk.spokenLanguage)").font(ARCTheme.ui(11, .bold)).foregroundStyle(ARCTheme.text0).lineLimit(1).frame(width: ARCTheme.s(200), alignment: .leading)
                            .padding(.horizontal, ARCTheme.s(8)).padding(.vertical, ARCTheme.s(5)).background(ARCTheme.appGrey)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1)).cornerRadius(4)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    if let url = sdk.thirdPartyCaptionURL {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) } label: {
                            Text("COPY VENDOR URL").font(ARCTheme.ui(11, .bold)).foregroundStyle(ARCTheme.text0).padding(.horizontal, ARCTheme.s(10)).padding(.vertical, ARCTheme.s(5)).background(ARCTheme.appGrey).cornerRadius(4)
                        }.buttonStyle(.plain).help("The caption API URL a third-party captioner posts to")
                    } else {
                        Text("vendor caption URL: portal setting off").font(ARCTheme.ui(11, .regular)).foregroundStyle(ARCTheme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Text(sdk.transcriptionStatus).font(ARCTheme.ui(11, .heavy)).foregroundStyle(sdk.transcriptionStatus == "ON" ? ARCTheme.readyGreen : ARCTheme.textSecondary)
                }
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(sdk.captions) { c in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(ChatWindowView.clock(c.time)).font(ARCTheme.ui(10, .regular)).foregroundStyle(ARCTheme.textTertiary).frame(width: ARCTheme.s(44), alignment: .leading)
                                    Text(c.speaker.uppercased()).font(ARCTheme.ui(11, .heavy)).foregroundStyle(ARCTheme.readyGreen).frame(width: ARCTheme.s(130), alignment: .leading).lineLimit(1)
                                    Text(c.text).font(ARCTheme.ui(12, .regular)).foregroundStyle(c.final ? ARCTheme.text0 : ARCTheme.textSecondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                                .id(c.id)
                            }
                        }
                        .padding(ARCTheme.s(ARCTheme.modulePad))
                    }
                    .onChange(of: sdk.captions.count) { _, _ in if let last = sdk.captions.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .background(ARCTheme.surface).cornerRadius(4)
            }
        }
        .padding(ARCTheme.railPad)
        .frame(minWidth: 600, minHeight: 360)
        .background(ARCTheme.ink)
    }
}

/// THIS MAC: everything a fresh crew Mac needs before ARC Zoom can run a show, each with its fix on the
/// row (the fresh-Mac rule, 2026-09-16: never depend on anything only the office workstation has). The Marketplace
/// pair goes into the login keychain from here, never from a file; the Zoom sign-in is one browser
/// consent as ARC Tech; the three TCC grants are asked for from here and the screen one needs a
/// relaunch to take.
struct ThisMacModule: View {
    @Environment(Sidecar.self) private var sidecar
    @Environment(\.operatorLayout) private var layout
    @State private var clientID = ""
    @State private var secret = ""
    @State private var tick = 0
    @State private var note = ""
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var credentialsOK: Bool { if case .success = ZoomCredentials.load() { return true } else { return false } }
    private var signedIn: Bool { TokenStore.load().refreshToken != nil }
    private var micOK: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    private var camOK: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    private var screenOK: Bool { CGPreflightScreenCaptureAccess() }
    private var allOK: Bool { credentialsOK && signedIn && micOK && camOK && screenOK }

    var body: some View {
        let _ = tick
        VStack(alignment: .leading, spacing: ARCTheme.s(6)) {
            FlowRow(spacing: ARCTheme.s(6)) {
                lamp("MARKETPLACE APP", credentialsOK, fix: nil) {}
                if credentialsOK {
                    lamp("ZOOM SIGN-IN", signedIn, fix: "SIGN IN AS ARC TECH") {
                        Task { if let sdk = await sidecar.ensureSDK() { _ = await sdk.authorize(); tick += 1 } }
                    }
                }
                lamp("MICROPHONE", micOK, fix: "ASK") { AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in tick += 1 } } }
                lamp("CAMERA", camOK, fix: "ASK") { AVCaptureDevice.requestAccess(for: .video) { _ in Task { @MainActor in tick += 1 } } }
                lamp("SCREEN RECORDING", screenOK, fix: "ASK · RELAUNCH AFTER") { _ = CGRequestScreenCaptureAccess(); tick += 1 }
            }
            if !credentialsOK {
                HStack(spacing: ARCTheme.s(6)) {
                    TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder).frame(minWidth: ARCTheme.s(120), maxWidth: ARCTheme.s(220))
                    SecureField("Client secret", text: $secret).textFieldStyle(.roundedBorder).frame(minWidth: ARCTheme.s(120), maxWidth: ARCTheme.s(220))
                    arcChip("SAVE TO KEYCHAIN") {
                        let creds = ZoomCredentials(clientID: clientID.trimmingCharacters(in: .whitespaces), clientSecret: secret.trimmingCharacters(in: .whitespaces))
                        note = "checking the pair with Zoom…"
                        Task {
                            // A mistyped secret is caught here, not mid show as an opaque SDK auth failure.
                            switch await ZoomCredentials.verify(creds) {
                            case .invalid: note = "Zoom rejected that pair (invalid_client); nothing saved"; return
                            case .unknown(let why): note = "could not check the pair with Zoom (\(why)); nothing saved"; return
                            case .valid: break
                            }
                            let ok = ZoomCredentials.store(creds)
                            note = ok ? "verified and saved; the SDK starts now" : "the keychain refused the pair"
                            if ok { secret = ""; _ = await sidecar.ensureSDK(); tick += 1 }
                        }
                    }
                    .disabled(clientID.isEmpty || secret.isEmpty)
                }
                .help(Self.pairNote)
                // Three lines on a narrow rail; there the same words are the fields' tooltip (2026-09-23).
                if !layout.narrow {
                    Text(Self.pairNote)
                        .font(ARCTheme.ui(10, .regular)).foregroundStyle(ARCTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !note.isEmpty { Text(note).font(ARCTheme.ui(10, .regular)).foregroundStyle(ARCTheme.warn) }
            if !screenOK {
                Text("Screen Recording is what lets ARC Zoom share a window (Presenter's program) into the call. It takes effect only after a relaunch.")
                    .font(ARCTheme.ui(10, .regular)).foregroundStyle(ARCTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .arcSubGroup(allOK ? "this mac · ready" : "this mac · not ready yet")
        .onReceive(timer) { _ in tick += 1 }
    }

    static let pairNote = "The ARC Zoom Marketplace app's Client ID and Client Secret (marketplace.zoom.us, signed in as ARC Tech). They go into this Mac's login keychain and nowhere else."

    /// A lamp when it is right, the fix as a chip when it is not.
    @ViewBuilder
    private func lamp(_ name: String, _ ok: Bool, fix: String?, action: @escaping () -> Void) -> some View {
        if ok {
            HStack(spacing: 4) {
                Circle().fill(ARCTheme.readyGreen).frame(width: ARCTheme.s(7), height: ARCTheme.s(7))
                Text(name).font(ARCTheme.ui(10, .heavy)).foregroundStyle(ARCTheme.text0).fixedSize()
            }
            .padding(.horizontal, ARCTheme.s(6)).padding(.vertical, ARCTheme.s(5))
        } else if let fix {
            arcChip("\(name): \(fix)", tint: ARCTheme.warn, action: action)
        } else {
            HStack(spacing: 4) {
                Circle().fill(ARCTheme.warn).frame(width: ARCTheme.s(7), height: ARCTheme.s(7))
                Text(name).font(ARCTheme.ui(10, .heavy)).foregroundStyle(ARCTheme.warn).fixedSize()
            }
            .padding(.horizontal, ARCTheme.s(6)).padding(.vertical, ARCTheme.s(5))
        }
    }
}
