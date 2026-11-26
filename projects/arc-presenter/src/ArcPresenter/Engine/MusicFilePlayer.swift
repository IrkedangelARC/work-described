//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import os

/// One sound cue on a MUSIC channel: an audio file on disk (mp3, wav, aiff,
/// m4a, caf, flac). Bells, chimes, stingers, or a whole walk-in track.
struct MusicCue: Identifiable, Hashable, Sendable {
    let url: URL
    /// Seconds, read from the file when it was added (0 if unreadable).
    let duration: Double
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }

    static let extensions: Set<String> = ["mp3", "wav", "wave", "aiff", "aif", "m4a", "aac", "caf", "flac", "mp4", "m4b"]

    /// A file or a folder (one level, sorted by name) → cues. Unreadable
    /// files are skipped, never thrown: a bad chime must not lose the bank.
    static func load(_ url: URL) -> [MusicCue] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        let files: [URL]
        if isDir.boolValue {
            let listed = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            files = listed.filter { extensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } else {
            files = [url]
        }
        return files.compactMap { f in
            guard let file = try? AVAudioFile(forReading: f) else { return nil }
            let secs = file.processingFormat.sampleRate > 0 ? Double(file.length) / file.processingFormat.sampleRate : 0
            return MusicCue(url: f, duration: secs)
        }
    }
}

/// Plays a channel's sound cues through the chosen output device, at the
/// channel's gain, with a post-fader peak meter. One AVAudioEngine per
/// channel: player node → main mixer (the gain stage) → output unit pinned
/// to the device. Not @MainActor: created and driven from the channel,
/// metered on the render thread through one short lock.
final class MusicFilePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let peaks = OSAllocatedUnfairLock(initialState: (l: Float(0), r: Float(0)))
    /// The player node's own output, before the mixer's volume: signal present whatever the fader says.
    private let inputPeaks = OSAllocatedUnfairLock(initialState: (l: Float(0), r: Float(0)))
    private var generation = 0
    private var connectedFormat: AVAudioFormat?
    private(set) var lastError: String?

    /// `outputDeviceID` nil = the system default output.
    init(outputDeviceID: AudioObjectID?) {
        engine.attach(node)
        if let dev = outputDeviceID, let au = engine.outputNode.audioUnit {
            var id = dev
            let err = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if err != noErr { lastError = "output device \(dev) refused (\(err))" }
        }
        let mixer = engine.mainMixerNode
        // Connect once with a default format so the graph is valid before the
        // first cue; play() reconnects for the file's own format.
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.connect(node, to: mixer, format: fmt)
        connectedFormat = fmt
        mixer.outputVolume = 0
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [peaks] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            let ch = Int(buffer.format.channelCount)
            var l: Float = 0, r: Float = 0
            let lp = data[0]
            for i in 0..<n { l = max(l, abs(lp[i])) }
            if ch > 1 { let rp = data[1]; for i in 0..<n { r = max(r, abs(rp[i])) } } else { r = l }
            let lf = min(l, 1), rf = min(r, 1)
            peaks.withLock { s in s.l = max(s.l, lf); s.r = max(s.r, rf) }
        }
        installNodeTap()
        engine.prepare()
    }

    /// The pre-fader tap on the player node. Re-installed after every reconnect: a tap installed
    /// for one format does not follow the node to a file's different one (review, 2026-09-19).
    private func installNodeTap() {
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { [inputPeaks] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            let ch = Int(buffer.format.channelCount)
            var l: Float = 0, r: Float = 0
            let lp = data[0]
            for i in 0..<n { l = max(l, abs(lp[i])) }
            if ch > 1 { let rp = data[1]; for i in 0..<n { r = max(r, abs(rp[i])) } } else { r = l }
            let lf = min(l, 1), rf = min(r, 1)
            inputPeaks.withLock { s in s.l = max(s.l, lf); s.r = max(s.r, rf) }
        }
    }

    var isPlaying: Bool { node.isPlaying }

    /// Pre-fader, read-and-reset.
    func readInputPeaks() -> (Float, Float) {
        inputPeaks.withLock { s in let out = (s.l, s.r); s.l = 0; s.r = 0; return out }
    }

    func setGain(_ g: Float) {
        engine.mainMixerNode.outputVolume = max(0, min(1, g))
    }

    /// Read-and-reset, like TapState, so a silent player decays the meter.
    func readPeaks() -> (Float, Float) {
        peaks.withLock { s in let out = (s.l, s.r); s.l = 0; s.r = 0; return out }
    }

    /// Start `cue` from the top (a cue already playing restarts). `onEnd`
    /// fires once, off the main thread, when the data has played out; the
    /// generation tells the caller whether it is still the current play.
    /// Where the current file is, in frames, for a second player joining it (PFL engaged mid-cue).
    var currentFrame: AVAudioFramePosition {
        guard let nodeTime = node.lastRenderTime, let t = node.playerTime(forNodeTime: nodeTime) else { return 0 }
        return max(0, t.sampleTime)
    }

    @discardableResult
    func play(_ cue: MusicCue, from frame: AVAudioFramePosition = 0, onEnd: @escaping @Sendable (Int) -> Void) -> Int? {
        do {
            let file = try AVAudioFile(forReading: cue.url)
            node.stop()
            if connectedFormat != file.processingFormat {
                engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
                connectedFormat = file.processingFormat
                installNodeTap()
            }
            if !engine.isRunning { try engine.start() }
            generation += 1
            let gen = generation
            if frame > 0, frame < file.length {
                node.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(file.length - frame), at: nil, completionCallbackType: .dataPlayedBack) { _ in onEnd(gen) }
            } else {
                node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in onEnd(gen) }
            }
            node.play()
            lastError = nil
            return gen
        } catch {
            lastError = "\(cue.name): \(error.localizedDescription)"
            return nil
        }
    }

    func stop() {
        generation += 1
        node.stop()
    }

    func close() {
        node.stop()
        node.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
    }

    deinit { close() }
}
