//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import ARCStyle

// The pop-up windows (2026-09-20): SETTINGS grouped, and ALL PARTICIPANTS with VIP pins. Both are
// ordinary control windows opened from a glyph in the rail, Presenter's way (ControlWindow.toggle).

/// Every setting, in the same grey sub-groups as the rail (2026-09-20 17:55: "give the same
/// attention to the pop up settings window"): MEETING POLICIES · SHARE · AUDIO ROUTING · DEVICES ·
/// NETWORK. Groups sit two to a row where they are short, so the window has no label gutter and no
/// dead space. The rail keeps only what the operator hits during a show.
struct SettingsWindowView: View {
    @Environment(Sidecar.self) private var sidecar
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: ARCTheme.railPad) {
                if let sdk = sidecar.engine as? SDKZoomEngine {
                    policies(sdk)
                    HStack(alignment: .top, spacing: ARCTheme.railPad) {
                        shareSettings(sdk).frame(maxWidth: .infinity, alignment: .topLeading)
                        network(sdk).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    audioRouting(sdk)
                    devices(sdk)
                } else {
                    Text("Settings live on the SDK engine. CREATE MEETING or switch the engine first.")
                        .font(ARCTheme.ui(12, .regular)).foregroundStyle(ARCTheme.textSecondary)
                        .padding(ARCTheme.s(ARCTheme.modulePad))
                        .arcSubGroup()
                }
            }
            .padding(ARCTheme.railPad)
        }
        .frame(minWidth: 820, minHeight: 640)
        .background(ARCTheme.ink)
    }

    // MARK: - Modules

    private func policies(_ sdk: SDKZoomEngine) -> some View {
        let s = sdk.settingsSample
        return VStack(alignment: .leading, spacing: 6) {
            pair {
                group("who may join") {
                    toggle("LOCK MEETING", on: sdk.meetingLocked) { _ = sdk.setLock(!sdk.meetingLocked) }
                        .help("Nobody new can join. The flag follows the command; the SDK has no lock getter.")
                    toggle("WAITING ROOM ON ENTRY", on: s.waitingRoom) { _ = sdk.setWaitingRoomOnEntry(!s.waitingRoom) }
                    toggle("MUTE ON ENTRY", on: s.muteOnEntry) { _ = sdk.setMuteOnEntry(!s.muteOnEntry, allowUnmute: s.allowUnmute) }
                }
            } second: {
                group("microphones") {
                    chip("MUTE ALL") { _ = sdk.muteAll(true) }
                    chip("ASK ALL TO UNMUTE") { _ = sdk.muteAll(false) }
                        .help("Zoom rule: a host can only ASK; each participant accepts")
                    toggle("UNMUTE BY SELF", on: s.allowUnmute) { _ = sdk.allowUnmuteBySelf(!s.allowUnmute) }
                    chip("LOWER ALL HANDS") { _ = sdk.lowerAllHands() }
                }
            }
            pair {
                group("participants may", note: "RENAME, START VIDEO and CHAT follow the last command; the SDK has no getter for them.") {
                    toggle("RENAME", on: sdk.allowRenameLast) { _ = sdk.allowRename(!sdk.allowRenameLast) }
                    toggle("START VIDEO", on: sdk.allowVideoLast) { _ = sdk.allowVideo(!sdk.allowVideoLast) }
                    toggle("CHAT", on: sdk.allowChatLast) { _ = sdk.allowChat(!sdk.allowChatLast) }
                }
            } second: {
                group("share policy") {
                    ForEach([("hostOnly", "HOST ONLY"), ("hostGrab", "ALL, HOST INTERRUPTS"), ("anyone", "ALL, ANYONE INTERRUPTS"), ("multi", "MULTI-SHARE")], id: \.0) { pair in
                        toggle(pair.1, on: s.share == pair.1 || (pair.0 == "hostGrab" && s.share == "HOST GRAB")) { _ = sdk.setSharePolicy(pair.0) }
                    }
                }
            }
            group("layout for attendees", note: s.focusEnabled ? "FOCUS MODE: attendees see only hosts, spotlights and shares. FOLLOW HOST ORDER pushes this roster's order to every gallery." : "Focus mode is not enabled for this account (portal). FOLLOW HOST ORDER pushes this roster's order to every gallery.") {
                toggle("FOCUS MODE", on: s.focus) { _ = sdk.setFocusMode(!s.focus) }.disabled(!s.focusEnabled)
                toggle("FOLLOW HOST ORDER", on: s.followOrder) {
                    if s.followOrder { _ = sdk.stopFollowHostOrder() } else { _ = sdk.pushVideoOrder(sidecar.orderedRoster.filter { !$0.isMe }.map(\.id)) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcModule(title: "MEETING POLICIES", tint: ARCTheme.secBlue, scale: ARCTheme.uiScale)
    }

    private func shareSettings(_ sdk: SDKZoomEngine) -> some View {
        group("when arc zoom shares", note: "Applied at share start; SHARE SOUND also live when the SDK allows.") {
            toggle("SHARE SOUND", on: sdk.shareSound) { sdk.shareSound.toggle() }
            toggle("OPTIMISE FOR VIDEO", on: sdk.shareOptimizeVideo) { sdk.shareOptimizeVideo.toggle() }
            toggle("STEREO", on: sdk.shareStereo) { sdk.shareStereo.toggle() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcModule(title: "SHARE", tint: ARCTheme.secCrimson, scale: ARCTheme.uiScale)
    }

    private func audioRouting(_ sdk: SDKZoomEngine) -> some View {
        let so = sdk.soundSample
        return VStack(alignment: .leading, spacing: 6) {
            pair {
                group("config", note: "BASIC: this Mac plays the call into the room, AEC on. CONSOLE / SPLIT: the desk carries the return.") {
                    ForEach(["basic", "console", "split"], id: \.self) { name in
                        toggle(name.uppercased(), on: sdk.audioConfig == name) { sdk.applyAudioConfig(name, mixMinus: nil) }
                    }
                    toggle("MIC IS A MIX-MINUS AUX", on: sdk.micIsMixMinus) { sdk.applyAudioConfig(sdk.audioConfig, mixMinus: !sdk.micIsMixMinus) }
                        .help("Assert that the input excludes the Zoom return; unlocks MUSIC in BASIC")
                }
            } second: {
                group("preset", note: "MUSIC = original sound, hi-fi, stereo, no gain riding, noise LOW.") {
                    toggle("SPEECH", on: sdk.soundPreset == "speech") { _ = sdk.applyPreset("speech") }
                    toggle("MUSIC", on: sdk.soundPreset == "music") { _ = sdk.applyPreset("music") }
                }
            }
            pair {
                group("processing") {
                    toggle("ORIGINAL SOUND", on: so.original) { _ = sdk.setSound(original: !so.original, hifi: nil, stereo: nil, noise: nil, agc: nil) }
                    toggle("HI-FI MUSIC", on: so.hifi) { _ = sdk.setSound(original: nil, hifi: !so.hifi, stereo: nil, noise: nil, agc: nil) }
                    toggle("STEREO", on: so.stereo) { _ = sdk.setSound(original: nil, hifi: nil, stereo: !so.stereo, noise: nil, agc: nil) }
                    toggle("AUTO GAIN", on: so.agc) { _ = sdk.setSound(original: nil, hifi: nil, stereo: nil, noise: nil, agc: !so.agc) }
                }
            } second: {
                group("noise suppression") {
                    ForEach(["auto", "low", "medium", "high"], id: \.self) { n in
                        toggle(n.uppercased(), on: so.noise == n.uppercased()) { _ = sdk.setSound(original: nil, hifi: nil, stereo: nil, noise: n, agc: nil) }
                    }
                }
            }
            group("sidecar speaker", note: "BASIC plays the call into the room from this Mac; CONSOLE and SPLIT keep it silent.") {
                toggle(sdk.speakerOutputOn ? "PLAYING THE CALL" : "SILENT", on: sdk.speakerOutputOn) { _ = sdk.setSpeakerOutput(!sdk.speakerOutputOn) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcModule(title: "AUDIO ROUTING", tint: ARCTheme.secBlue, scale: ARCTheme.uiScale)
    }

    private func devices(_ sdk: SDKZoomEngine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            group("microphone · the mic the call hears") {
                ForEach(sdk.audioDeviceList(mic: true)) { d in toggle(d.name, on: d.selected) { _ = sdk.selectAudio(mic: true, id: d.id) } }
            }
            group("speaker · the call into the room") {
                ForEach(sdk.audioDeviceList(mic: false)) { d in toggle(d.name, on: d.selected) { _ = sdk.selectAudio(mic: false, id: d.id) } }
            }
            pair {
                group("camera") {
                    Text(sdk.selectedCamera ?? "?").font(ARCTheme.ui(12, .bold)).foregroundStyle(ARCTheme.text0).lineLimit(1)
                    chip("INSTA360") { _ = sdk.selectDevices(cameraMatch: "Insta360 Link", micMatch: nil) }
                    toggle("SEND VIDEO", on: sdk.sendsOwnVideo) { sdk.sendsOwnVideo.toggle(); _ = sdk.setOwnVideo(on: sdk.sendsOwnVideo) }
                    toggle("BLUR", on: sdk.soundSample.blur) { _ = sdk.setBlur(!sdk.soundSample.blur) }.disabled(!sdk.blurSupported)
                }
            } second: {
                group("video quality", note: "Receivers decide the resolution they pull; 1080p also needs the account's Group HD setting.") {
                    toggle("HD CAPTURE (720p ceiling)", on: sdk.hdCapture) { sdk.hdCapture.toggle() }
                    toggle(sdk.smoothVideo ? "SMOOTH 24-30 FPS" : "SHARPNESS FIRST", on: sdk.smoothVideo) { sdk.smoothVideo.toggle() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcModule(title: "DEVICES", tint: ARCTheme.secGreen, scale: ARCTheme.uiScale)
    }

    private func network(_ sdk: SDKZoomEngine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            group("venue network", note: "Off unless the venue inspects SSL; a refused certificate is reported, never silently trusted.") {
                toggle("TRUST VENUE CERTIFICATES", on: sdk.trustVenueCertificates) { sdk.trustVenueCertificates.toggle() }
            }
            group("unattended handlers") {
                Text(sdk.unattended.applied.isEmpty ? "not yet applied (they apply after the SDK authenticates)" : sdk.unattended.applied.joined(separator: " · "))
                    .font(ARCTheme.ui(11, .regular)).foregroundStyle(ARCTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if !sdk.prompts.isEmpty {
                group("prompts answered") {
                    Text(sdk.prompts.suffix(6).joined(separator: "\n")).font(ARCTheme.ui(11, .regular)).foregroundStyle(ARCTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcModule(title: "NETWORK · UNATTENDED", tint: ARCTheme.secOrange, scale: ARCTheme.uiScale)
    }

    // MARK: - Bits

    /// Two groups side by side, equal widths.
    private func pair<A: View, B: View>(@ViewBuilder _ first: () -> A, @ViewBuilder second: () -> B) -> some View {
        HStack(alignment: .top, spacing: 6) {
            first().frame(maxWidth: .infinity, alignment: .topLeading)
            second().frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
    /// A labelled grey group of chips, with an optional one-line note beneath the chips.
    private func group<Content: View>(_ label: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            FlowRow(spacing: ARCTheme.s(6)) { content() }
            if let note {
                Text(note).font(ARCTheme.ui(10, .regular)).foregroundStyle(ARCTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .arcSubGroup(label)
    }
    private func toggle(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        arcChip(label, fill: on ? ARCTheme.secBlue : nil, action: action)
    }
    private func chip(_ label: String, action: @escaping () -> Void) -> some View { arcChip(label, action: action) }
}

/// Everyone in the meeting and the waiting room, with PIN for VIPs, in the same order as the rail.
struct ParticipantsWindowView: View {
    @Environment(Sidecar.self) private var sidecar

    var body: some View {
        let sdk = sidecar.engine as? SDKZoomEngine
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: ARCTheme.railPad) {
                if let sdk, !sdk.waitingRoomIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sdk.waitingRoom()) { p in
                            HStack(spacing: 8) {
                                Circle().fill(ARCTheme.warn).frame(width: ARCTheme.s(8), height: ARCTheme.s(8))
                                Text(p.displayName).font(ARCTheme.ui(13, .bold)).foregroundStyle(ARCTheme.text0).frame(width: ARCTheme.s(220), alignment: .leading).lineLimit(1)
                                chip("ADMIT", tint: ARCTheme.readyGreen) { Task { _ = await sdk.admit(p.id) } }
                                Spacer(minLength: 0)
                            }
                            .frame(height: ARCTheme.s(26))
                        }
                        chip("ADMIT ALL", tint: ARCTheme.readyGreen) { Task { _ = await sdk.admit(nil) } }
                    }
                    .arcSubGroup("waiting room  \(sdk.waitingRoomIDs.count)")
                }
                VStack(alignment: .leading, spacing: 4) {
                    if sidecar.roster.isEmpty {
                        Text("not in a meeting").font(ARCTheme.ui(11, .regular)).foregroundStyle(ARCTheme.textTertiary)
                    }
                    ForEach(sidecar.orderedRoster) { p in row(p, sdk: sdk) }
                }
                .arcSubGroup("in the meeting  \(sidecar.roster.count) · PIN keeps a VIP at the top of the rail")
            }
            .padding(ARCTheme.railPad)
        }
        .frame(minWidth: 760, minHeight: 420)
        .background(ARCTheme.ink)
    }

    private func row(_ p: Participant, sdk: SDKZoomEngine?) -> some View {
        let isProgram = p.id == sidecar.programID
        let vip = sidecar.isVIP(p.id)
        let talking = sdk?.talking.contains(p.id) ?? false
        let hand = sdk?.raisedHands.contains(p.id) ?? false
        return HStack(spacing: 8) {
            chip(vip ? "★ VIP" : "PIN", fill: vip ? ARCTheme.secOrange : nil) { sidecar.toggleVIP(p.id) }
                .help(vip ? "Unpin" : "Pin to the top of the roster")
            Circle().fill(p.videoOn ? ARCTheme.readyGreen : ARCTheme.textTertiary).frame(width: ARCTheme.s(8), height: ARCTheme.s(8))
            Text(p.displayName).font(ARCTheme.ui(13, .bold)).foregroundStyle(ARCTheme.text0)
                .frame(width: ARCTheme.s(200), alignment: .leading).lineLimit(1).truncationMode(.middle)
            Text(p.isMe ? "ME" : (p.isHost ? "HOST" : (p.isCoHost ? "CO-HOST" : (talking ? "TALKING" : (hand ? "✋" : "")))))
                .font(ARCTheme.ui(10, .heavy)).foregroundStyle(talking ? ARCTheme.readyGreen : ARCTheme.textSecondary).frame(width: ARCTheme.s(64), alignment: .leading)
            chip(isProgram ? "ON PROGRAM" : "TO PROGRAM", fill: isProgram ? ARCTheme.liveRed : nil) { sidecar.setProgram(p.id) }.disabled(p.isMe)
            chip(p.isSpotlighted ? "SPOTLIT" : "SPOTLIGHT", fill: p.isSpotlighted ? ARCTheme.secBlue : nil) { Task { await sidecar.spotlight(p.id, on: !p.isSpotlighted) } }
            chip(p.audioOn ? "MUTE" : "ASK UNMUTE") { Task { _ = await sidecar.engine.mute(p.id, on: p.audioOn) } }
            if let sdk, !p.isMe, sdk.amHost {
                chip(p.isCoHost ? "REVOKE CO-HOST" : "CO-HOST") { _ = p.isCoHost ? sdk.revokeCoHost(p.id) : sdk.assignCoHost(p.id) }
                    .help("Make \(p.displayName) co-host")
            }
            Spacer(minLength: 0)
        }
        .frame(height: ARCTheme.s(26))
    }

    private func chip(_ label: String, tint: SwiftUI.Color = ARCTheme.text0, fill: SwiftUI.Color? = nil, action: @escaping () -> Void) -> some View { arcChip(label, tint: tint, fill: fill, action: action) }
}

/// Chips that wrap onto the next line instead of pushing the window wider (Presenter's rule: the rail
/// never sets the window's width).
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

/// The whole show log, newest last, opened from the glyph in the header (2026-09-21: "add a
/// button to expand the log"). COPY puts it on the clipboard for a bug report.
struct LogWindowView: View {
    @State private var tick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        let lines = ShowLog.recent(500)
        VStack(alignment: .leading, spacing: ARCTheme.railPad) {
            HStack(spacing: ARCTheme.s(6)) {
                arcChip("COPY") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                .help("Every line to the clipboard")
                Text("\(lines.count) lines · newest last · \(ShowLog.url.path)").font(ARCTheme.ui(10, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(ARCTheme.ui(10, line.contains("ERROR") ? .bold : .regular))
                                .foregroundStyle(line.contains("ERROR") ? ARCTheme.liveRed : ARCTheme.text0)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .id(i)
                        }
                    }
                    .padding(ARCTheme.s(ARCTheme.modulePad))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .arcSubGroup()
                .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                .onReceive(timer) { _ in tick += 1; proxy.scrollTo(max(0, lines.count - 1), anchor: .bottom) }
            }
        }
        .padding(ARCTheme.railPad)
        .frame(minWidth: 760, minHeight: 480)
        .background(ARCTheme.ink)
    }
}

