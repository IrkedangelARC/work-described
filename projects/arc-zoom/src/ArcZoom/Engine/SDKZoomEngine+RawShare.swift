//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AppKit
import ZoomSDK

// MARK: - Sharing the PREVIEW module (2026-09-24)
// SHARE THIS sends exactly what PREVIEW shows:
//   CAMERA, AUDIO IN none  -> startShareCamera (the SDK opens the camera itself; works since 0.9.0)
//   CAMERA + an AUDIO IN   -> the raw share source: our capture session's frames + that input's sound
//   FILE                   -> the raw share source: the preview player's frames + its tap's sound, so pause,
//                             seek, loop and restart act live on the call
//   FILE, raw refused      -> startVideoFileShare on the playable mov / mp4 (Zoom plays it; no transport)
//
// THE RAW SHARE SOURCE (ZoomSDKRawDataShareSourceController.h, SDK 7.1.5):
//   ZoomSDK.getRawDataController().getRawDataShareSourceHelper(&helper)
//   helper.setExternalShareSource(source, shareAudioSource: source)    STARTS the share
//   -> source.onStartSend(ZoomSDKShareSender)                          frames: sendShareFrame(buf, w, h, len, I420_Limited)
//   -> source.onStartSendAudio(ZoomSDKShareAudioSender)                sound: sendShareAudio(pcm16, len, 44100|48000, mono|stereo)
//   ASController.stopShare()                                           STOPS it -> onStopSend / onStopSendAudio
// State lives in SDKZoomEngine.swift (rawShare, previewShare); this file is behaviour only.

/// The Zoom end of a `ShareSink`: the two senders the SDK hands over, and what went through them.
final class ZoomShareSink: ShareSink, @unchecked Sendable {
    private let lock = NSLock()
    private var video: ZoomSDKShareSender?
    private var audio: ZoomSDKShareAudioSender?
    private(set) var frameErrors = 0
    private(set) var audioErrors = 0
    private(set) var lastError: String?
    /// Send on the main thread instead of the pump/send queues. OFF: the SDK's raw senders are documented
    /// for a capture thread. `POST /preview?sendOnMain=1` flips it if the live test sees nothing arrive.
    nonisolated(unsafe) static var sendOnMain = false

    func setVideo(_ s: ZoomSDKShareSender?) { lock.lock(); video = s; lock.unlock() }
    func setAudio(_ s: ZoomSDKShareAudioSender?) { lock.lock(); audio = s; lock.unlock() }
    var hasVideo: Bool { lock.lock(); defer { lock.unlock() }; return video != nil }
    var hasAudio: Bool { lock.lock(); defer { lock.unlock() }; return audio != nil }

    func sendFrame(_ bytes: UnsafeMutablePointer<UInt8>, count: Int, width: Int, height: Int, fullRange: Bool) {
        lock.lock(); let v = video; lock.unlock()
        guard let v else { return }
        let fmt = fullRange ? ZoomSDKFrameDataFormat_I420_Full : ZoomSDKFrameDataFormat_I420_Limited
        let send = { () -> ZoomSDKError in
            bytes.withMemoryRebound(to: CChar.self, capacity: count) { v.sendShareFrame($0, width: UInt32(width), height: UInt32(height), frameLength: UInt32(count), format: fmt) }
        }
        let e = Self.sendOnMain ? DispatchQueue.main.sync(execute: send) : send()
        if e != ZoomSDKError_Success { note(frame: true, e) }
    }

    func sendAudio(_ samples: [Int16], rate: Int, channels: Int) {
        lock.lock(); let a = audio; lock.unlock()
        guard let a else { return }
        let ch = channels == 2 ? ZoomSDKAudioChannel_Stereo : ZoomSDKAudioChannel_Mono
        var copy = samples
        let send = { () -> ZoomSDKError in
            copy.withUnsafeMutableBytes { raw in
                a.sendShareAudio(raw.baseAddress!.assumingMemoryBound(to: CChar.self), dataLength: UInt32(raw.count), sampleRate: Int32(rate), audioChannel: ch)
            }
        }
        let e = Self.sendOnMain ? DispatchQueue.main.sync(execute: send) : send()
        if e != ZoomSDKError_Success { note(frame: false, e) }
    }

    private func note(frame: Bool, _ e: ZoomSDKError) {
        lock.lock()
        if frame { frameErrors += 1 } else { audioErrors += 1 }
        let first = (frame ? frameErrors : audioErrors) == 1
        lastError = "\(frame ? "sendShareFrame" : "sendShareAudio") answered \(e.rawValue)"
        lock.unlock()
        if first { ShowLog.error("raw share: \(frame ? "sendShareFrame" : "sendShareAudio") refused (\(e.rawValue)); counting, logged once") }
    }
}

/// The object the SDK calls back: it hands the senders to the sink and the sink to the preview player.
final class RawShareSource: NSObject, ZoomSDKShareSourceDelegate, ZoomSDKShareAudioSourceDelegate {
    let sink = ZoomShareSink()
    weak var player: PreviewPlayer?
    let label: String
    /// Both senders arrived and neither has been withdrawn.
    private(set) var sending = false
    var onStopped: (() -> Void)?

    init(player: PreviewPlayer, label: String) { self.player = player; self.label = label }

    /// Every source ever handed to `setExternalShareSource`, for the life of the app. The SDK stores the
    /// delegate WITHOUT retaining it and still calls it after `stopShare` (onStopSendAudio, and a
    /// respondsToSelector from its own notification): freeing it on STOP SHARE crashed the app 0.1 s later
    /// (EXC_BREAKPOINT in objc_opt_respondsToSelector under ZoomSDK, 2026-09-24 05:05:52). Each is a few
    /// hundred bytes; a show makes a handful.
    @MainActor private static var retired: [RawShareSource] = []

    /// Cut a finished source loose and keep it alive. A late callback from it can no longer reach the
    /// player (it would detach the NEXT share's feed) or the engine.
    @MainActor static func retire(_ s: RawShareSource) {
        s.onStopped = nil
        s.detach()
        s.player = nil
        if !retired.contains(where: { $0 === s }) { retired.append(s) }
    }

    func onStartSend(_ sender: ZoomSDKShareSender?) {
        sink.setVideo(sender)
        ShowLog.log("raw share: video sender \(sender == nil ? "MISSING" : "ready") (\(label))")
        attach()
    }
    func onStopSend() {
        sink.setVideo(nil)
        ShowLog.log("raw share: video sender stopped")
        stopped()
    }
    func onStartSendAudio(_ shareAudioSender: ZoomSDKShareAudioSender?) {
        sink.setAudio(shareAudioSender)
        ShowLog.log("raw share: audio sender \(shareAudioSender == nil ? "MISSING" : "ready")")
        attach()
    }
    func onStopSendAudio() {
        sink.setAudio(nil)
        ShowLog.log("raw share: audio sender stopped")
    }

    private func attach() {
        sending = sink.hasVideo
        let s = sink
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.player?.attach(s) } }
    }
    private func stopped() {
        sending = false
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.player?.detachShare(); self?.onStopped?() } }
    }
    func detach() {
        sink.setVideo(nil); sink.setAudio(nil); sending = false
        MainActor.assumeIsolated { player?.detachShare() }
    }
}

extension SDKZoomEngine {
    /// The raw share source controller, or nil with the reason in `lastError`.
    func rawShareHelper() -> ZoomSDKRawDataShareSourceController? {
        guard let raw = ZoomSDK.shared().getRawDataController() else { lastError = "no raw data controller"; return nil }
        let lic = raw.hasRawDataLicense()
        guard lic == ZoomSDKError_Success else { lastError = "no raw data licence (\(Self.name(for: lic)))"; return nil }
        var helper: ZoomSDKRawDataShareSourceController?
        let e = raw.getRawDataShareSourceHelper(&helper)
        guard e == ZoomSDKError_Success, let helper else { lastError = "no raw share source (\(Self.name(for: e)))"; return nil }
        return helper
    }

    /// SHARE THIS. Replaces whatever this Mac is sharing. Answers after the SDK accepted (or refused) the start.
    func sharePreview(_ p: PreviewPlayer) async -> Bool {
        guard state == .inMeeting else { lastError = "not in a meeting"; return false }
        switch p.source {
        case .off:
            lastError = "PREVIEW has no source: pick a camera or a video file"
            return false
        case .camera(let id, let name):
            if p.sendAsVideo { return await sendPreviewAsVideo(p) }
            if sendingAsVideo { await endPreviewVideo(p) }
            if p.cameraShareIsRaw { return await startRaw(p, label: "camera \(name) + \(p.cameraAudioName ?? "audio")", mode: "camera-raw") }
            let cams = cameraList()
            guard let cam = cams.first(where: { $0.deviceID == id }) ?? cams.first(where: { $0.name == name }) else {
                lastError = "the Zoom SDK does not list \(name) as a camera"; return false
            }
            if isSharing { await stopShare() }
            // The SDK opens the device alone, then our preview joins it at the format the SDK chose.
            p.yieldCameraToShare()
            let ok = shareCamera(cam.deviceID, label: cam.name)
            if ok { previewShare = "camera" }
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(ok ? 1500 : 100)); p.resumeCamera() }
            syncPreview(p)
            return ok
        case .file:
            guard p.transport.isLoaded, let url = p.playURL else {
                lastError = "the file is not ready (\(p.transport.word.lowercased()))"; return false
            }
            if await startRaw(p, label: "video file \(p.originalURL?.lastPathComponent ?? url.lastPathComponent) (ARC player)", mode: "file-raw") { return true }
            // Raw refused: Zoom's own file share, on the playable file (a converted mkv is an mp4 by now).
            guard PreviewFormats.sdkFileShare.contains(url.pathExtension.lowercased()) else { return false }
            let why = lastError ?? "raw share refused"
            if isSharing { await stopShare() }
            let ok = shareVideoFile(url.path)
            if ok {
                previewShare = "file-sdk"
                p.note = "Zoom is playing the file itself (\(why)): PREVIEW's transport does not reach the call"
            }
            syncPreview(p)
            return ok
        }
    }

    private func startRaw(_ p: PreviewPlayer, label: String, mode: String) async -> Bool {
        guard let helper = rawShareHelper() else { return false }
        if isSharing { await stopShare() }
        applyShareSettings()
        // A share's frame-rate cap (the Zoom client's "limit fps" screen-share setting) applies to a raw share
        // too: logged, and lifted for ours so a video or a camera goes out at the rate it is sent.
        if let ss = ZoomSDK.shared().getSettingService()?.getShareScreenSetting() {
            let limited = ss.isEnableToSetLimitFPS()
            ShowLog.log("raw share: Zoom share fps limit \(limited ? "ON at \(ss.getLimitFPSValue())" : "off")")
            if limited { _ = apply("share fps limit off", ss.setEnableLimitFPS(false)) }
        }
        let src = RawShareSource(player: p, label: label)
        src.onStopped = { [weak self, weak src] in
            guard let self, let src, self.rawShare === src else { return }
            // The SDK withdrew the sender (someone else took the share, or the meeting stopped it).
            self.rawShare = nil
            if self.isSharing { self.isSharing = false; self.shareDescription = nil; self.sharedWindowTitle = nil; ShowLog.log("our raw share ended"); self.onRosterChange?() }
        }
        rawShare = src
        let e = helper.setExternalShareSource(src, shareAudioSource: src)
        guard shareResult(label, e) else { rawShare = nil; return false }
        previewShare = mode
        syncPreview(p)
        return true
    }

    /// STOP SHARE from PREVIEW: the same stop as the SHARE module's, which also detaches the raw source.
    func stopPreviewShare(_ p: PreviewPlayer) async {
        if sendingAsVideo { await endPreviewVideo(p); return }
        await stopShare()
        syncPreview(p)
    }

    /// The module's ON AIR and share mode follow the engine.
    func syncPreview(_ p: PreviewPlayer) {
        if sendingAsVideo { p.onAir = true; p.shareMode = "camera-video"; return }
        p.onAir = isSharing && previewShare != nil
        p.shareMode = p.onAir ? previewShare : nil
    }

    /// Counters for GET /preview while a raw share runs.
    var rawShareJSON: String {
        guard let r = rawShare else { return "null" }
        return "{\"sending\":\(r.sending),\"videoSender\":\(r.sink.hasVideo),\"audioSender\":\(r.sink.hasAudio),\"frameErrors\":\(r.sink.frameErrors),\"audioErrors\":\(r.sink.audioErrors),\"lastError\":\(r.sink.lastError.map { "\"\(jsonEscape($0))\"" } ?? "null"),\"sendOnMain\":\(ZoomShareSink.sendOnMain)}"
    }
}
