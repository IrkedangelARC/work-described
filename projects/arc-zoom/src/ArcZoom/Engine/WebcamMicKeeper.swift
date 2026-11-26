//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AVFoundation

/// Keeps a webcam's VIDEO stream open so its MICROPHONE delivers audio.
///
/// MEASURED 2026-09-21 on the OBSBOT Meet 2: with its camera closed, the microphone hands every
/// process exact digital zeros (ARC Zoom with a fresh grant, a plain-process AVAudioEngine tap, a raw
/// CoreAudio IOProc: 0.0 in every sample). With the camera's video endpoint open in the same process
/// the same microphone reads −9 dBFS. That is why the Zoom client, with video up, heard it and nothing
/// else did. A show that pins such a mic and sends a different camera (the UltraStudio) would put a
/// SILENT mic into the call, so the hold is not a test option: it runs whenever the pinned mic has a
/// camera of its make and that camera is not the one the SDK is sending.
@MainActor
final class WebcamMicKeeper {
    private(set) var heldCamera: String?
    private(set) var forMic: String?
    private var session: AVCaptureSession?

    /// The camera that shares this microphone's make, if any: "OBSBOT Meet 2 Microphone" ->
    /// "OBSBOT Meet 2 StreamCamera". Pure on the names, so it is tested.
    static func cameraName(forMic mic: String, cameras: [String]) -> String? {
        guard let make = mic.split(separator: " ").first.map(String.init), !make.isEmpty,
              make.lowercased() != "same" else { return nil }
        return cameras.first { $0.localizedCaseInsensitiveContains(make) }
    }

    static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
    }

    /// Hold the mic's camera open, unless the SDK is already sending it (two readers on one camera in
    /// the same process is not worth the risk when the SDK's own stream keeps it awake anyway).
    /// Returns what is held after the call.
    @discardableResult
    func update(mic: String?, sendingCamera: String?) -> String? {
        let cams = Self.availableCameras()
        let wanted = mic.flatMap { Self.cameraName(forMic: $0, cameras: cams.map(\.localizedName)) }
        guard let wanted, wanted != sendingCamera else { release(); return nil }
        if heldCamera == wanted { return wanted }
        release()
        guard let cam = cams.first(where: { $0.localizedName == wanted }), let input = try? AVCaptureDeviceInput(device: cam) else { return nil }
        let s = AVCaptureSession()
        s.beginConfiguration()
        if s.canAddInput(input) { s.addInput(input) }
        let out = AVCaptureVideoDataOutput()   // a sink so the stream really runs; frames go nowhere
        if s.canAddOutput(out) { s.addOutput(out) }
        s.commitConfiguration()
        s.startRunning()
        session = s
        heldCamera = wanted
        forMic = mic
        ShowLog.log("mic keeper: \(wanted) held open so \(mic ?? "the mic") delivers audio")
        return wanted
    }

    func release() {
        guard let s = session else { return }
        s.stopRunning()
        session = nil
        ShowLog.log("mic keeper: released \(heldCamera ?? "the camera")")
        heldCamera = nil
        forMic = nil
    }
}
