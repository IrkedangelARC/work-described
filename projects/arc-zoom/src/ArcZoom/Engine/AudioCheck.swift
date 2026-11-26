//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AVFoundation
import CoreAudio
import Observation
import AppKit

/// The two pre-flight checks an operator runs BEFORE the meeting (2026-09-21: "TEST MIC and TEST
/// AUDIO OUT buttons and a test sequence for each that can be done before connecting to a meeting").
///
/// TEST MIC: listen on the mic the call will use for 5 s with a live meter, then play the recording
/// back through the speaker the call will use, so the operator hears what the far end would.
/// Pass = the mic heard something above the floor. The meter is ARC's own AVAudioEngine tap (the
/// proven one); the recording and playback are the SDK's own microphone test helper, so the playback
/// path is Zoom's, not a guess.
///
/// TEST AUDIO OUT: the SDK's own speaker test tone on the selected speaker for 4 s, with the SDK's level
/// readout when it delivers one. If the SDK refuses, a 1 kHz tone of our own goes to the same device
/// by name, so the room still gets a sound. This check cannot hear the room: the result says what was
/// sent where, and the operator's ears say whether it arrived.
///
/// Every SDK delegate in this app has turned out silent at some point, so the sequence never WAITS on
/// one: it runs on a clock and reads whatever levels have arrived.
@MainActor
@Observable
final class AudioCheck {
    enum Kind: String { case mic, out }

    enum Phase: Equatable {
        case idle
        case running(Kind)
        case done(Kind, pass: Bool)
    }

    private(set) var phase: Phase = .idle
    /// The current step, for the line under the buttons: "SPEAK NOW · Insta360 Link 2 · 3 s".
    private(set) var step = ""
    /// The last result line; stays after the sequence so the operator can read it.
    private(set) var result: String?
    /// 0...1 for the meter, whichever check is running.
    private(set) var level: Float = 0
    /// macOS's microphone grant for this app: "granted", "denied", "not asked", "restricted". A denied
    /// grant is SILENCE with no error (measured: peak exactly 0.0 for the whole listen), so it is checked
    /// and asked for before the meter, and reported.
    private(set) var micPermission = AudioCheck.permissionName(AVCaptureDevice.authorizationStatus(for: .audio))
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var toneEngine: AVAudioEngine?

    var isRunning: Bool { if case .running = phase { return true } else { return false } }
    func isRunning(_ kind: Kind) -> Bool { phase == .running(kind) }

    /// Mic floor, on the meter's 0...1 scale (−50 dBFS ... 0): −40 dBFS. A mic that is plugged in and
    /// pointed at nobody sits under this; a voice at any sensible distance sits well over it.
    static let micFloor: Float = 0.2
    static let listenSeconds = 5
    static let playbackSeconds = 5
    static let toneSeconds = 4

    static func permissionName(_ st: AVAuthorizationStatus) -> String {
        switch st {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked"
        @unknown default: return "?"
        }
    }

    /// Ask macOS for the microphone if it has never been asked; true when the app may listen.
    private func ensureMicrophoneGrant() async -> Bool {
        let st = AVCaptureDevice.authorizationStatus(for: .audio)
        micPermission = Self.permissionName(st)
        switch st {
        case .authorized: return true
        case .notDetermined:
            step = "macOS is asking for the microphone…"
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            micPermission = Self.permissionName(AVCaptureDevice.authorizationStatus(for: .audio))
            return ok
        default: return false
        }
    }

    /// Meter level back to dBFS, the number the operator thinks in.
    static func dBFS(_ level: Float) -> Float { level * 50 - 50 }

    /// The mic verdict from the peak the meter saw and the loudest RAW sample. Pure, so it is tested.
    /// The raw peak is what tells a live interface with the gain down (−53 dBFS of noise floor, the
    /// MOTU M4 measured 2026-09-21) from a device handing over exact zeros (the OBSBOT with its
    /// camera closed): the meter's −50 dBFS floor reads both as 0.
    static func micVerdict(peak: Float, rawPeak: Float, device: String, speaker: String) -> (pass: Bool, text: String) {
        if peak >= micFloor {
            return (true, String(format: "MIC OK: %@ heard you, peak %.0f dBFS; playback sent to %@", device, dBFS(peak), speaker))
        }
        if peak > 0.02 {
            return (false, String(format: "MIC LOW: %@ peaked %.0f dBFS, under the −40 floor. Closer, louder, or check the gain", device, dBFS(peak)))
        }
        if rawPeak > 0 {
            let floor = 20 * log10(rawPeak)
            return (false, String(format: "MIC QUIET: %@ is live (noise floor %.0f dBFS) but heard nothing above −50 in %d s. Speak into it, or check the input gain and which input the mic is on", device, floor, listenSeconds))
        }
        return (false, "MIC SILENT: \(device) is sending digital silence. Wake or unmute the device, or pin another mic in SOUND")
    }

    // MARK: - Start / stop

    /// `sdkRecord: false` meters the mic WITHOUT the SDK's test recorder on the same device, to tell a
    /// silent device from a device the SDK has silenced for everyone else (diagnostic, ?record=0).
    func start(_ kind: Kind, sidecar: Sidecar, sdkRecord: Bool = true) {
        guard !isRunning else { return }
        phase = .running(kind)
        result = nil
        level = 0
        task = Task { [weak self, weak sidecar] in
            guard let self, let sidecar else { return }
            switch kind {
            case .mic: await self.runMic(sidecar, sdkRecord: sdkRecord)
            case .out: await self.runOut(sidecar)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        stopTone()
        if isRunning { phase = .idle; step = ""; result = "stopped"; level = 0 }
    }

    // MARK: - TEST MIC

    private func runMic(_ sidecar: Sidecar, sdkRecord: Bool) async {
        step = "starting the Zoom SDK…"
        guard let sdk = await sidecar.ensureSDK() else { return finish(.mic, pass: false, sidecar.lastError ?? "the SDK is not available") }
        guard sidecar.state != .inMeeting else { return finish(.mic, pass: false, "not during a meeting: the mic is live to the call") }
        let devices = sdk.audioDevices
        let mic = devices.mic ?? "system default", speaker = devices.speaker ?? "system default"

        guard await ensureMicrophoneGrant() else {
            return finish(.mic, pass: false, "MIC BLOCKED: macOS microphone access is \(micPermission) for ARC Zoom. System Settings > Privacy & Security > Microphone, then run again")
        }

        // A webcam's mic is digital silence until its video runs (the OBSBOT, measured). The engine's
        // keeper holds that camera whenever such a mic is pinned; make sure it is, and give the device a
        // moment to come up if it was just opened.
        let wasHeld = sdk.micKeeper.heldCamera
        sdk.updateMicKeeper()
        let woke = sdk.micKeeper.heldCamera
        if let woke, woke != wasHeld { step = "waking \(woke)…"; try? await Task.sleep(nanoseconds: 1_500_000_000) }

        // Our meter on the call's mic, and the SDK recording the same mic for the playback.
        let meterWasRunning = sidecar.micMeter.isRunning
        if !meterWasRunning { sidecar.micMeter.start(deviceNamed: devices.mic) }
        if let e = sidecar.micMeter.error { return finish(.mic, pass: false, e) }
        let recording = sdkRecord && sdk.audioTest(mic: "start", speaker: nil).contains { $0.contains("recording") }
        ShowLog.log("pre-flight mic: listening on \(mic), SDK recording \(sdkRecord ? (recording ? "on" : "REFUSED") : "off by request")")

        var peak: Float = 0
        let ticks = Self.listenSeconds * 10
        for i in 0..<ticks {
            if Task.isCancelled { break }
            level = sidecar.micMeter.level
            peak = max(peak, level)
            step = "SPEAK NOW · \(mic) · \(Self.listenSeconds - i / 10) s"
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if recording { _ = sdk.audioTest(mic: "stop", speaker: nil) }
        let buffers = sidecar.micMeter.buffersSeen, rawPeak = sidecar.micMeter.peakEver
        let perChannel = sidecar.micMeter.channelPeaks.enumerated()
            .map { i, p in "ch\(i + 1) " + (p > 0 ? String(format: "%.0f", 20 * log10(p)) : "-inf") }.joined(separator: " · ")
        if !meterWasRunning { sidecar.micMeter.stop() }
        level = 0
        if Task.isCancelled { return }
        ShowLog.log("pre-flight mic: \(buffers) buffers from \(mic), raw peak \(String(format: "%.4f", rawPeak)), meter peak \(String(format: "%.2f", peak)) · \(perChannel) dBFS")

        var verdict = Self.micVerdict(peak: peak, rawPeak: rawPeak, device: mic, speaker: speaker)
        if let woke, verdict.pass { verdict.text += " (\(woke) held open for it)" }
        if sidecar.micMeter.channelPeaks.count > 1 { verdict.text += " · \(perChannel) dBFS" }
        // No buffers at all is the tap, not the device. Exact zeros WITH the grant is the device itself
        // sending digital silence (the OBSBOT Meet 2 with its camera closed, measured 2026-09-21).
        if buffers == 0 { verdict = (false, "MIC DEAD: the tap on \(mic) delivered no audio at all in \(Self.listenSeconds) s. Is the device still connected?") }
        if verdict.pass, recording {
            let played = sdk.audioTest(mic: "play", speaker: nil).contains { $0.contains("playing") }
            if played {
                for i in 0..<(Self.playbackSeconds * 10) {
                    if Task.isCancelled { break }
                    step = "PLAYBACK on \(speaker) · you should hear yourself · \(Self.playbackSeconds - i / 10) s"
                    level = min(1, Float(sdk.micLevel) / 100)
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            } else {
                ShowLog.log("pre-flight mic: SDK playback refused")
            }
        }
        level = 0
        finish(.mic, pass: verdict.pass, verdict.text)
    }

    // MARK: - TEST AUDIO OUT

    private func runOut(_ sidecar: Sidecar) async {
        step = "starting the Zoom SDK…"
        guard let sdk = await sidecar.ensureSDK() else { return finish(.out, pass: false, sidecar.lastError ?? "the SDK is not available") }
        guard sidecar.state != .inMeeting else { return finish(.out, pass: false, "not during a meeting: the speaker carries the call") }
        let speaker = sdk.audioDevices.speaker ?? "system default"

        // OUR tone, always. The SDK's speaker test answered Success and produced nothing audible
        // (2026-09-21: "no tone"), and its level delegate never fired, so it proved nothing. A
        // pulsed 1 kHz from our own engine on the pinned device, by name, is the sound in the room.
        guard startTone(deviceNamed: sdk.audioDevices.speaker) else {
            return finish(.out, pass: false, "no tone: could not open \(speaker) for playback (\(toneDeviceNote))")
        }
        ShowLog.log("pre-flight out: 1 kHz pulses on \(toneDeviceNote)")
        for i in 0..<(Self.toneSeconds * 10) {
            if Task.isCancelled { break }
            // The meter follows the pulse so the eye and the ear agree on what is being sent.
            level = tonePulseOn ? 0.7 : 0.05
            step = "TONE on \(speaker) · listen in the room · \(Self.toneSeconds - i / 10) s"
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        stopTone()
        level = 0
        if Task.isCancelled { return }
        finish(.out, pass: true, "OUT: 1 kHz pulses ran \(Self.toneSeconds) s on \(toneDeviceNote). Heard in the room = pass")
    }

    private func finish(_ kind: Kind, pass: Bool, _ text: String) {
        step = ""
        result = text
        phase = .done(kind, pass: pass)
        level = 0
        ShowLog.log("pre-flight \(kind.rawValue): \(pass ? "PASS" : "FAIL") · \(text)")
    }

    // MARK: - Our own tone, for when the SDK's refuses

    /// Which device the tone engine actually opened, for the result line.
    @ObservationIgnored private var toneDeviceNote = "system default"
    /// Whether the pulse is in its ON half right now, read by the sequence for the meter.
    @ObservationIgnored private var toneStartedAt = Date()
    private var tonePulseOn: Bool { Int(Date().timeIntervalSince(toneStartedAt) * 2) % 2 == 0 }

    /// 1 kHz at −20 dBFS, 0.5 s on / 0.5 s off, on the named output device (the system default when nil
    /// or unknown). Pulsed so it cannot be mistaken for a hum that was already there.
    private func startTone(deviceNamed name: String?) -> Bool {
        let e = AVAudioEngine()
        toneDeviceNote = "system default"
        if let name, name != "Same as system", let id = MicMeter.outputDeviceID(named: name), let unit = e.outputNode.audioUnit {
            var dev = id
            let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if err == noErr { toneDeviceNote = name } else { ShowLog.log("pre-flight out: could not select \(name) (\(err)); the system default plays the tone") }
        }
        if toneDeviceNote == "system default", let real = MicMeter.systemDefaultDeviceName(input: false) { toneDeviceNote = "system default · \(real)" }
        let format = e.outputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return false }
        let rate = format.sampleRate
        var phase: Double = 0
        var frameIndex: Double = 0
        let amplitude: Float = 0.1  // −20 dBFS
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let step = 2 * Double.pi * 1000 / rate
            for frame in 0..<Int(frameCount) {
                // 0.5 s on, 0.5 s off, from the sample clock so it is exact.
                let on = Int(frameIndex / (rate / 2)) % 2 == 0
                let v = on ? Float(sin(phase)) * amplitude : 0
                phase += step
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                frameIndex += 1
                for b in buffers { b.mData?.assumingMemoryBound(to: Float.self)[frame] = v }
            }
            return noErr
        }
        e.attach(source)
        e.connect(source, to: e.mainMixerNode, format: format)
        do { try e.start() } catch { ShowLog.error("pre-flight out: tone engine \(error.localizedDescription)"); return false }
        toneEngine = e
        toneStartedAt = Date()
        return true
    }

    private func stopTone() {
        toneEngine?.stop()
        toneEngine = nil
    }
}

extension AudioCheck {
    var json: String {
        let phaseName: String, kind: String, pass: String
        switch phase {
        case .idle: phaseName = "idle"; kind = "null"; pass = "null"
        case .running(let k): phaseName = "running"; kind = "\"\(k.rawValue)\""; pass = "null"
        case .done(let k, let p): phaseName = "done"; kind = "\"\(k.rawValue)\""; pass = p ? "true" : "false"
        }
        return "{\"phase\":\"\(phaseName)\",\"kind\":\(kind),\"pass\":\(pass),\"micPermission\":\"\(micPermission)\",\"step\":\"\(jsonEscape(step))\","
            + "\"level\":\(jsonNumber(level)),\"result\":\(result.map { "\"\(jsonEscape($0))\"" } ?? "null")}"
    }
}
