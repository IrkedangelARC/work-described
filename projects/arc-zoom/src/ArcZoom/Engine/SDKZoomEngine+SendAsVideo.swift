//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

// SEND AS: VIDEO for PREVIEW's camera (2026-09-24: "camera is good but delay is almost 3 seconds").
// Zoom buffers a SHARE far more than participant video, so a camera sent as a share arrives seconds late.
// AS VIDEO makes the camera ARC Zoom's OWN video instead, in one move:
//   the SDK camera = the PREVIEW camera; with an AUDIO IN, the SDK mic = that input, marked mix-minus and on
//   the MUSIC preset (no echo cancellation, gain or noise processing: a line feed like an ATEM's is not a room
//   mic); own video on, own audio open; ARC Zoom spotlighted so every viewer gets it full frame.
// STOP puts every one of those back exactly as it was. A participant tile, not content: that is the trade.

extension SDKZoomEngine {
    struct VideoSendRestore {
        var camera: String?
        var mic: String?
        var preset: String
        var mixMinus: Bool
        var videoOn: Bool
        var audioOn: Bool
        var spotlightAdded: Bool
    }

    /// GO LIVE AS VIDEO. Replaces a PREVIEW share that is running.
    func sendPreviewAsVideo(_ p: PreviewPlayer) async -> Bool {
        guard state == .inMeeting else { lastError = "not in a meeting"; return false }
        guard case .camera(let id, let name) = p.source else { lastError = "AS VIDEO is for a camera source"; return false }
        let cams = cameraList()
        guard let cam = cams.first(where: { $0.deviceID == id }) ?? cams.first(where: { $0.name == name }) else {
            lastError = "the Zoom SDK does not list \(name) as a camera"; return false
        }
        if isSharing, previewShare != nil { await stopShare() }
        previewForVideoSend = p
        let me = participants.first { $0.isMe }
        if videoSendRestore == nil {
            videoSendRestore = VideoSendRestore(
                camera: selectedCamera, mic: soundSample.mic.isEmpty ? nil : soundSample.mic, preset: soundPreset,
                mixMinus: micIsMixMinus, videoOn: me?.videoOn ?? false, audioOn: me?.audioOn ?? false,
                spotlightAdded: !(me?.isSpotlighted ?? false))
        }
        // The SDK opens the device; the preview steps off and rejoins at the SDK's format, as for a camera share.
        p.yieldCameraToShare()
        var notes: [String] = []
        if !selectCamera(id: cam.deviceID) { notes.append("camera \(cam.name) refused") }
        if let audioName = p.cameraAudioName {
            if selectAudio(mic: true, id: audioName) {
                micIsMixMinus = true
                let r = applyPreset("music")
                if !r.ok { notes.append(contentsOf: r.notes) }
                _ = setOwnAudio(on: true)
            } else { notes.append("the SDK does not list \(audioName) as a mic: the call keeps the current mic") }
        }
        _ = setOwnVideo(on: true)
        // Spotlight: Zoom refuses it in a meeting of two (and for a video that is not on YET: the camera was
        // switched on in the same instant, live 2026-09-24). Two people see each other anyway, so it is skipped
        // there, and otherwise asked once the video is really on. The log says which.
        var spotNote = "not spotlighted: a meeting of two needs none"
        if participants.count >= 3, let id = myID, videoSendRestore?.spotlightAdded == true {
            for _ in 0..<10 where participants.first(where: { $0.isMe })?.videoOn != true { try? await Task.sleep(for: .milliseconds(300)) }
            spotNote = await spotlight(id, on: true) ? "spotlighted" : "spotlight refused (\(lastError ?? "?"))"
        } else if videoSendRestore?.spotlightAdded == false { spotNote = "already spotlighted" }
        if videoSendRestore?.spotlightAdded == true, !spotNote.hasPrefix("spotlighted") { videoSendRestore?.spotlightAdded = false }
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(1500)); p.resumeCamera() }
        sendingAsVideo = true
        p.onAir = true
        p.shareMode = "camera-video"
        ShowLog.log("preview: \(cam.name)\(p.cameraAudioName.map { " + \($0)" } ?? "") LIVE AS VIDEO (ARC Zoom's own camera\(p.cameraAudioName == nil ? "" : " and mic, MUSIC preset"), \(spotNote))"
                    + (notes.isEmpty ? "" : "; " + notes.joined(separator: "; ")))
        if !notes.isEmpty { lastError = notes.joined(separator: "; ") }
        return true
    }

    /// STOP from AS VIDEO: camera, mic, preset, mix-minus, own video and audio, spotlight, all back as they were.
    func endPreviewVideo(_ p: PreviewPlayer) async {
        guard let r = videoSendRestore else { sendingAsVideo = false; p.onAir = false; p.shareMode = nil; return }
        videoSendRestore = nil
        if state == .inMeeting {
            if r.spotlightAdded, let id = myID { _ = await spotlight(id, on: false) }
            _ = setOwnVideo(on: r.videoOn)
            _ = setOwnAudio(on: r.audioOn)
        }
        if let c = r.camera, let dev = cameraList().first(where: { $0.name == c }) { _ = selectCamera(id: dev.deviceID) }
        if let m = r.mic { _ = selectAudio(mic: true, id: m) }
        micIsMixMinus = r.mixMinus
        _ = applyPreset(r.preset)
        sendingAsVideo = false
        p.onAir = false
        p.shareMode = nil
        ShowLog.log("preview: AS VIDEO ended; camera \(r.camera ?? "?"), mic \(r.mic ?? "?"), \(r.preset.uppercased()), own video \(r.videoOn ? "on" : "off"), mic \(r.audioOn ? "open" : "muted") restored")
    }
}
