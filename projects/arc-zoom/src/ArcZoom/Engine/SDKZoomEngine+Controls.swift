//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ZoomSDK

// Phase A controls (PLAN_controls.md): health, the host's SETTINGS, and SOUND. All API-first: the
// operator surface is ARC Presenter, this file only has to be right and say what it did.

// MARK: - Health

extension SDKZoomEngine {
    /// Everything the SDK will tell us about the connection, computed on request. Presenter polls it at
    /// 1 Hz. Self statistics are polled getters; per-user quality comes from events (SDKZoomEngine+Events).
    var healthJSON: String {
        let sdk = ZoomSDK.shared()
        var parts: [String] = []
        parts.append("\"state\":\"\(state.rawValue)\",\"authenticated\":\(isAuthenticated),\"coHostNeeded\":\(coHostNeeded)")
        if let st = sdk.getSettingService()?.getStatisticsSetting() {
            let conn: String
            switch st.getConnectionType() {
            case SettingConnectionType_P2P: conn = "P2P"
            case SettingConnectionType_Cloud: conn = "Cloud"
            default: conn = "Unknown"
            }
            let net: String
            switch st.getNetworkType() {
            case SettingNetworkType_Wired: net = "Wired"
            case SettingNetworkType_WiFi: net = "WiFi"
            case SettingNetworkType_PPP: net = "PPP"
            case SettingNetworkType_3G: net = "3G"
            case SettingNetworkType_Other: net = "Other"
            default: net = "Unknown"
            }
            parts.append("\"connection\":\"\(conn)\",\"network\":\"\(net)\",\"proxy\":\(st.getProxyAddress().map { "\"\(jsonEscape($0))\"" } ?? "null")")
            if let a = st.getAudioStatisticInfo() {
                parts.append("\"audio\":{\"send\":{\"kHz\":\(a.sendFrequency),\"rtt\":\(a.sendRTT),\"jitter\":\(a.sendJitter),\"lossAvg\":\(a.sendPacketLossAvg),\"lossMax\":\(a.sendPacketLossMax),\"kbps\":\(a.sendBandwidth)},"
                             + "\"recv\":{\"kHz\":\(a.recvFrequency),\"rtt\":\(a.recvRTT),\"jitter\":\(a.recvJitter),\"lossAvg\":\(a.recvPacketLossAvg),\"lossMax\":\(a.recvPacketLossMax),\"kbps\":\(a.recvBandwidth)}}")
            }
            func asv(_ name: String, _ v: ZoomSDKASVStatisticInfo?) {
                guard let v else { return }
                func res(_ r: Int) -> String { "\"w\":\(r & 0xFFFF),\"h\":\(r >> 16)" }
                parts.append("\"\(name)\":{\"send\":{\"kbps\":\(v.sendBandwidth),\"fps\":\(v.sendFps),\"rtt\":\(v.sendRTT),\"jitter\":\(v.sendJitter),\"lossAvg\":\(v.sendPacketLossAvg),\"lossMax\":\(v.sendPacketLossMax),\(res(v.sendResolution))},"
                             + "\"recv\":{\"kbps\":\(v.recvBandwidth),\"fps\":\(v.recvFps),\"rtt\":\(v.recvRTT),\"jitter\":\(v.recvJitter),\"lossAvg\":\(v.recvPacketLossAvg),\"lossMax\":\(v.recvPacketLossMax),\(res(v.recvResolution))}}")
            }
            asv("video", st.getVideoStatisticInfo())
            asv("share", st.getShareStatisticInfo())
        }
        if let m = sdk.getMeetingService(), state == .inMeeting {
            let comps: [(String, ConnectionComponent)] = [("audio", ConnectionComponent_Audio), ("video", ConnectionComponent_Video), ("share", ConnectionComponent_Share)]
            let selfQ = comps.flatMap { name, c in
                ["\"\(name).up\":\"\(Self.qualityName(m.getConnectionQuality(c, sending: true)))\"",
                 "\"\(name).down\":\"\(Self.qualityName(m.getConnectionQuality(c, sending: false)))\""]
            }.joined(separator: ",")
            parts.append("\"selfQuality\":{\(selfQ)},\"dataCenter\":\"\(jsonEscape(m.getInMeetingDataCenterInfo()))\"")
        }
        let users = userQuality.map { uid, comps in
            "\"\(uid)\":{" + comps.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",") + "}"
        }.joined(separator: ",")
        parts.append("\"users\":{\(users)},\"warning\":\(lastWarning.map { "\"\($0)\"" } ?? "null")")
        parts.append("\"talking\":[\(talking.sorted().map(String.init).joined(separator: ","))],\"hands\":[\(raisedHands.sorted().map(String.init).joined(separator: ","))]")
        parts.append("\"video\":\(videoJSON)".replacingOccurrences(of: "\"video\":{\"subscriptions\"", with: "\"subscriptions\":{\"list\""))
        return "{" + parts.joined(separator: ",") + "}"
    }
}

// MARK: - SETTINGS: the host's meeting-wide policies

extension SDKZoomEngine {
    /// The SDK has no lock getter and `onMeetingLockStatus:` stayed silent in the 2026-09-20 measurement,
    /// so the flag follows the accepted command until an event contradicts it.
    func assignCoHost(_ id: UInt32) -> Bool { apply("co-host: \(id)", act?.assignCoHost(id)) }
    func revokeCoHost(_ id: UInt32) -> Bool { apply("co-host revoked: \(id)", act?.revokeCoHost(id)) }

    func setLock(_ on: Bool) -> Bool {
        let ok = action(on ? ActionMeetingCmd_LockMeeting : ActionMeetingCmd_UnLockMeeting, user: myID ?? 0, what: on ? "lock meeting" : "unlock meeting")
        if ok { meetingLocked = on }
        return ok
    }
    func muteAll(_ on: Bool) -> Bool { action(on ? ActionMeetingCmd_MuteAll : ActionMeetingCmd_UnmuteAll, user: myID ?? 0, what: on ? "mute all" : "ask all to unmute") }
    func allowUnmuteBySelf(_ on: Bool) -> Bool { action(on ? ActionMeetingCmd_EnableUnmuteBySelf : ActionMeetingCmd_DisableUnmuteBySelf, user: myID ?? 0, what: "unmute by self \(on ? "allowed" : "blocked")") }
    func allowShare(_ on: Bool) -> Bool { apply("participants may share: \(on)", act?.allowParticipants(toShare: on)) }
    func allowRename(_ on: Bool) -> Bool { let ok = apply("participants may rename: \(on)", act?.allowParticipants(toRename: on)); if ok { allowRenameLast = on }; return ok }
    func allowVideo(_ on: Bool) -> Bool { let ok = apply("participants may start video: \(on)", act?.allowParticipants(toStartVideo: on)); if ok { allowVideoLast = on }; return ok }
    func allowChat(_ on: Bool) -> Bool { let ok = apply("participants may chat: \(on)", act?.allowParticipants(toChat: on)); if ok { allowChatLast = on }; return ok }
    /// Stop pushing the host's gallery order (the toggle only ever turned it ON before).
    func stopFollowHostOrder() -> Bool { apply("follow host video order: off", act?.enableFollowHostVideoOrder(false)) }
    func setWaitingRoomOnEntry(_ on: Bool) -> Bool { apply("waiting room on entry: \(on)", ZoomSDK.shared().getMeetingService()?.getWaitingRoomController().enableWaitingRoom(onEntry: on)) }
    func setMuteOnEntry(_ on: Bool, allowUnmute: Bool) -> Bool { apply("mute on entry: \(on), unmute by self: \(allowUnmute)", ZoomSDK.shared().getSettingService()?.getGeneralSetting()?.enableMute(onEntry: on, allowUnmuteBySelf: allowUnmute)) }
    func setTopic(_ topic: String) -> Bool {
        guard act?.canSetMeetingTopic() == true else { lastError = "the topic cannot be set here (host only, and only in some meetings)"; return false }
        let ok = apply("topic: \(topic)", act?.setMeetingTopic(topic)); if ok { meetingTopic = topic }; return ok
    }
    func lowerAllHands() -> Bool { let ok = apply("all hands lowered", act?.lowerAllHands(false)); if ok { raisedHands = [] }; return ok }
    func setFocusMode(_ on: Bool) -> Bool {
        guard act?.isFocusModeEnabled() == true else { lastError = "focus mode is not enabled for this account (portal setting)"; return false }
        return apply("focus mode: \(on)", act?.turnFocusMode(on: on))
    }
    /// hostOnly | hostGrab | anyone | multi
    func setSharePolicy(_ name: String) -> Bool {
        let t: ZoomSDKShareSettingType
        switch name.lowercased() {
        case "hostonly": t = ShareSettingType_OnlyHostCanShare
        case "hostgrab": t = ShareSettingType_OnlyHostCanGrab
        case "anyone": t = ShareSettingType_AnyoneCanGrab
        case "multi": t = ShareSettingType_MultiShare
        default: lastError = "share policy must be hostOnly|hostGrab|anyone|multi"; return false
        }
        return apply("share policy: \(name)", act?.setShareSettingType(t))
    }
    /// The one true attendees' layout: a gallery order every follower sees.
    func pushVideoOrder(_ ids: [UInt32]) -> Bool {
        guard act?.isSupportFollowHostVideoOrder() == true else { lastError = "follow-host video order is not supported in this meeting"; return false }
        _ = act?.enableFollowHostVideoOrder(true)
        return apply("video order pushed: \(ids)", act?.setVideoOrder(ids.map { NSNumber(value: $0) }))
    }

    var settingsJSON: String {
        guard let a = act, state == .inMeeting else { return "{\"state\":\"\(state.rawValue)\"}" }
        var share = ShareSettingType_None
        _ = a.getShareSettingType(&share)
        let shareName: String
        switch share {
        case ShareSettingType_OnlyHostCanShare: shareName = "hostOnly"
        case ShareSettingType_OnlyHostCanGrab: shareName = "hostGrab"
        case ShareSettingType_AnyoneCanGrab: shareName = "anyone"
        case ShareSettingType_MultiShare: shareName = "multi"
        default: shareName = "none"
        }
        let wr = ZoomSDK.shared().getMeetingService()?.getWaitingRoomController()
        let order = (a.getVideoOrderList() ?? []).map { "\($0.uint32Value)" }.joined(separator: ",")
        return "{\"locked\":\(meetingLocked),\"muteOnEntry\":\(a.isMuteOnEntryEnabled()),\"allowUnmute\":\(a.isParticipantsUnmuteSelfAllowed()),"
            + "\"allowRename\":\(a.isParticipantsRenameAllowed()),\"allowVideo\":\(a.isParticipantsStartVideoAllowed()),"
            + "\"waitingRoom\":\(wr?.isEnableWaitingRoomOnEntry() ?? false),\"share\":\"\(shareName)\","
            + "\"focusEnabled\":\(a.isFocusModeEnabled()),\"focus\":\(a.isFocusModeOn()),"
            + "\"followHostOrder\":\(a.isFollowHostVideoOrderOn()),\"order\":[\(order)],"
            + "\"topic\":\(meetingTopic.map { "\"\(jsonEscape($0))\"" } ?? "null"),\"canSetTopic\":\(a.canSetMeetingTopic()),"
            + "\"amHost\":\(amHost),\"amCoHost\":\(amCoHost),\"coHostNeeded\":\(coHostNeeded)}"
    }
}

// MARK: - SOUND: audio config, speaker output, presets, meters

extension SDKZoomEngine {
    private var audioSetting: ZoomSDKAudioSetting? { ZoomSDK.shared().getSettingService()?.getAudioSetting() }

    /// BASIC: the sidecar's speaker IS the room feed, so it plays. CONSOLE / SPLIT: the console carries
    /// the return, so the sidecar stays silent. Returns what it did.
    @discardableResult
    func applyAudioConfig(_ name: String, mixMinus: Bool?) -> [String] {
        guard ["basic", "console", "split"].contains(name.lowercased()) else { lastError = "audio config must be basic|console|split"; return [] }
        audioConfig = name.lowercased()
        if let m = mixMinus { micIsMixMinus = m }
        var did = ["config \(audioConfig)", "mix-minus mic: \(micIsMixMinus)"]
        if state == .inMeeting {
            let speakerOn = audioConfig == "basic"
            if setSpeakerOutput(speakerOn) { did.append("speaker output \(speakerOn ? "ON" : "OFF")") }
        }
        if soundPreset == "music", audioConfig == "basic", !micIsMixMinus {
            _ = applyPreset("speech"); did.append("MUSIC dropped to SPEECH: BASIC without a mix-minus mic would echo to every remote")
        }
        ShowLog.log("audio: " + did.joined(separator: ", "))
        return did
    }

    func setSpeakerOutput(_ on: Bool) -> Bool { apply("sidecar speaker output: \(on)", act?.enablePlayMeetingAudio(on)) }
    var speakerOutputOn: Bool { act?.isPlayMeetingAudioEnabled() ?? true }

    /// The mic slider (2026-09-24: "mic turned all the way down and still sending"). Three fixes:
    /// auto gain is switched OFF first (it raised the level straight back: the log read 81 after 0); the
    /// level is read back and a device that ignores it (USB webcams often have no hardware gain) is
    /// flagged instead of pretending; and 0 mutes the sidecar in the call, a value above 0 undoes a mute
    /// the slider made, so zero always means silent.
    func setVolume(mic: Bool, _ v: Float) -> Bool {
        let v = max(0, min(100, v))
        if mic {
            micLevelManual = true
            if audioSetting?.isAutoAdjustMicOn() == true { put("auto gain off (manual mic level)", audioSetting?.enableAutoAdjustMic(false)) }
        }
        let ok = apply("\(mic ? "mic" : "speaker") volume \(Int(v))", audioSetting?.setAudioDeviceVolume(mic, volume: v))
        if mic {
            if state == .inMeeting {
                if v == 0, !micMutedBySlider, ownAudioOn { micMutedBySlider = setOwnAudio(on: false) }
                else if v > 0, micMutedBySlider { micMutedBySlider = false; _ = setOwnAudio(on: true) }
            }
            micLevelTarget = v
            micLevelCheck?.cancel()
            micLevelCheck = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled, let read = self.audioSetting?.getAudioDeviceVolume(true) else { return }
                let ignored = abs(read - v) > 5
                if ignored != self.micGainIgnored {
                    self.micGainIgnored = ignored
                    ShowLog.log(ignored ? "mic device ignores its level (set \(Int(v)), reads \(Int(read))): no hardware gain" : "mic device follows its level again")
                }
            }
        }
        if state != .inMeeting { sampleSound() }
        return ok
    }

    /// Is our own audio in the call open (joined and unmuted), from the polled roster.
    var ownAudioOn: Bool { participants.first(where: { $0.isMe })?.audioOn == true }

    private func put(_ what: String, _ e: ZoomSDKError?) { _ = apply(what, e) }

    /// MUSIC: original sound, hi-fi, stereo, noise suppression off, auto gain off. SPEECH: the inverse.
    /// MUSIC is refused in BASIC unless the mic is asserted mix-minus (PLAN_controls.md 3.9).
    @discardableResult
    func applyPreset(_ name: String) -> (ok: Bool, notes: [String]) {
        switch name.lowercased() {
        case "music":
            if audioConfig == "basic", !micIsMixMinus {
                lastError = "MUSIC refused in BASIC: the mic is not a mix-minus source, so echo cancellation must stay on. Assert mixMinus=1 on /audio/config if the input is a console aux."
                return (false, [lastError!])
            }
            // Original sound first, then its sub-options.
            var notes = setSound(original: true, hifi: nil, stereo: nil, noise: nil, agc: nil)
            // "none" is not a level the SDK keeps (set ok, reads back Auto, measured 2026-09-20); LOW is the
            // floor, and original sound bypasses suppression anyway.
            notes += setSound(original: nil, hifi: true, stereo: true, noise: "low", agc: false)
            soundPreset = "music"; return (true, notes)
        case "speech":
            // Order matters: hi-fi and stereo are sub-options of original sound and answer WrongUsage
            // once it is off (measured 2026-09-20), so they go first; noise and gain are independent.
            var notes = setSound(original: nil, hifi: false, stereo: false, noise: nil, agc: nil)
            // Auto gain stays OFF once the operator has set the mic level by hand: SPEECH is re-applied on every
            // audio join (MIC OPEN), and it switched auto gain back on over a manual level (live, 2026-09-24).
            notes += setSound(original: false, hifi: nil, stereo: nil, noise: "auto", agc: !micLevelManual)
            soundPreset = "speech"; return (true, notes)
        default:
            lastError = "preset must be music|speech"; return (false, [lastError!])
        }
    }

    /// Individual toggles; nil leaves a setting alone. Returns one line per setting with the result.
    func setSound(original: Bool?, hifi: Bool?, stereo: Bool?, noise: String?, agc: Bool?) -> [String] {
        var notes: [String] = []
        func put(_ what: String, _ e: ZoomSDKError?) { notes.append("\(what): \(e == ZoomSDKError_Success ? "ok" : (e.map(Self.name(for:)) ?? "no service"))") }
        if let o = original {
            if act?.isSupportUseOriginalSound() == true { put("original sound \(o)", act?.enableUseOriginalSound(o)) }
            else { notes.append("original sound: not supported here") }
        }
        if let h = hifi { put("hi-fi music mode \(h)", audioSetting?.setHighFideMusicMode(h)) }
        if let s = stereo { put("stereo \(s)", audioSetting?.enableStero(s)) }
        if let n = noise {
            let level: ZoomSDKSuppressBackgroundNoiseLevel
            switch n.lowercased() {
            case "none": level = ZoomSDKSuppressBackgroundNoiseLevel_None
            case "low": level = ZoomSDKSuppressBackgroundNoiseLevel_Low
            case "medium": level = ZoomSDKSuppressBackgroundNoiseLevel_Medium
            case "high": level = ZoomSDKSuppressBackgroundNoiseLevel_High
            default: level = ZoomSDKSuppressBackgroundNoiseLevel_Auto
            }
            put("noise suppression \(n)", audioSetting?.setSuppressBackgroundNoise(level))
        }
        if let a = agc { put("auto gain \(a)", audioSetting?.enableAutoAdjustMic(a)) }
        if !notes.isEmpty { ShowLog.log("sound: " + notes.joined(separator: ", ")) }
        return notes
    }

    var soundJSON: String {
        let a = audioSetting
        let noise: String
        switch a?.getSuppressBackgroundNoiseLevel() {
        case ZoomSDKSuppressBackgroundNoiseLevel_None: noise = "none"
        case ZoomSDKSuppressBackgroundNoiseLevel_Low: noise = "low"
        case ZoomSDKSuppressBackgroundNoiseLevel_Medium: noise = "medium"
        case ZoomSDKSuppressBackgroundNoiseLevel_High: noise = "high"
        default: noise = "auto"
        }
        let d = audioDevices
        return "{\"config\":\"\(audioConfig)\",\"mixMinus\":\(micIsMixMinus),\"preset\":\"\(soundPreset)\","
            + "\"original\":\(act?.isUseOriginalSoundOn() ?? false),\"originalSupported\":\(act?.isSupportUseOriginalSound() ?? false),"
            + "\"hifi\":\(a?.isHighFideMusicMode() ?? false),\"stereo\":\(a?.isEnableStereoOn() ?? false),\"noise\":\"\(noise)\",\"noiseRaw\":\(a?.getSuppressBackgroundNoiseLevel().rawValue ?? 99),\"agc\":\(a?.isAutoAdjustMicOn() ?? false),"
            + "\"speakerOutput\":\(speakerOutputOn),\"micVolume\":\(a?.getAudioDeviceVolume(true) ?? -1),\"speakerVolume\":\(a?.getAudioDeviceVolume(false) ?? -1),"
            + "\"mic\":\"\(jsonEscape(Self.deviceLabel(d.mic, input: true)))\",\"speaker\":\"\(jsonEscape(Self.deviceLabel(d.speaker, input: false)))\",\"camera\":\"\(jsonEscape(selectedCamera ?? "?"))\","
            + "\"heldCamera\":\(micKeeper.heldCamera.map { "\"\(jsonEscape($0))\"" } ?? "null"),"
            + "\"micLevel\":\(micLevel),\"speakerLevel\":\(speakerLevel),\"micTest\":\(micTestRunning),\"speakerTest\":\(speakerTestRunning)}"
    }

    /// mic: start | stop | play ; speaker: start | stop. Levels arrive on the test delegate.
    func audioTest(mic: String?, speaker: String?) -> [String] {
        var notes: [String] = []
        if let cmd = mic, let helper = audioSetting?.getMicrophoneTestHelper() {
            helper.delegate = self
            let id = (audioSetting?.getAudioDeviceList(true) as? [SDKDeviceInfo])?.first { $0.isSelectedDevice() }?.getDeviceID() ?? ""
            switch cmd {
            case "start": micTestRunning = helper.startRecordingMic(id) == ZoomSDKError_Success; notes.append("mic test \(micTestRunning ? "recording" : "refused")")
            case "stop": _ = helper.stopRecrodingMic(); micTestRunning = false; notes.append("mic test stopped")
            case "play": notes.append("mic playback \(helper.playRecordedMic() == ZoomSDKError_Success ? "playing" : "refused")")
            default: notes.append("mic test wants start|stop|play")
            }
        }
        if let cmd = speaker, let helper = audioSetting?.getSpeakerTestHelper() {
            helper.delegate = self
            let id = (audioSetting?.getAudioDeviceList(false) as? [SDKDeviceInfo])?.first { $0.isSelectedDevice() }?.getDeviceID() ?? ""
            switch cmd {
            case "start": speakerTestRunning = helper.speakerStartPlaying(id) == ZoomSDKError_Success; notes.append("speaker tone \(speakerTestRunning ? "playing" : "refused")")
            case "stop": _ = helper.speakerStopPlaying(); speakerTestRunning = false; notes.append("speaker tone stopped")
            default: notes.append("speaker test wants start|stop")
            }
        }
        ShowLog.log("audio test: " + notes.joined(separator: ", "))
        return notes
    }
}

extension SDKZoomEngine: ZoomSDKSettingTestAudioDelegate {
    @objc(onMicLevelChanged:)
    nonisolated func onMicLevelChanged(_ level: UInt32) { Task { @MainActor in self.micLevel = level } }
    @objc(onSpeakerLevelChanged:)
    nonisolated func onSpeakerLevelChanged(_ level: UInt32) { Task { @MainActor in self.speakerLevel = level } }
}

// MARK: - Own picture: background blur (2026-09-20: "microphone mute, turn off video and blur background")

extension SDKZoomEngine {
    private var virtualBG: ZoomSDKVirtualBackgroundSetting? { ZoomSDK.shared().getSettingService()?.getVirtualBGSetting() }
    private var bgItems: [ZoomSDKVirtualBGImageInfo] { (virtualBG?.getBGItemList() as? [ZoomSDKVirtualBGImageInfo]) ?? [] }
    var blurSupported: Bool { virtualBG?.isSupportVirtualBG() ?? false }
    /// Read from the SDK's own list: the selected item is the Blur one.
    var blurOn: Bool { bgItems.first { $0.isSelected() }.map { ($0.getImageName() ?? "").lowercased().contains("blur") } ?? false }
    var backgroundItemNames: [String] { bgItems.map { "\($0.getImageName() ?? "?")\($0.isSelected() ? " (selected)" : "")" } }
    var blurDiagnostics: String {
        guard let vb = virtualBG else { return "{}" }
        return "{\"smartVB\":\(vb.isDeviceSupportSmartVirtualBG()),\"greenScreen\":\(vb.isUsingGreenScreenOn()),\"wanted\":\(wantBlur)}"
    }
    /// The SDK resets the background to None for every new meeting (measured 17:02), so the choice is
    /// remembered here and re-applied when the meeting is up.
    func reapplyBlurIfWanted() { if wantBlur, !blurOn { _ = setBlur(true) } }
    /// Blur is one of the SDK's built-in background items; OFF selects the "None" item.
    func setBlur(_ on: Bool) -> Bool {
        guard let vb = virtualBG, vb.isSupportVirtualBG() else { lastError = "virtual background is not supported on this Mac or account"; return false }
        let items = bgItems
        let target = on
            ? items.first { ($0.getImageName() ?? "").lowercased().contains("blur") }
            : (items.first { ($0.getImageName() ?? "").lowercased() == "none" } ?? items.first)
        guard let target else { lastError = on ? "the SDK's background list has no Blur item (\(backgroundItemNames))" : "no None item"; return false }
        // Blur needs the smart (segmentation) path; a green-screen setting left on would key on a colour.
        if on, vb.isUsingGreenScreenOn(), vb.isDeviceSupportSmartVirtualBG() { _ = vb.setUsingGreenScreen(false) }
        let ok = apply(on ? "background blur ON" : "background blur OFF", vb.useBGItem(target))
        if ok { wantBlur = on }
        return ok
    }
}
