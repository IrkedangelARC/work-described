//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import Foundation
import AppKit
import CoreVideo
import ZoomSDK

// MARK: - Health
// The 1 Hz sampler: roster, share, chat, captions, recording, waiting room and the self stats; measured account capabilities.
// State lives in SDKZoomEngine.swift; this file is behaviour only (PLAN_stability_refactor.md step 11).

extension SDKZoomEngine {
    func startSampling() {
        guard sampleTimer == nil else { return }
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(sampleTimer!, forMode: .common)
        sample()
    }

    func stopSampling() { sampleTimer?.invalidate(); sampleTimer = nil }

    /// The SOUND module's sample, on its own because it does NOT need a meeting: devices, volumes and
    /// the audio settings are the SDK's setting service, live from authentication (2026-09-21:
    /// "is there any way to get this configured before connecting?"). Taken by the 1 Hz sampler in a
    /// meeting, and after prepare and every sound setter outside one. Original sound is the one
    /// meeting-audio fact in it, false with no meeting up.
    func sampleSound() {
        var so = SoundSample()
        so.original = act?.isUseOriginalSoundOn() ?? false
        so.blur = blurOn
        if let au = ZoomSDK.shared().getSettingService()?.getAudioSetting() {
            so.hifi = au.isHighFideMusicMode(); so.stereo = au.isEnableStereoOn(); so.agc = au.isAutoAdjustMicOn()
            switch au.getSuppressBackgroundNoiseLevel() {
            case ZoomSDKSuppressBackgroundNoiseLevel_Low: so.noise = "LOW"
            case ZoomSDKSuppressBackgroundNoiseLevel_Medium: so.noise = "MEDIUM"
            case ZoomSDKSuppressBackgroundNoiseLevel_High: so.noise = "HIGH"
            default: so.noise = "AUTO"
            }
            so.speakerVolume = Double(au.getAudioDeviceVolume(false)); so.micVolume = Double(au.getAudioDeviceVolume(true))
        }
        let d = audioDevices
        so.mic = Self.deviceLabel(d.mic, input: true); so.speaker = Self.deviceLabel(d.speaker, input: false); so.camera = selectedCamera ?? "?"
        so.heldCamera = micKeeper.heldCamera
        if so != soundSample { soundSample = so }
    }

    /// "Same as system" tells the operator nothing on a show day; say which device that is right now.
    static func deviceLabel(_ name: String?, input: Bool) -> String {
        guard let name else { return "?" }
        guard name == "Same as system", let real = MicMeter.systemDefaultDeviceName(input: input) else { return name }
        return "Same as system · \(real)"
    }

    func sample() {
        guard state == .inMeeting else { return }
        pollRoster()
        savePrefs()
        refreshShare()
        pollChat()
        pollCaptions()
        pollRecording()
        refreshWaiting()
        let sdk = ZoomSDK.shared()
        var h = HealthSample()
        if let st = sdk.getSettingService()?.getStatisticsSetting() {
            switch st.getConnectionType() {
            case SettingConnectionType_P2P: h.connection = "P2P"
            case SettingConnectionType_Cloud: h.connection = "CLOUD"
            default: h.connection = "?"
            }
            switch st.getNetworkType() {
            case SettingNetworkType_Wired: h.network = "WIRED"
            case SettingNetworkType_WiFi: h.network = "WIFI"
            default: h.network = "?"
            }
            if let v = st.getVideoStatisticInfo() {
                h.sendKbps = v.sendBandwidth; h.sendFps = v.sendFps; h.sendW = v.sendResolution & 0xFFFF; h.sendH = v.sendResolution >> 16
                h.sendRTT = v.sendRTT; h.sendLoss = v.sendPacketLossAvg; h.recvFps = v.recvFps; h.recvLoss = v.recvPacketLossAvg
            }
            if let sh = st.getShareStatisticInfo() {
                h.shareKbps = sh.sendBandwidth; h.shareFps = sh.sendFps; h.shareW = sh.sendResolution & 0xFFFF; h.shareH = sh.sendResolution >> 16
            }
            if h.network == "WIFI" { h.advice = "Zoom is on Wi-Fi. Put Ethernet first in the network service order (or turn Wi-Fi off) before a show." }
        }
        if let m = sdk.getMeetingService() {
            h.videoUp = Self.qualityName(m.getConnectionQuality(ConnectionComponent_Video, sending: true))
            h.audioUp = Self.qualityName(m.getConnectionQuality(ConnectionComponent_Audio, sending: true))
            h.videoDown = Self.qualityName(m.getConnectionQuality(ConnectionComponent_Video, sending: false))
            h.dataCenter = m.getInMeetingDataCenterInfo()
            let a = m.getMeetingActionController()
            var sh = ShareSettingType_None
            _ = a.getShareSettingType(&sh)
            var ss = SettingsSample()
            ss.allowUnmute = a.isParticipantsUnmuteSelfAllowed(); ss.waitingRoom = m.getWaitingRoomController().isEnableWaitingRoomOnEntry()
            ss.muteOnEntry = a.isMuteOnEntryEnabled(); ss.followOrder = a.isFollowHostVideoOrderOn()
            ss.focusEnabled = a.isFocusModeEnabled(); ss.focus = a.isFocusModeOn()
            switch sh {
            case ShareSettingType_OnlyHostCanShare: ss.share = "HOST ONLY"
            case ShareSettingType_OnlyHostCanGrab: ss.share = "HOST GRAB"
            case ShareSettingType_AnyoneCanGrab: ss.share = "ANYONE"
            case ShareSettingType_MultiShare: ss.share = "MULTI"
            default: ss.share = "?"
            }
            if ss != settingsSample { settingsSample = ss }
            sampleSound()
        }
        if h != health { health = h }
    }

    /// What THIS account, in THIS meeting, is allowed to do. Measured, not assumed: several of these
    /// (Production Studio, talkback, dial-out, third-party captions) depend on the Zoom plan and
    /// the meeting's settings, and the headers say nothing about which plan. Answers the plan's
    /// open question 1 the only honest way.
    var capabilities: [String: String] {
        var c: [String: String] = [:]
        func flag(_ k: String, _ v: Bool) { c[k] = v ? "yes" : "no" }
        func err(_ k: String, _ e: ZoomSDKError) { c[k] = e == ZoomSDKError_Success ? "yes" : "no (\(Self.name(for: e)))" }
        let sdk = ZoomSDK.shared()
        guard let m = sdk.getMeetingService() else { return ["error": "no meeting service"] }
        let ps = m.getMeetingProductionStudioController()
        flag("productionStudio.supported", ps.isSupportPSMode())
        flag("productionStudio.canStart", ps.canStartPSMode())
        flag("talkback", m.getTalkbackController().isMeetingSupportTalkBack())
        if let raw = sdk.getRawDataController() { err("rawDataLicense", raw.hasRawDataLicense()) } else { c["rawDataLicense"] = "no controller" }
        err("liveStream.canStart", m.getLiveStreamHelper().canStartLiveStream())
        if let im = m.getMeetingImmersiveController() { flag("immersive", im.isSupportImmersive()) } else { c["immersive"] = "no controller" }
        let cc = m.getCloseCaptionController()
        flag("captions.thirdPartyServer", cc.is3rdPartCCServerAvailable())
        flag("captions.liveTranscription", cc.isLiveTranscriptionFeatureEnabled())
        let ph = m.getPhoneHelper()
        flag("phone.supported", ph.isSupportPhone())
        flag("phone.dialOut", ph.isDialoutSupported())
        if let rec = Optional(m.getRecordController()) {
            err("recording.cloud", rec.canStartRecording(true))
            err("recording.local", rec.canStartRecording(false))
        }
        let act = m.getMeetingActionController()
        flag("originalSound", act.isSupportUseOriginalSound())
        flag("waitingRoom", m.getWaitingRoomController().isSupportWaitingRoom())
        flag("qa", m.getQAController().isQAEnable())
        flag("reactions", m.getReactionController().isEmojiReactionEnabled())
        flag("interpretation", m.getInterpretationController().isInterpretationEnabled())
        if let audio = sdk.getSettingService()?.getAudioSetting() { flag("echoCancellation.supported", audio.isSupportEchoCancellation()) }
        return c
    }
}
