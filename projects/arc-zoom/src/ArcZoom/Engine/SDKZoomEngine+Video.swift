//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import Foundation
import AppKit
import CoreVideo
import ZoomSDK

// MARK: - Video
// The raw-data gate (startRawRecording releases frames), per-participant subscriptions, the HD budget, own-video preference.
// State lives in SDKZoomEngine.swift; this file is behaviour only (PLAN_stability_refactor.md step 11).

extension SDKZoomEngine {
    func applyVideoQuality() {
        guard let v = ZoomSDK.shared().getSettingService()?.getVideoSetting() else { return }
        _ = v.enableCatchHDVideo(hdCapture)
        _ = v.enableHardwareAcceleration(forVideoReceive: true)
        let pref = ZoomSDKVideoPreferenceSetting()
        pref.mode = smoothVideo ? ZoomSDKVideoPreferenceMode_Custom : ZoomSDKVideoPreferenceMode_Sharpness
        pref.minimumFrameRate = smoothVideo ? 24 : 0
        pref.maximumFrameRate = smoothVideo ? 30 : 0
        let e = v.setVideoQualityPreference(pref)
        ShowLog.log("video quality: HD \(hdCapture ? "on" : "off"), \(smoothVideo ? "smooth 24-30 fps" : "sharpness") (\(Self.name(for: e)))")
    }


    func applyOwnVideoPreference() {
        guard let pre = ZoomSDK.shared().getPremeetingService() else {
            ShowLog.log("no pre-meeting service; cannot set the sidecar camera")
            return
        }
        pre.enableForceAutoStartMyVideo(whenJoinMeeting: sendsOwnVideo)
        pre.enableForceAutoStopMyVideo(whenJoinMeeting: !sendsOwnVideo)
        ShowLog.log("sidecar camera \(sendsOwnVideo ? "ON" : "OFF") for the next join")
    }

    /// THE RAW DATA GATE. The SDK hands out no raw video at all until a RAW RECORDING is running: a
    /// `ZoomSDKRenderer` will subscribe without error and then simply never deliver a frame, and
    /// `onSubscribedUserDataOn` never fires (measured 2026-09-20, an hour of black output). Starting it
    /// needs local recording permission, which the host has. Nothing is written to disk: "raw recording"
    /// is Zoom's name for the permission to see the media, not for a file.
    @discardableResult
    func startRawData() async -> Bool {
        guard state == .inMeeting else { return false }
        if rawDataRunning { return true }
        guard let service = ZoomSDK.shared().getMeetingService() else { return false }
        let rec = service.getRecordController()
        let can = rec.canStartRawRecording()
        guard can == ZoomSDKError_Success else {
            lastError = "the SDK will not release raw video (\(Self.name(for: can))); the sidecar needs to be host or have local recording permission"
            ShowLog.error("Zoom SDK: \(lastError!)")
            return false
        }
        let err = rec.startRawRecording()
        guard err == ZoomSDKError_Success else {
            lastError = "could not start raw data (\(Self.name(for: err)))"
            ShowLog.error("Zoom SDK: \(lastError!)")
            return false
        }
        rawDataRunning = true
        ShowLog.log("raw data unlocked (raw recording started; nothing is written to disk)")
        return true
    }

    func stopRawData() {
        guard rawDataRunning, let service = ZoomSDK.shared().getMeetingService() else { return }
        _ = service.getRecordController().stopRawRecording()
        rawDataRunning = false
    }

    /// One `VideoSubscription` per participant we draw (gating item 2).
    func subscribe(to id: UInt32) async -> Bool {
        guard state == .inMeeting else { return false }
        guard await startRawData() else { return false }
        if subscriptions[id] != nil { return true }
        let gate = frameGate
        let sub = VideoSubscription(userID: id) { uid, buffer in gate.push(uid, buffer) }
        sub.setResolution(id == hdID ? ZoomSDKResolution_720P : ZoomSDKResolution_360P)
        guard sub.start() else { return false }
        subscriptions[id] = sub
        return true
    }

    func unsubscribe(from id: UInt32) {
        subscriptions.removeValue(forKey: id)?.stop()
    }

    /// Tear every video subscription down and build it again. Needed because raw video permission
    /// depends on our ROLE, and the role changes under us: subscribing as a plain participant and then
    /// being promoted to host leaves a subscription that never delivers (2026-09-20).
    func resubscribeAll() async {
        let ids = subscriptions.keys.sorted()
        for id in ids { subscriptions.removeValue(forKey: id)?.stop() }
        for id in ids { _ = await subscribe(to: id) }
        ShowLog.log("video: resubscribed to \(ids.map(String.init).joined(separator: ", "))")
    }

    /// What each subscription is actually doing. Black output with a live subscription is otherwise
    /// impossible to tell apart from a camera that is off.
    var videoJSON: String {
        let subs = subscriptions.values.sorted { $0.userID < $1.userID }.map {
            "{\"user\":\($0.userID),\"receiving\":\($0.isReceiving),\"frames\":\($0.frameCount)}"
        }.joined(separator: ",")
        return "{\"subscriptions\":[\(subs)]}"
    }
}
