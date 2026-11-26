//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import Foundation
import AppKit
import CoreVideo
import ZoomSDK

// MARK: - Devices
// Own camera and mic into the call, device lists keyed deviceID|name (the SDK reuses IDs), selection by name.
// State lives in SDKZoomEngine.swift; this file is behaviour only (PLAN_stability_refactor.md step 11).

extension SDKZoomEngine {
    /// Our own camera, IN the meeting. `sendsOwnVideo` only sets the pre-meeting preference; this is
    /// the live switch: `ActionMeetingCmd_UnMuteVideo` / `_MuteVideo` on our own user id.
    func setOwnVideo(on: Bool) -> Bool {
        guard let me = participants.first(where: { $0.isMe })?.id else {
            lastError = "no roster entry for the sidecar itself yet"
            return false
        }
        let ok = action(on ? ActionMeetingCmd_UnMuteVideo : ActionMeetingCmd_MuteVideo, user: me,
                        what: on ? "camera on" : "camera off")
        if ok { refreshRoster() }
        return ok
    }

    /// The sidecar's own microphone into the call. Two steps the sidecar has never taken before:
    /// On entering a meeting: JOIN the audio (mic stays muted, the unattended setting) and set the
    /// room playback per config. Without this the sidecar sat in meetings with no audio channel at
    /// all: audio.send 0, audio.recv 0, nothing in the room (2026-09-21, "no sound is coming
    /// out of the app"), while MIC OPEN lit because "not muted" is also what "no audio" reads as.
    func joinAudioOnEntry() {
        guard let me = participants.first(where: { $0.isMe })?.id ?? myID else {
            audioJoinPending = true
            ShowLog.log("audio on entry: no own id yet; joining when the roster has it")
            return
        }
        audioJoinPending = false
        let joined = action(ActionMeetingCmd_JoinVoip, user: me, what: "join meeting audio on entry")
        let speakerOn = audioConfig == "basic"
        let spk = setSpeakerOutput(speakerOn)
        ShowLog.log("audio on entry: join \(joined ? "ok" : "refused"), room playback \(speakerOn ? "ON" : "OFF") (\(spk ? "ok" : "refused")), mic stays muted until MIC OPEN")
        refreshRoster()
    }

    /// JOIN the meeting audio (`ActionMeetingCmd_JoinVoip`, otherwise it is in the meeting with no
    /// audio at all, which is how it has run all day), then open the mic (`_UnMuteAudio` on our own
    /// id). Off just mutes; it does not leave the audio.
    func setOwnAudio(on: Bool) -> Bool {
        guard let me = participants.first(where: { $0.isMe })?.id else {
            lastError = "no roster entry for the sidecar itself yet"
            return false
        }
        if on {
            // Answers WrongUsage when already joined; harmless, so the result is logged and ignored.
            _ = action(ActionMeetingCmd_JoinVoip, user: me, what: "join meeting audio")
            let ok = action(ActionMeetingCmd_UnMuteAudio, user: me, what: "mic open")
            if ok {
                refreshRoster()
                // Zoom keeps sound settings across launches; the mic never goes live on leftovers.
                _ = applyPreset(soundPreset)
            }
            return ok
        }
        let ok = action(ActionMeetingCmd_MuteAudio, user: me, what: "mic closed")
        if ok { refreshRoster() }
        return ok
    }

    /// The devices the SDK will use for the sidecar's own audio, by name. It follows the system
    /// default unless told otherwise, so on the office workstation this is whatever Sound settings say.
    var audioDevices: (mic: String?, speaker: String?) {
        guard let audio = ZoomSDK.shared().getSettingService()?.getAudioSetting() else { return (nil, nil) }
        func selected(_ mic: Bool) -> String? {
            // The "Same as system" entry carries the ID of the CURRENT DEFAULT device, so when the
            // pinned device is also the default, BOTH entries answer selected and "Same as system"
            // comes first in the list (measured 2026-09-21: pin the OBSBOT by name, read back "Same as
            // system"). Prefer the named entry; "Same as system" is the answer only when it is the
            // only one selected.
            let list = (audio.getAudioDeviceList(mic) as? [SDKDeviceInfo])?.filter { $0.isSelectedDevice() } ?? []
            return (list.first { $0.getDeviceName() != "Same as system" } ?? list.first)?.getDeviceName()
        }
        return (selected(true), selected(false))
    }

    /// Pick the camera and microphone by a name fragment ("Insta360"), because the system default is
    /// whatever was plugged in last and a show rig cannot run on that. Case-insensitive contains match
    /// on the device name; the first match wins. Returns what was chosen, or what was not found.
    func selectDevices(cameraMatch: String?, micMatch: String?) -> (camera: String?, mic: String?, errors: [String]) {
        var errors: [String] = []
        var cameraName: String?, micName: String?
        let settings = ZoomSDK.shared().getSettingService()
        if let want = cameraMatch {
            if let video = settings?.getVideoSetting(),
               let list = video.getCameraList() as? [SDKDeviceInfo],
               let hit = list.first(where: { $0.getDeviceName().localizedCaseInsensitiveContains(want) }) {
                let err = video.selectCamera(hit.getDeviceID())
                if err == ZoomSDKError_Success { cameraName = hit.getDeviceName(); ShowLog.log("camera: \(hit.getDeviceName())"); OperatorPrefs.set("cameraDevice", hit.getDeviceName()); updateMicKeeper() }
                else { errors.append("camera \(hit.getDeviceName()) refused (\(Self.name(for: err)))") }
            } else { errors.append("no camera matching \(want)") }
        }
        if let want = micMatch {
            if let audio = settings?.getAudioSetting(),
               let list = audio.getAudioDeviceList(true) as? [SDKDeviceInfo],
               let hit = list.first(where: { $0.getDeviceName().localizedCaseInsensitiveContains(want) }) {
                let err = audio.selectAudioDevice(true, deviceID: hit.getDeviceID(), deviceName: hit.getDeviceName())
                if err == ZoomSDKError_Success { micName = hit.getDeviceName(); ShowLog.log("mic: \(hit.getDeviceName())"); onMicDeviceChange?(hit.getDeviceName()) }
                else { errors.append("mic \(hit.getDeviceName()) refused (\(Self.name(for: err)))") }
            } else { errors.append("no microphone matching \(want)") }
        }
        return (cameraName, micName, errors)
    }

    /// Microphones or speakers the SDK can use, with the one it is using.
    func audioDeviceList(mic: Bool) -> [AudioDevice] {
        ((ZoomSDK.shared().getSettingService()?.getAudioSetting()?.getAudioDeviceList(mic) as? [SDKDeviceInfo]) ?? [])
            .map { AudioDevice(deviceID: $0.getDeviceID(), name: $0.getDeviceName(), selected: $0.isSelectedDevice()) }
    }
    /// Which entry a name or id means. MEASURED 2026-09-21: the SDK's deviceID IS the device's name,
    /// and the "Same as system" entry's deviceID is the CURRENT DEFAULT device's name. So a plain
    /// first-match on deviceID answers "Same as system" for the very device that is the default (the
    /// OBSBOT pin landed there every time). Exact composite id first, then the NAME, then the deviceID
    /// with the named entry preferred over "Same as system". Pure, so it is tested.
    static func pick(_ list: [AudioDevice], _ id: String) -> AudioDevice? {
        if let d = list.first(where: { $0.id == id }) { return d }
        if let d = list.first(where: { $0.name == id }) { return d }
        let byID = list.filter { $0.deviceID == id }
        return byID.first { $0.name != "Same as system" } ?? byID.first
    }

    @discardableResult
    func selectAudio(mic: Bool, id: String) -> Bool {
        guard let audio = ZoomSDK.shared().getSettingService()?.getAudioSetting(),
              let dev = Self.pick(audioDeviceList(mic: mic), id) else { return false }
        let e = audio.selectAudioDevice(mic, deviceID: dev.deviceID, deviceName: dev.name)
        if e == ZoomSDKError_Success {
            ShowLog.log("\(mic ? "mic" : "speaker"): \(dev.name)")
            // The pick is a show setting: it must be there after a relaunch, not whatever was plugged in
            // last (measured 2026-09-21: the OBSBOT pin was gone at the next launch).
            OperatorPrefs.set(mic ? "micDevice" : "speakerDevice", dev.name)
            if mic { updateMicKeeper() }
            sampleSound()
            if mic { onMicDeviceChange?(dev.name) }
            return true
        }
        lastError = "\(mic ? "mic" : "speaker") \(dev.name) refused (\(Self.name(for: e)))"
        return false
    }

    /// The mic and speaker the operator pinned last time, re-applied once the setting service exists.
    /// A name that is not plugged in today is reported and left alone: the SDK then follows the system
    /// default, which the SOUND module shows by name.
    func restoreAudioDevices() {
        var notes: [String] = []
        for (mic, key) in [(true, "micDevice"), (false, "speakerDevice")] {
            guard let want = OperatorPrefs.string(key) else { continue }
            if audioDeviceList(mic: mic).contains(where: { $0.name == want }) {
                if selectAudio(mic: mic, id: want) { notes.append("\(mic ? "mic" : "speaker") \(want)") }
            } else {
                notes.append("\(mic ? "mic" : "speaker") \(want) NOT PRESENT, following the system default")
            }
        }
        if let want = OperatorPrefs.string("cameraDevice") {
            if cameraList().contains(where: { $0.name == want }) { if selectCamera(id: want) { notes.append("camera \(want)") } }
            else { notes.append("camera \(want) NOT PRESENT, the SDK's default stays") }
        }
        if !notes.isEmpty { ShowLog.log("devices restored: " + notes.joined(separator: ", ")) }
        updateMicKeeper()
    }

    /// The pinned mic's camera, held open unless the SDK is sending that camera itself. Call after any
    /// mic or camera change; idempotent.
    func updateMicKeeper() {
        let mic = audioDevices.mic
        let real = mic == "Same as system" ? MicMeter.systemDefaultDeviceName(input: true) : mic
        micKeeper.update(mic: real, sendingCamera: selectedCamera)
    }

    /// Cameras the SDK can send, with the one it would send.
    func cameraList() -> [AudioDevice] {
        ((ZoomSDK.shared().getSettingService()?.getVideoSetting()?.getCameraList() as? [SDKDeviceInfo]) ?? [])
            .map { AudioDevice(deviceID: $0.getDeviceID(), name: $0.getDeviceName(), selected: $0.isSelectedDevice()) }
    }

    /// Pick the camera by name or id (the OWN FEED picker; 2026-09-21: "nowhere I can choose the
    /// camera input"). Pinned across launches like the mic; the keeper re-evaluates because sending a
    /// webcam's own camera makes holding it unnecessary.
    @discardableResult
    func selectCamera(id: String) -> Bool {
        guard let video = ZoomSDK.shared().getSettingService()?.getVideoSetting(),
              let dev = Self.pick(cameraList(), id) else { lastError = "no camera matching \(id)"; return false }
        let e = video.selectCamera(dev.deviceID)
        if e == ZoomSDKError_Success {
            ShowLog.log("camera: \(dev.name)")
            OperatorPrefs.set("cameraDevice", dev.name)
            updateMicKeeper()
            sampleSound()
            return true
        }
        lastError = "camera \(dev.name) refused (\(Self.name(for: e)))"
        return false
    }

    /// The camera the SDK will send, by name.
    var selectedCamera: String? {
        (ZoomSDK.shared().getSettingService()?.getVideoSetting()?.getCameraList() as? [SDKDeviceInfo])?
            .first { $0.isSelectedDevice() }?.getDeviceName()
    }
}
