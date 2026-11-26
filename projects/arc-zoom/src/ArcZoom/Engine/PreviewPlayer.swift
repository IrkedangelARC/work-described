//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AppKit
import AVFoundation
import MediaToolbox
import CoreVideo
import QuartzCore

/// Where a shared picture and its sound go. The Zoom raw share source is one (`ZoomShareSink`); the tests use a
/// recording one, which is how the whole file path (decode, I420, timing, audio packing) is checked with no
/// meeting. Called from the pump and send queues, never the main thread.
protocol ShareSink: AnyObject, Sendable {
    /// One I420 frame, `count` bytes, even `width` x `height`; `fullRange` false = video range (I420_Limited).
    func sendFrame(_ bytes: UnsafeMutablePointer<UInt8>, count: Int, width: Int, height: Int, fullRange: Bool)
    /// Interleaved 16-bit PCM, one 10 ms chunk.
    func sendAudio(_ samples: [Int16], rate: Int, channels: Int)
}

/// THE PREVIEW MODULE's engine (2026-09-24: "i would like a way to preview the camera before sharing.
/// this should apply to the video file playback as well"; "share video file has no way to play?").
///
/// CAMERA: an AVCaptureSession drawn by a preview layer. The camera itself is shared by the SDK
/// (`startShareCamera`, which already works), so SHARE THIS sends exactly that device.
/// FILE: an AVPlayer drawn by an AVPlayerLayer. While shared, the SAME player item feeds the call: frames
/// from an AVPlayerItemVideoOutput (NV12 -> I420) and sound from an MTAudioProcessingTap, into a `ShareSink`.
/// Pause, seek, loop and restart act on the player, so they act on the share. The local monitor volume and
/// mute are applied INSIDE the tap after the copy for the call is taken: what the room hears here never
/// changes what the call gets.
@MainActor
@Observable
final class PreviewPlayer {
    enum Source: Equatable {
        case off
        case camera(id: String, name: String)
        case file(URL)
        var word: String {
            switch self { case .off: return "OFF"; case .camera: return "CAMERA"; case .file: return "FILE" }
        }
    }

    private(set) var source: Source = .off
    private(set) var transport = PreviewTransport()
    /// The file the operator chose, and what AVFoundation plays (the same, or ffmpeg's temporary mp4).
    private(set) var originalURL: URL?
    private(set) var playURL: URL?
    private(set) var position: Double = 0
    private(set) var naturalSize: CGSize = .zero
    /// Local monitoring only: never what the call gets. Kept per source: a FILE monitors at 0.8, a CAMERA's
    /// audio input is MUTED until the operator opens it (an ATEM's program sound on the room's speakers
    /// is a feedback loop waiting to happen, 2026-09-24).
    private var fileMonitor: (volume: Float, muted: Bool) = (0.8, false)
    private var cameraMonitor: (volume: Float, muted: Bool) = (0.8, true)
    private var isCameraSource: Bool { if case .camera = source { return true }; return false }
    var monitorVolume: Float {
        get { isCameraSource ? cameraMonitor.volume : fileMonitor.volume }
        set { let v = max(0, min(1, newValue)); if isCameraSource { cameraMonitor.volume = v } else { fileMonitor.volume = v }; applyMonitor() }
    }
    var monitorMuted: Bool {
        get { isCameraSource ? cameraMonitor.muted : fileMonitor.muted }
        set { if isCameraSource { cameraMonitor.muted = newValue } else { fileMonitor.muted = newValue }; applyMonitor() }
    }
    /// PFL: the output device every local listen goes to (file and camera AUDIO IN alike), chosen by the
    /// operator and remembered. nil = OFF: nothing is heard locally. Never the room by accident: the
    /// monitor used to play on the Mac's DEFAULT output, the same Anker carrying the call into the room,
    /// and the room heard the file twice (2026-09-24: "echo on the anker while playing back").
    var pflUID: String? = UserDefaults.standard.string(forKey: "previewPFL") {
        didSet { UserDefaults.standard.set(pflUID, forKey: "previewPFL"); applyMonitor(); ShowLog.log("preview: PFL \(pflUID.flatMap(AudioOutputs.name(uid:)) ?? (pflUID == nil ? "OFF" : "unplugged device"))") }
    }
    private var fileGain: Float { pflUID == nil || fileMonitor.muted ? 0 : fileMonitor.volume }
    private var cameraGain: Float { pflUID == nil || cameraMonitor.muted ? 0 : cameraMonitor.volume }
    private func applyMonitor() {
        // Re-routed only when it changes: assigning the output device (even nil) rebuilds the player's audio
        // path, and that moved the sound ~0.1 s ahead of the picture in the share (PreviewTests sync check).
        if player.audioOutputDeviceUniqueID != pflUID { player.audioOutputDeviceUniqueID = pflUID }
        tapContext?.setMonitor(gain: fileGain)
        audioMonitorOutput?.outputDeviceUniqueID = pflUID
        audioMonitorOutput?.volume = cameraGain
    }
    /// The CAMERA source's AUDIO IN: nil = none (picture only, shared by the SDK's own camera share); an input
    /// device's uniqueID = the camera and this input go out together through the raw share source.
    private(set) var cameraAudioID: String?
    private(set) var cameraAudioName: String?
    /// With an audio input the camera goes through the raw share path; without, through startShareCamera.
    var cameraShareIsRaw: Bool { isCameraSource && cameraAudioID != nil }
    var loop: Bool {
        get { transport.loop }
        set { transport.loop = newValue }
    }
    /// The file's sound, 0...1, pre-monitor (what the call gets).
    private(set) var level: Float = 0
    /// One line under the transport: a conversion, a fallback, a refusal.
    var note: String?
    /// The camera session is running (the device is held).
    private(set) var cameraRunning = false
    /// Set by the engine while this module's source is what the call sees.
    var onAir = false
    /// CAMERA only: SEND AS VIDEO (ARC Zoom's own camera, spotlighted: well under a second) instead of a share
    /// (seconds: Zoom buffers shares). Remembered.
    var sendAsVideo: Bool = UserDefaults.standard.bool(forKey: "previewSendAsVideo") {
        didSet { UserDefaults.standard.set(sendAsVideo, forKey: "previewSendAsVideo") }
    }
    /// "camera", "file-raw" (the player feeds the call: transport is live) or "file-sdk" (Zoom plays the
    /// file itself: the transport does not reach the call). nil when not on air.
    var shareMode: String?

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored let playerLayer = AVPlayerLayer()
    @ObservationIgnored let cameraLayer = AVCaptureVideoPreviewLayer()
    @ObservationIgnored private var captureSession: AVCaptureSession?
    @ObservationIgnored let cameraFeed = CameraFeed()
    @ObservationIgnored private var audioMonitorOutput: AVCaptureAudioPreviewOutput?
    @ObservationIgnored private let captureQueue = DispatchQueue(label: "arc.zoom.preview.capture")
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private(set) var tapContext: TapContext?
    @ObservationIgnored private(set) var pump: VideoPump?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var conversion: Process?
    @ObservationIgnored private var conversionPartial: URL?
    @ObservationIgnored private var loadToken = 0

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        cameraLayer.videoGravity = .resizeAspect
        cameraLayer.backgroundColor = NSColor.black.cgColor
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickMeter() }
        }
    }

    #if DEBUG
    /// Layout tests and their screenshots only: the module drawn with a source and a loaded transport, no device
    /// opened and no file read. Compiled out of Release.
    func stageForLayout(_ src: Source, duration: Double = 95, position: Double = 12, audioIn: String? = nil, onAir: Bool = false) {
        source = src
        transport = PreviewTransport()
        if case .file = src { transport.handle(.load); transport.handle(.loaded(duration: duration)); self.position = position }
        if case .camera = src { cameraAudioID = audioIn; cameraAudioName = audioIn; naturalSize = CGSize(width: 1920, height: 1080) }
        self.onAir = onAir
        shareMode = onAir ? (src == .off ? nil : "file-raw") : nil
    }
    #endif

    // MARK: - Sources

    /// Cameras AVFoundation can preview: built-in, USB / UVC, and iPhone Continuity.
    static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
    }

    /// The preview device for a camera the SDK lists: the SDK's device id IS AVFoundation's uniqueID for
    /// cameras on this SDK (the name is the fallback: its AUDIO ids are names, 2026-09-21).
    static func device(id: String, name: String) -> AVCaptureDevice? {
        let all = availableCameras()
        return all.first { $0.uniqueID == id } ?? all.first { $0.localizedName == name } ?? all.first { $0.localizedName.localizedCaseInsensitiveContains(name) }
    }

    /// Preview a camera. Releases whatever the module held before (the file keeps its place, paused).
    func previewCamera(id: String, name: String) {
        if case .camera(let cur, _) = source, cur == id, cameraRunning { return }
        pauseForSourceChange()
        stopCamera()
        source = .camera(id: id, name: name)
        note = nil
        // The audio input remembered for THIS camera (the ATEM's own USB audio, usually).
        let remembered = OperatorPrefs.string("previewAudio." + name)
        let inputs = Self.availableAudioInputs()
        let dev = remembered.flatMap { r in inputs.first { $0.uniqueID == r } ?? inputs.first { $0.localizedName == r } }
        cameraAudioID = dev?.uniqueID
        cameraAudioName = dev?.localizedName
        startCamera()
    }

    /// OFF: the camera is released, the file is paused and kept loaded.
    func previewOff() {
        if isConverting { cancelConvert(); return }
        pauseForSourceChange()
        stopCamera()
        source = .off
    }

    /// The camera format PREVIEW and its share use: the most pixels up to 1920x1080 at 25 fps or more.
    static func bestFormat(_ dev: AVCaptureDevice) -> AVCaptureDevice.Format? {
        dev.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width <= 1920 && d.height <= 1080 && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 25 }
        }.max { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription), db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
        }
    }

    /// Audio inputs a camera can be paired with (USB interfaces, the ATEM, built-in mics, virtual devices).
    static func availableAudioInputs() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    /// AUDIO IN for the camera source: nil = none (video only). Remembered per camera, by name, and applied
    /// by rebuilding the session. Refused while that camera is on air (the share would change under the call).
    @discardableResult
    func setCameraAudio(id: String?) -> Bool {
        guard case .camera(_, let camName) = source else { note = "AUDIO IN belongs to the CAMERA source"; return false }
        guard !onAir else { note = "stop the share before changing its AUDIO IN"; return false }
        let dev = id.flatMap { i in Self.availableAudioInputs().first { $0.uniqueID == i || $0.localizedName == i } }
        if id != nil, dev == nil { note = "no audio input \(id!)"; return false }
        cameraAudioID = dev?.uniqueID
        cameraAudioName = dev?.localizedName
        OperatorPrefs.set("previewAudio." + camName, dev?.localizedName ?? "")
        ShowLog.log("preview: \(camName) audio in = \(dev?.localizedName ?? "none (video only)")")
        stopCamera()
        startCamera()
        return true
    }

    private func startCamera() {
        guard case .camera(let id, let name) = source else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            note = "camera access is off for ARC Zoom (System Settings > Privacy > Camera)"; return
        default: break
        }
        guard let dev = Self.device(id: id, name: name), let input = try? AVCaptureDeviceInput(device: dev) else {
            note = "\(name) cannot be previewed (unplugged, or not a camera AVFoundation sees)"; return
        }
        let s = AVCaptureSession()
        s.beginConfiguration()
        // The format is CHOSEN, not left to a preset: the size used to be read before the preset applied, so an
        // iPhone (Continuity Camera) that opens at 640x480 previewed, and would have shared, at 640x480
        // (2026-09-24). Largest format up to 1920x1080 that runs at 25 fps or more; the share never sends more.
        if s.canAddInput(input) { s.addInput(input) }
        let best = Self.bestFormat(dev)
        func pin() { if let best, dev.activeFormat != best, (try? dev.lockForConfiguration()) != nil { dev.activeFormat = best; dev.unlockForConfiguration() } }
        if best == nil, s.canSetSessionPreset(.high) { s.sessionPreset = .high }
        pin()
        var dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
        naturalSize = CGSize(width: Int(dims.width), height: Int(dims.height))
        // With an AUDIO IN the camera is shared RAW: a data output for the frames (NV12, scaled to the share
        // size), the input on the SAME session (one clock), a data output for its sound (48 kHz Int16 stereo)
        // and a local monitor that starts muted.
        if let aid = cameraAudioID {
            let share = I420.shareSize(natural: naturalSize)
            let vOut = AVCaptureVideoDataOutput()
            vOut.alwaysDiscardsLateVideoFrames = true
            vOut.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: share.width, kCVPixelBufferHeightKey as String: share.height,
            ]
            vOut.setSampleBufferDelegate(cameraFeed, queue: cameraFeed.videoQueue)
            if s.canAddOutput(vOut) { s.addOutput(vOut) }
            if let adev = Self.availableAudioInputs().first(where: { $0.uniqueID == aid }), let ain = try? AVCaptureDeviceInput(device: adev), s.canAddInput(ain) {
                s.addInput(ain)
                let aOut = AVCaptureAudioDataOutput()
                aOut.audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: CameraFeed.audioRate, AVNumberOfChannelsKey: CameraFeed.audioChannels,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
                ]
                aOut.setSampleBufferDelegate(cameraFeed, queue: cameraFeed.audioQueue)
                if s.canAddOutput(aOut) { s.addOutput(aOut) }
                let mon = AVCaptureAudioPreviewOutput()
                mon.outputDeviceUniqueID = pflUID
                mon.volume = cameraGain
                if s.canAddOutput(mon) { s.addOutput(mon); audioMonitorOutput = mon }
            } else {
                note = "the audio input \(cameraAudioName ?? aid) could not be opened: the share would be picture only"
            }
        }
        s.commitConfiguration()
        // A session can re-pick the format on commit: pin it again and take the size it really runs at.
        pin()
        dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
        if Int(dims.width) != Int(naturalSize.width) { ShowLog.log("preview: camera format changed on commit to \(dims.width)x\(dims.height)") }
        naturalSize = CGSize(width: Int(dims.width), height: Int(dims.height))
        cameraFeed.setClock(s.synchronizationClock)
        cameraLayer.session = s
        captureSession = s
        cameraRunning = true
        captureQueue.async { s.startRunning() }
        ShowLog.log("preview: camera \(dev.localizedName) (\(dims.width)x\(dims.height))\(cameraAudioName.map { ", audio in \($0)" } ?? "")")
    }

    /// Releases the device (the camera LED goes out when nothing else holds it).
    func stopCamera() {
        guard let s = captureSession else { return }
        captureSession = nil
        cameraRunning = false
        cameraFeed.detach()
        audioMonitorOutput = nil
        cameraLayer.session = nil
        captureQueue.async { s.stopRunning() }
        ShowLog.log("preview: camera released")
    }

    /// The SDK is about to open this camera for its share: our session steps aside so the SDK negotiates the
    /// device alone, then comes back (`resumeCamera`) and joins it at the format the SDK chose.
    func yieldCameraToShare() { stopCamera() }
    func resumeCamera() { if case .camera = source, captureSession == nil { startCamera() } }

    private func pauseForSourceChange() {
        if transport.isPlaying { apply(transport.handle(.pause)) }
    }

    // MARK: - Files

    /// Load a file. mov / mp4 / m4v play directly; anything else goes through ffmpeg to a temporary mp4 when
    /// one is found, with progress, and is refused plainly otherwise.
    func loadFile(_ url: URL) {
        stopCamera()
        cancelConversion()
        loadToken += 1
        let token = loadToken
        source = .file(url)
        originalURL = url
        playURL = nil
        note = nil
        position = 0
        detachItem()
        apply(transport.handle(.load))
        guard FileManager.default.isReadableFile(atPath: url.path) else { fail("cannot read \(url.lastPathComponent)"); return }
        if PreviewFormats.needsConversion(url) {
            guard let ffmpeg = Self.locateFFmpeg() else {
                fail("\(url.pathExtension.lowercased()) needs ffmpeg and none was found: \(PreviewFormats.sayWhatWorks)")
                return
            }
            convert(url, ffmpeg: ffmpeg, token: token)
        } else {
            Task { await open(url, token: token) }
        }
    }

    func unload() {
        cancelConversion()
        detachItem()
        apply(transport.handle(.unload))
        originalURL = nil; playURL = nil; position = 0
        if case .file = source { source = .off }
    }

    private func fail(_ why: String) {
        apply(transport.handle(.failed(why)))
        note = why
        ShowLog.error("preview: \(why)")
    }

    private func open(_ url: URL, token: Int) async {
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard token == loadToken else { return }
        guard playable, !videoTracks.isEmpty else {
            fail("\(url.lastPathComponent) does not play in AVFoundation\(videoTracks.isEmpty ? " (no picture)" : ""): \(PreviewFormats.sayWhatWorks)")
            return
        }
        var size = (try? await videoTracks[0].load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        if let t = try? await videoTracks[0].load(.preferredTransform) { size = size.applying(t); size = CGSize(width: abs(size.width), height: abs(size.height)) }
        guard token == loadToken else { return }
        naturalSize = size
        playURL = url
        let item = AVPlayerItem(asset: asset)
        let share = I420.shareSize(natural: size)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: share.width,
            kCVPixelBufferHeightKey as String: share.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        item.add(out)
        videoOutput = out
        let ctx = TapContext()
        ctx.setMonitor(gain: fileGain)
        if let track = audioTracks.first, let mix = Self.audioMix(track: track, context: ctx) { item.audioMix = mix }
        tapContext = ctx
        pump = VideoPump(output: out, tap: ctx)
        player.replaceCurrentItem(with: item)
        player.volume = 1   // the monitor gain lives in the tap
        if player.audioOutputDeviceUniqueID != pflUID { player.audioOutputDeviceUniqueID = pflUID }
        installObservers(item)
        apply(transport.handle(.loaded(duration: duration)))
        ShowLog.log("preview: file \(url.lastPathComponent), \(PreviewTime.clock(duration)), \(Int(size.width))x\(Int(size.height)), shares at \(share.width)x\(share.height)\(audioTracks.isEmpty ? ", no sound" : "")")
    }

    private func detachItem() {
        pump?.stop()
        pump = nil
        if let t = timeObserver { player.removeTimeObserver(t); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        tapContext?.detach()
        tapContext = nil
        videoOutput = nil
        player.replaceCurrentItem(with: nil)
        level = 0
    }

    private func installObservers(_ item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.position = t.seconds.isFinite ? t.seconds : 0 }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.apply(self.transport.handle(.reachedEnd)) }
        }
    }

    /// One meter for whichever source is up: the file's tap, or the camera's audio input.
    private func tickMeter() {
        let peak: Float
        switch source {
        case .file: peak = tapContext?.takePeak() ?? 0
        case .camera: peak = cameraAudioID == nil ? 0 : cameraFeed.takePeak()
        case .off: peak = 0
        }
        let target = ShareAudio.meterLevel(peak: peak)
        let next = target > level ? target : level * 0.8 + target * 0.2
        if abs(next - level) > 0.004 { level = next < 0.01 ? 0 : next }
    }

    /// The tap on the file's first audio track: it sees every buffer the player renders, takes the call's copy,
    /// then scales the buffer in place for the local monitor.
    static func audioMix(track: AVAssetTrack, context: TapContext) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                var range = CMTimeRange()
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut) == noErr else { return }
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .process(bufferList, frames: Int(framesOut.pointee), range: range)
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr, let tap else {
            Unmanaged<TapContext>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    // MARK: - Transport

    func play() { apply(transport.handle(.play)) }
    func pause() { apply(transport.handle(.pause)) }
    func toggle() { apply(transport.handle(.toggle)) }
    func restart() { apply(transport.handle(.restart)) }
    func seek(to t: Double) { apply(transport.handle(.seek(t))) }

    private func apply(_ effect: PreviewTransport.Effect) {
        switch effect {
        case .none: break
        case .play: player.play()
        case .pause: player.pause()
        case .seek(let t): seekPlayer(t, thenPlay: false)
        case .seekAndPlay(let t): seekPlayer(t, thenPlay: true)
        }
    }

    private func seekPlayer(_ t: Double, thenPlay: Bool) {
        guard player.currentItem != nil else { return }
        tapContext?.resetTiming()
        pump?.resetTiming()
        position = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard thenPlay else { return }
            Task { @MainActor in self?.player.play() }
        }
    }

    // MARK: - The share (attached by the engine's raw share source)

    /// Frames and sound start flowing into `sink`. Idempotent: the video and audio senders arrive separately.
    func attach(_ sink: ShareSink) {
        startRateLog()
        if isCameraSource { cameraFeed.attach(sink); return }
        tapContext?.attach(sink)
        pump?.start(sink)
    }

    func detachShare() {
        rateLog?.cancel(); rateLog = nil
        cameraFeed.detach()
        tapContext?.detach()
        pump?.stop()
    }

    /// Every 10 s on air: frames and sound chunks actually handed to the call. "Choppy on the iPad"
    /// (2026-09-24) needs to be told apart: a low number here is ours, a steady 30 is Zoom's encode or the
    /// viewer's link.
    @ObservationIgnored private var rateLog: Task<Void, Never>?
    private func startRateLog() {
        rateLog?.cancel()
        rateLog = Task { @MainActor [weak self] in
            var f0 = self?.sentFrames ?? 0, a0 = self?.sentAudioChunks ?? 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                let f = self.sentFrames, a = self.sentAudioChunks
                ShowLog.log("raw share: \(String(format: "%.1f", Double(f - f0) / 10)) fps, \(String(format: "%.0f", Double(a - a0) / 10 * 10)) ms of sound per s sent (\(self.transport.word))")
                f0 = f; a0 = a
            }
        }
    }

    /// Counters for GET /preview: what was actually handed to the call.
    var sentFrames: Int { isCameraSource ? cameraFeed.stats.frames : (pump?.sentFrames ?? 0) }
    var sentAudioChunks: Int { isCameraSource ? cameraFeed.stats.chunks : (tapContext?.sentChunks ?? 0) }
    /// File: how far the tap runs ahead of the picture (the video poll follows it). Camera: how long the
    /// audio is held behind the slower video path.
    var audioLead: Double { isCameraSource ? Double(cameraFeed.stats.audioHoldMs) / 1000 : (pump?.lead ?? 0) }

    // MARK: - ffmpeg

    static func locateFFmpeg() -> String? {
        let fm = FileManager.default
        var apps: [String] = []
        for dir in [fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path, "/Applications"] {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".app") { apps.append((dir as NSString).appendingPathComponent(name)) }
        }
        return FFmpeg.locate(apps: apps) { fm.isExecutableFile(atPath: $0) }
    }

    private static let conversionDir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ARC Zoom Preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func cancelConversion() {
        if let p = conversion, p.isRunning { p.terminate() }
        conversion = nil
        if let part = conversionPartial { try? FileManager.default.removeItem(at: part) }
        conversionPartial = nil
    }

    var isConverting: Bool { if case .converting = transport.phase { return true } else { return false } }

    /// CANCEL on a conversion (2026-09-24: "stop conversion"; OFF left ffmpeg running and a kill read
    /// as FAILED). Stops ffmpeg, drops the partial file, and leaves the module empty, not failed.
    func cancelConvert() {
        guard isConverting || conversion != nil else { return }
        loadToken += 1   // the termination handler of the killed run must not report it
        cancelConversion()
        detachItem()
        apply(transport.handle(.unload))
        originalURL = nil; playURL = nil; position = 0
        source = .off
        note = "conversion cancelled"
        ShowLog.log("preview: conversion cancelled")
    }

    /// Probe, plan (remux / audio only / full), run with `-progress`, then open the mp4. A converted file is
    /// kept for the session (named by source path and date), so a reload is instant.
    private func convert(_ url: URL, ffmpeg: String, token: Int) {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        let out = Self.conversionDir.appendingPathComponent(FFmpeg.outputName(for: url.path, modified: modified))
        if FileManager.default.fileExists(atPath: out.path) {
            note = "converted earlier: \(out.lastPathComponent)"
            Task { await open(out, token: token) }
            return
        }
        apply(transport.handle(.converting(0)))
        let input = url.path
        Task.detached {
            let probeText = Self.run(ffmpeg, ["-hide_banner", "-nostdin", "-i", input]).stderr
            let probe = FFmpeg.parseProbe(probeText)
            let plan = FFmpeg.plan(for: probe)
            let encoders = plan == .full ? Self.run(ffmpeg, ["-hide_banner", "-encoders"]).stdout : ""
            let args = FFmpeg.arguments(input: input, output: out.path + ".part.mp4", plan: plan, encoders: encoders, hevc: probe.video == "hevc")
            await MainActor.run {
                guard token == self.loadToken else { return }
                self.note = "converting with ffmpeg (\(plan == .remux ? "remux, no quality loss" : (plan == .audioOnly ? "sound to AAC" : "full re-encode"))): \((ffmpeg as NSString).deletingLastPathComponent.components(separatedBy: "/").first { $0.hasSuffix(".app") } ?? ffmpeg)"
                ShowLog.log("preview: ffmpeg \(args.joined(separator: " "))")
                self.conversionPartial = URL(fileURLWithPath: out.path + ".part.mp4")
                self.startConversion(ffmpeg, args: args, duration: probe.duration, partial: URL(fileURLWithPath: out.path + ".part.mp4"), final: out, token: token)
            }
        }
    }

    private func startConversion(_ ffmpeg: String, args: [String], duration: Double?, partial: URL, final: URL, token: Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = args
        let pipe = Pipe(), err = Pipe()
        p.standardOutput = pipe
        p.standardError = err
        let errTail = LockedText()
        err.fileHandleForReading.readabilityHandler = { h in errTail.append(String(decoding: h.availableData, as: UTF8.self)) }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            for line in text.split(separator: "\n") {
                if let prog = FFmpeg.progress(line: String(line), duration: duration) {
                    Task { @MainActor in guard let self, token == self.loadToken else { return }; self.apply(self.transport.handle(.converting(prog))) }
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            Task { @MainActor in
                guard let self, token == self.loadToken else { return }
                self.conversion = nil
                self.conversionPartial = nil
                if status == 0, (try? FileManager.default.moveItem(at: partial, to: final)) != nil {
                    self.note = "converted to mp4 for the preview and the share"
                    await self.open(final, token: token)
                } else {
                    try? FileManager.default.removeItem(at: partial)
                    let tail = errTail.text.split(separator: "\n").suffix(2).joined(separator: " ")
                    self.fail("ffmpeg could not convert it (exit \(status))\(tail.isEmpty ? "" : ": \(tail)")")
                }
            }
        }
        do { try p.run(); conversion = p } catch { fail("ffmpeg did not start: \(error.localizedDescription)") }
    }

    nonisolated static func run(_ exe: String, _ args: [String]) -> (stdout: String, stderr: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        guard (try? p.run()) != nil else { return ("", "", -1) }
        let od = o.fileHandleForReading.readDataToEndOfFile(), ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: od, as: UTF8.self), String(decoding: ed, as: UTF8.self), p.terminationStatus)
    }

    // MARK: - Control API

    var json: String {
        let src: String
        switch source {
        case .off: src = "{\"kind\":\"off\"}"
        case .camera(let id, let name): src = "{\"kind\":\"camera\",\"id\":\"\(jsonEscape(id))\",\"name\":\"\(jsonEscape(name))\",\"running\":\(cameraRunning),\"audioIn\":\(cameraAudioName.map { "\"\(jsonEscape($0))\"" } ?? "null"),\"raw\":\(cameraShareIsRaw)}"
        case .file(let u): src = "{\"kind\":\"file\",\"path\":\"\(jsonEscape(u.path))\",\"plays\":\(playURL.map { "\"\(jsonEscape($0.path))\"" } ?? "null")}"
        }
        let cams = Self.availableCameras().map { "{\"id\":\"\(jsonEscape($0.uniqueID))\",\"name\":\"\(jsonEscape($0.localizedName))\"}" }.joined(separator: ",")
        let ins = Self.availableAudioInputs().map { "{\"id\":\"\(jsonEscape($0.uniqueID))\",\"name\":\"\(jsonEscape($0.localizedName))\"}" }.joined(separator: ",")
        let ff = Self.locateFFmpeg().map { "\"\(jsonEscape($0))\"" } ?? "null"
        return "{\"source\":\(src),\"state\":\"\(transport.word)\",\"position\":\(jsonNumber(position)),\"duration\":\(jsonNumber(transport.duration)),"
            + "\"loop\":\(loop),\"monitorVolume\":\(jsonNumber(Double(monitorVolume))),\"monitorMuted\":\(monitorMuted),\"sendAsVideo\":\(sendAsVideo),\"pfl\":\(pflUID.map { "{\"id\":\"\(jsonEscape($0))\",\"name\":\"\(jsonEscape(AudioOutputs.name(uid: $0) ?? "unplugged"))\"}" } ?? "null"),\"level\":\(jsonNumber(Double(level))),"
            + "\"size\":[\(Int(naturalSize.width)),\(Int(naturalSize.height))],\"onAir\":\(onAir),\"shareMode\":\(shareMode.map { "\"\($0)\"" } ?? "null"),"
            + "\"sent\":{\"frames\":\(sentFrames),\"audioChunks\":\(sentAudioChunks),\"audioLeadMs\":\(Int(audioLead * 1000))},"
            + "\"note\":\(note.map { "\"\(jsonEscape($0))\"" } ?? "null"),\"ffmpeg\":\(ff),\"cameras\":[\(cams)],\"audioInputs\":[\(ins)]}"
    }
}

/// A string many threads append to (ffmpeg's stderr tail).
final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = ""
    func append(_ s: String) { lock.lock(); buf += s; if buf.count > 4000 { buf = String(buf.suffix(2000)) }; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return buf }
}

// MARK: - The audio tap's state (render thread in, send queue out)

/// Everything the MTAudioProcessingTap callbacks touch. The render thread only COPIES (Float planes, the time
/// range) and scales for the monitor; packing, resampling and sending happen on `sendQueue`.
final class TapContext: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: ShareSink?
    private var monitorGain: Float = 1
    private var peak: Float = 0
    private var format = AudioStreamBasicDescription()
    private var latest: (end: Double, host: Double)?
    private let sendQueue = DispatchQueue(label: "arc.zoom.preview.audio")
    // sendQueue only:
    private var chunker: AudioChunker?
    /// Chunks waiting for the player's clock (AudioReleaseQueue); pushed on sendQueue, drained by the pump.
    private var release = AudioReleaseQueue()
    private var converter: AVAudioConverter?
    private var converterIn: AVAudioFormat?
    private var resetPending = false
    private var sentChunksStore = 0
    var sentChunks: Int { lock.lock(); defer { lock.unlock() }; return sentChunksStore }

    func attach(_ s: ShareSink) { lock.lock(); sink = s; lock.unlock() }
    func detach() { lock.lock(); sink = nil; lock.unlock() }
    func setMonitor(gain: Float) { lock.lock(); monitorGain = gain; lock.unlock() }
    func takePeak() -> Float { lock.lock(); defer { peak = 0; lock.unlock() }; return peak }
    func resetTiming() { lock.lock(); latest = nil; release.flush(); lock.unlock(); sendQueue.async { self.resetPending = true } }
    /// The pump's tick: the chunks whose item time the player has reached.
    func dueAudio(upTo now: Double) -> [AudioReleaseQueue.Chunk] { lock.lock(); defer { lock.unlock() }; return release.due(upTo: now) }
    func flushAudio() { lock.lock(); release.flush(); lock.unlock() }
    /// The item time the last handed-over audio ENDS at, and the host time it was handed over.
    var latestAudio: (end: Double, host: Double)? { lock.lock(); defer { lock.unlock() }; return latest }

    func prepare(_ f: AudioStreamBasicDescription) { lock.lock(); format = f; lock.unlock() }

    /// Render thread. Copy for the call, meter, then apply the local monitor gain in place.
    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, range: CMTimeRange) {
        lock.lock()
        let f = format, gain = monitorGain, target = sink
        lock.unlock()
        guard frames > 0, f.mFormatID == kAudioFormatLinearPCM, f.mFormatFlags & kAudioFormatFlagIsFloat != 0, f.mBitsPerChannel == 32 else { return }
        let abl = UnsafeMutableAudioBufferListPointer(list)
        let nonInterleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = Int(f.mChannelsPerFrame)
        var planes: [[Float]] = []
        var p: Float = 0
        if nonInterleaved {
            for b in abl { guard let d = b.mData else { continue }
                let ptr = d.assumingMemoryBound(to: Float.self)
                let plane = Array(UnsafeBufferPointer(start: ptr, count: frames))
                for v in plane { p = max(p, abs(v)) }
                if target != nil { planes.append(plane) }
            }
        } else if let d = abl.first?.mData, channels > 0 {
            let ptr = d.assumingMemoryBound(to: Float.self)
            if target != nil { planes = (0..<channels).map { c in (0..<frames).map { ptr[$0 * channels + c] } } }
            for i in 0..<(frames * channels) { p = max(p, abs(ptr[i])) }
        }
        let end = range.end.seconds
        lock.lock()
        peak = max(peak, p)
        if end.isFinite { latest = (end, CACurrentMediaTime()) }
        lock.unlock()
        if target != nil, !planes.isEmpty {
            let rate = f.mSampleRate, start = range.start.seconds
            sendQueue.async { self.queue(planes, sourceRate: rate, start: start) }
        }
        if gain != 1 {
            for b in abl { guard let d = b.mData else { continue }
                let ptr = d.assumingMemoryBound(to: Float.self), n = Int(b.mDataByteSize) / 4
                for i in 0..<n { ptr[i] *= gain }
            }
        }
    }

    /// Send queue: resample when Zoom does not take the file's rate, pack to Int16, cut into 10 ms chunks, and
    /// queue each with the item time it starts at (the buffer's start, less what the chunker still held).
    private func queue(_ planes: [[Float]], sourceRate: Double, start: Double) {
        let rate = ShareAudio.sendRate(for: sourceRate)
        let channels = ShareAudio.sendChannels(for: planes.count)
        if resetPending || chunker == nil || chunker!.channels != channels || chunker!.chunkFrames != ShareAudio.chunkFrames(rate: rate) {
            chunker = AudioChunker(channels: channels, rate: rate)
            resetPending = false
        }
        var use = planes
        if Int(sourceRate.rounded()) != rate, let r = resample(planes, from: sourceRate, to: Double(rate)) { use = r }
        let held = Double(chunker!.pending.count / channels) / Double(rate)
        let chunks = chunker!.push(ShareAudio.interleave(use, channels: channels))
        guard start.isFinite else { return }
        lock.lock()
        for (k, c) in chunks.enumerated() { release.push(.init(time: start - held + Double(k) * 0.01, samples: c, rate: rate, channels: channels)) }
        lock.unlock()
    }
    /// Counted by the pump as it sends.
    func countSent(_ n: Int) { lock.lock(); sentChunksStore += n; lock.unlock() }

    private func resample(_ planes: [[Float]], from: Double, to: Double) -> [[Float]]? {
        let n = planes.count
        guard let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: AVAudioChannelCount(n), interleaved: false),
              let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: AVAudioChannelCount(n), interleaved: false),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(planes[0].count)) else { return nil }
        if converter == nil || converterIn != inF { converter = AVAudioConverter(from: inF, to: outF); converterIn = inF }
        guard let converter else { return nil }
        inBuf.frameLength = AVAudioFrameCount(planes[0].count)
        for c in 0..<n { planes[c].withUnsafeBufferPointer { inBuf.floatChannelData![c].update(from: $0.baseAddress!, count: planes[c].count) } }
        let cap = AVAudioFrameCount(Double(planes[0].count) * to / from + 64)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        let len = Int(outBuf.frameLength)
        return (0..<n).map { c in Array(UnsafeBufferPointer(start: outBuf.floatChannelData![c], count: len)) }
    }
}

// MARK: - The video pump (runs only while the file is on air)

/// Polls the player's video output at 60 Hz on its own queue and sends I420 at up to 30 fps, the frame on the
/// player's clock, and releases the audio chunks the clock has reached (AudioReleaseQueue), so picture and
/// sound leave together; the last frame again every 0.2 s while nothing new comes (paused), so the far end holds
/// the picture. AVSyncClock measures how far the tap runs ahead, for GET /preview.
final class VideoPump: @unchecked Sendable {
    private let output: AVPlayerItemVideoOutput
    private let tap: TapContext
    private let queue = DispatchQueue(label: "arc.zoom.preview.video", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var sink: ShareSink?
    private var sync = AVSyncClock()
    private var pacer = FramePacer()
    /// The video time of the last frame sent (the pacer's clock).
    private var lastSentItem: Double?
    private var lastSent: Double?
    private var frame: UnsafeMutablePointer<UInt8>?
    private var frameSize = (w: 0, h: 0, bytes: 0)
    private let lock = NSLock()
    private var counters = (frames: 0, lead: 0.0)
    private var resetPending = false

    init(output: AVPlayerItemVideoOutput, tap: TapContext) { self.output = output; self.tap = tap }
    deinit { timer?.cancel(); frame?.deallocate() }

    var sentFrames: Int { lock.lock(); defer { lock.unlock() }; return counters.frames }
    var lead: Double { lock.lock(); defer { lock.unlock() }; return counters.lead }

    func start(_ s: ShareSink) {
        queue.async {
            self.sink = s
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    func stop() { queue.async { self.timer?.cancel(); self.timer = nil; self.sink = nil; self.lastSent = nil; self.lastSentItem = nil }; tap.flushAudio() }
    func resetTiming() { queue.async { self.resetPending = true } }

    private func tick() {
        guard let sink else { return }
        if resetPending { sync.reset(); resetPending = false }
        let host = CACurrentMediaTime()
        if let a = tap.latestAudio {
            let then = output.itemTime(forHostTime: a.host).seconds
            if then.isFinite { sync.observe(audioEnd: a.end, playerNow: then) }
        }
        let now = output.itemTime(forHostTime: host).seconds
        guard now.isFinite else { return }
        let audio = tap.dueAudio(upTo: now)
        for c in audio { sink.sendAudio(c.samples, rate: c.rate, channels: c.channels) }
        if !audio.isEmpty { tap.countSent(audio.count) }
        let t = CMTime(seconds: now, preferredTimescale: 90000)
        let hasNew = output.hasNewPixelBuffer(forItemTime: t)
        switch pacer.decide(now: host, lastSent: lastSent, hasNew: hasNew, itemTime: now, lastItemTime: lastSentItem) {
        case .skip: return
        case .resend:
            guard let frame, frameSize.bytes > 0 else { return }
            sink.sendFrame(frame, count: frameSize.bytes, width: frameSize.w, height: frameSize.h, fullRange: false)
            lastSent = host
        case .send:
            var shown = CMTime.invalid
            guard let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown), convert(pb) else { return }
            sink.sendFrame(frame!, count: frameSize.bytes, width: frameSize.w, height: frameSize.h, fullRange: false)
            lastSent = host
            lastSentItem = shown.isValid ? shown.seconds : now
            lock.lock(); counters.frames += 1; counters.lead = sync.lead; lock.unlock()
        }
    }

    /// NV12 -> the reused I420 buffer. false for a format the output should never hand back.
    private func convert(_ pb: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPlaneCount(pb) == 2 else { return false }
        let w = CVPixelBufferGetWidth(pb) & ~1, h = CVPixelBufferGetHeight(pb) & ~1
        let bytes = I420.byteCount(width: w, height: h)
        if frameSize.bytes != bytes || frame == nil {
            frame?.deallocate()
            frame = .allocate(capacity: bytes)
            frameSize = (w, h, bytes)
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return false }
        I420.fromNV12(y: y.assumingMemoryBound(to: UInt8.self), yStride: CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                      uv: uv.assumingMemoryBound(to: UInt8.self), uvStride: CVPixelBufferGetBytesPerRowOfPlane(pb, 1),
                      width: w, height: h, into: frame!)
        return true
    }
}
