//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import Foundation
import AppKit
import CoreVideo
import ZoomSDK

// MARK: - Recording
// Cloud recording while raw video runs (the SDK's local recorder is the raw gate), local MP4 only with the outputs closed.
// State lives in SDKZoomEngine.swift; this file is behaviour only (PLAN_stability_refactor.md step 11).

extension SDKZoomEngine {
    var rec: ZoomSDKMeetingRecordController? { ZoomSDK.shared().getMeetingService()?.getRecordController() }
    var recordingFolder: String { ZoomSDK.shared().getSettingService()?.getRecordSetting()?.getRecordingPath() ?? "?" }

    func setRecordingFolder(_ path: String) -> Bool { apply("recording folder \(path)", ZoomSDK.shared().getSettingService()?.getRecordSetting()?.setRecordingPath(path)) }
    /// CLOUD whenever the account allows it. Local file recording and raw video share the SDK's recorder
    /// and are mutually exclusive: whichever starts second loses (measured 2026-09-21 02:40: a local
    /// recording that started while the outputs ran took the raw feed to 0 frames). Local is the fallback
    /// only with no cloud and no outputs, and it says what it costs.
    func startRecording() -> Bool {
        guard let rec else { lastError = "not in a meeting"; return false }
        // canStartRecording(cloud) answered WrongUsage on 2026-09-21 with the portal's cloud recording
        // ON, so its verdict is not the last word: try the start itself, both flavours, and log what
        // each answered. If one takes, the "can" check was the liar.
        let canCloud = rec.canStartRecording(true)
        let smart = "smart recording \(rec.isSmartRecordingEnabled() ? "enabled" : "off"), feature \(rec.canEnableSmartRecordingFeature() ? "available" : "unavailable")"
        let e1 = rec.startCloudRecording(true)
        if e1 == ZoomSDKError_Success {
            ShowLog.log("cloud recording started (can: \(Self.name(for: canCloud)); \(smart))")
            recordingStatus = "CLOUD REC"; recordingKind = "cloud"
            return true
        }
        ShowLog.log("cloud recording refused: can \(Self.name(for: canCloud)), start \(Self.name(for: e1)); \(smart); raw video \(rawDataRunning ? "running" : "off")")
        if rawDataRunning {
            lastError = "recording unavailable: cloud recording refused (\(Self.name(for: e1))), and local recording would take the raw video away from the outputs"
            ShowLog.error("Zoom SDK: \(lastError!)")
            return false
        }
        let can = rec.canStartRecording(false)
        guard can == ZoomSDKError_Success else { lastError = "local recording cannot start (\(Self.name(for: can)))"; return false }
        var t: time_t = 0
        let ok = apply("recording started (local; the outputs' raw video is off until it stops)", rec.startRecording(&t))
        if ok { recordingStatus = "REC"; recordingKind = "local"; mp4Progress = -1 }
        return ok
    }

    func stopCloudRecordingIfRunning() -> Bool {
        guard let rec else { return false }
        let e = rec.startCloudRecording(false)
        if e == ZoomSDKError_Success { recordingStatus = "OFF"; recordingKind = "" }
        ShowLog.log("cloud recording stop: \(Self.name(for: e))")
        return e == ZoomSDKError_Success
    }

    func restoreRawAfterLocalRecording() {
        rawDataRunning = false
        Task { @MainActor in
            guard await startRawData() else { return }
            await resubscribeAll()
        }
    }
    func pauseRecording() -> Bool {
        let ok = apply("recording paused", recordingKind == "cloud" ? rec?.pauseCloudRecording() : rec?.pauseLocalRecording())
        if ok { recordingStatus = "PAUSED" }; return ok
    }
    func resumeRecording() -> Bool {
        let ok = apply("recording resumed", recordingKind == "cloud" ? rec?.resumeCloudRecording() : rec?.resumeLocalRecording())
        if ok { recordingStatus = recordingKind == "cloud" ? "CLOUD REC" : "REC" }; return ok
    }
    func stopRecording() -> Bool {
        if recordingKind == "cloud" {
            let ok = apply("cloud recording stopped", rec?.startCloudRecording(false))
            if ok { recordingStatus = "OFF"; recordingKind = "" }
            return ok
        }
        var t: time_t = 0
        let ok = apply("recording stopped; converting to MP4", rec?.stopRecording(&t))
        if ok { recordingStatus = "CONVERTING"; mp4Progress = 0; restoreRawAfterLocalRecording() }
        return ok
    }
    func recordingWord(_ st: ZoomSDKRecordingStatus) -> String {
        switch st {
        case ZoomSDKRecordingStatus_Start: return "REC"
        case ZoomSDKRecordingStatus_Pause: return "PAUSED"
        case ZoomSDKRecordingStatus_DiskFull: return "DISK FULL"
        case ZoomSDKRecordingStatus_Fail: return "FAIL"
        case ZoomSDKRecordingStatus_Connecting: return "CONNECTING"
        case ZoomSDKRecordingStatus_Stop: return recordingStatus == "CONVERTING" ? "CONVERTING" : "OFF"
        default: return recordingStatus == "CONVERTING" ? "CONVERTING" : "OFF"
        }
    }
    /// Poll our own recording state from the roster entry (the record delegate may stay silent).
    /// Only the faults are read from the SDK's flag: the flag says "recording" whenever raw video runs.
    func pollRecording() {
        guard let me = myID, let info = ZoomSDK.shared().getMeetingService()?.getMeetingActionController().getUserByUserID(me) else { return }
        let st = info.getLocalRecordingStatus()
        if st == ZoomSDKRecordingStatus_DiskFull { recordingStatus = "DISK FULL" }
        else if st == ZoomSDKRecordingStatus_Fail, recordingKind == "local" { recordingStatus = "FAIL" }
        if recordingKind == "cloud" {
            let c = rec?.getCloudRecordingStatus() ?? ZoomSDKRecordingStatus_None
            if c == ZoomSDKRecordingStatus_Stop { recordingStatus = "OFF"; recordingKind = "" }
        }
    }
    var recordingJSON: String {
        "{\"status\":\"\(recordingStatus)\",\"mp4Progress\":\(mp4Progress),\"folder\":\"\(jsonEscape(recordingFolder))\",\"lastFile\":\(lastRecordingPath.map { "\"\(jsonEscape($0))\"" } ?? "null")}"
    }
}
