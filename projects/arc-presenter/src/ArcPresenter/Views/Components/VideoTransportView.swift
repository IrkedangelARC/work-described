//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AVFoundation
import Accelerate

struct VideoTransportView: View {
    let player: AVPlayer
    let deck: Deck

    @State private var currentTime: TimeInterval = 0
    @State private var isPlaying: Bool = false
    @State private var pollTimer: Timer?
    @State private var playbackRate: Float = 1.0
    @State private var volume: Float = 1.0
    @State private var shuttleRate: Float = 0      // live shuttle rate (0 = parked)
    @State private var shuttleActive: Bool = false
    @State private var loopEnabled: Bool = false
    @State private var lastVolume: Float = 1.0
    @State private var isFading: Bool = false
    @State private var fadeTimer: Timer?
    @StateObject private var meter = AudioLevelMonitor()

    // Last audio player item the meter was attached to, so we reattach on change.
    @State private var meteredItem: AVPlayerItem?

    // Discrete shuttle detents, center outward: reverse … pause … forward.
    private let shuttleRates: [Float] = [-8, -4, -2, -1, -0.5, 0, 0.5, 1, 2, 4, 8]

    private var duration: TimeInterval { deck.videoDuration }

    var body: some View {
        VStack(spacing: 6) {
            // Header: VIDEO label + timecode
            HStack {
                Text("VIDEO")
                    .font(ARCTheme.mono(14, .bold))
                    .foregroundStyle(ARCTheme.textSecondary)

                if player.isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(ARCTheme.textSecondary)
                        .help("Audio muted in preview. Take deck live to hear audio.")
                }

                Spacer()

                Text(timecode(currentTime))
                    .font(ARCTheme.mono(14, .medium))
                    .foregroundStyle(ARCTheme.textPrimary)
                Text("/")
                    .foregroundStyle(ARCTheme.textSecondary)
                    .font(.system(size: 14))
                Text(timecode(duration))
                    .font(ARCTheme.mono(14, .medium))
                    .foregroundStyle(ARCTheme.textSecondary)

                Rectangle()
                    .fill(ARCTheme.surfaceLight)
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 2)

                VideoRemainingView(player: player, compact: true)
            }

            // Scrub bar with in/out markers
            scrubBar

            // Transport buttons
            transportButtons

            // Shuttle (variable-speed jog)
            shuttleControl

            Divider()
                .background(ARCTheme.surfaceLight)

            // In/Out controls
            inOutControls

            // Speed controls
            speedControls

            Divider()
                .background(ARCTheme.surfaceLight)

            // Audio: fader, fade in/out, live level meter
            audioSection
        }
        .onAppear {
            loopEnabled = deck.loopEnabled
            volume = player.volume
            startPolling()
            attachMeter()
        }
        .onDisappear {
            stopPolling()
            fadeTimer?.invalidate()
            meter.detach()
        }
    }

    /// Point the level meter at the current clip's audio, reattaching if the
    /// live item changed underneath us (new slide, new player item).
    private func attachMeter() {
        let item = player.currentItem
        if item !== meteredItem {
            meteredItem = item
            meter.player = player; meter.attach(to: item)
        }
    }

    // MARK: - Scrub Bar

    private var scrubBar: some View {
        GeometryReader { geo in
            let progress = duration > 0 ? currentTime / duration : 0
            let w = geo.size.width

            ZStack(alignment: .leading) {
                // Track
                Rectangle()
                    .fill(ARCTheme.surfaceLight)
                    .frame(height: 8)
                    .cornerRadius(4)

                // In/Out region highlight
                if let inPt = deck.inPoint, let outPt = deck.outPoint, duration > 0 {
                    let inFrac = inPt / duration
                    let outFrac = outPt / duration
                    Rectangle()
                        .fill(ARCTheme.accent.opacity(0.2))
                        .frame(width: w * (outFrac - inFrac), height: 8)
                        .offset(x: w * inFrac)
                        .cornerRadius(4)
                }

                // Progress fill
                Rectangle()
                    .fill(ARCTheme.accent)
                    .frame(width: w * progress, height: 8)
                    .cornerRadius(4)

                // In marker
                if let inPt = deck.inPoint, duration > 0 {
                    Rectangle()
                        .fill(ARCTheme.readyGreen)
                        .frame(width: 2, height: 14)
                        .offset(x: w * (inPt / duration) - 1)
                }

                // Out marker
                if let outPt = deck.outPoint, duration > 0 {
                    Rectangle()
                        .fill(ARCTheme.liveRed)
                        .frame(width: 2, height: 14)
                        .offset(x: w * (outPt / duration) - 1)
                }
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, value.location.x / w))
                        let target = fraction * duration
                        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                    toleranceBefore: .zero, toleranceAfter: .zero)
                    }
            )
        }
        .frame(height: 14)
    }

    // MARK: - Transport Buttons

    private var transportButtons: some View {
        HStack(spacing: 8) {
            transportBtn("backward.end.fill", tip: "Go to IN point or start") {
                let target = deck.inPoint ?? 0
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            }

            transportBtn("chevron.left.2", tip: "Step back one frame") {
                player.pause()
                player.currentItem?.step(byCount: -1)
            }

            transportBtn("gobackward.5", tip: "Skip back 5 seconds") {
                let minTime = deck.inPoint ?? 0
                let target = max(minTime, currentTime - 5)
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            }

            Button {
                if isPlaying {
                    player.pause()
                } else {
                    if let outPt = deck.outPoint, currentTime >= outPt - 0.1 {
                        let startAt = deck.inPoint ?? 0
                        player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
                    } else if currentTime >= duration - 0.5 {
                        let startAt = deck.inPoint ?? 0
                        player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
                    }
                    player.rate = playbackRate
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 40, height: 32)
                    .foregroundStyle(isPlaying ? ARCTheme.liveRed : ARCTheme.readyGreen)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Pause playback" : "Play video at selected speed")

            transportBtn("goforward.5", tip: "Skip forward 5 seconds") {
                let maxTime = deck.outPoint ?? duration
                let target = min(maxTime, currentTime + 5)
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            }

            transportBtn("chevron.right.2", tip: "Step forward one frame") {
                player.pause()
                player.currentItem?.step(byCount: 1)
            }

            transportBtn("forward.end.fill", tip: "Go to OUT point or end") {
                let target = deck.outPoint ?? duration
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            }

            Rectangle()
                .fill(ARCTheme.surfaceLight)
                .frame(width: 1, height: 20)
                .padding(.horizontal, 2)

            // Loop toggle: repeat IN→OUT (or whole clip) while live
            Button {
                loopEnabled.toggle()
                deck.loopEnabled = loopEnabled
            } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 14, weight: loopEnabled ? .heavy : .regular))
                    .frame(width: 32, height: 32)
                    .background(loopEnabled ? ARCTheme.accent.opacity(0.2) : Color.clear)
                    .foregroundStyle(loopEnabled ? ARCTheme.accent : ARCTheme.textSecondary)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help(loopEnabled ? "Looping: clip repeats at OUT/end" : "Loop this clip (walkout/hold)")

            Spacer()
        }
    }

    // MARK: - Shuttle (variable-speed jog)

    private var shuttleControl: some View {
        VStack(spacing: 3) {
            HStack {
                Text("SHUTTLE")
                    .font(ARCTheme.mono(11, .bold))
                    .foregroundStyle(ARCTheme.textSecondary)
                Spacer()
                Text(shuttleActive ? shuttleLabel(shuttleRate) : "PARKED")
                    .font(ARCTheme.mono(12, .heavy))
                    .foregroundStyle(shuttleRate == 0 ? ARCTheme.textSecondary
                        : (shuttleRate < 0 ? ARCTheme.liveRed : ARCTheme.readyGreen))
            }

            GeometryReader { geo in
                let w = geo.size.width
                let center = w / 2
                // Thumb offset from center, proportional to the active detent.
                let maxIdx = Float(shuttleRates.count / 2)
                let detentIdx = Float(shuttleRates.firstIndex(of: shuttleRate) ?? shuttleRates.count / 2) - maxIdx
                let thumbX = center + CGFloat(detentIdx / maxIdx) * (center - 12)

                ZStack(alignment: .leading) {
                    // Track + tick marks
                    Rectangle().fill(ARCTheme.surfaceLight).frame(height: 10).cornerRadius(5)
                    ForEach(0..<shuttleRates.count, id: \.self) { i in
                        let x = CGFloat(i) / CGFloat(shuttleRates.count - 1) * w
                        Rectangle()
                            .fill(shuttleRates[i] == 0 ? ARCTheme.textSecondary : ARCTheme.surfaceLight.opacity(0.8))
                            .frame(width: shuttleRates[i] == 0 ? 2 : 1, height: shuttleRates[i] == 0 ? 16 : 10)
                            .offset(x: x - 1)
                    }
                    // Filled region from center to thumb
                    Rectangle()
                        .fill((shuttleRate < 0 ? ARCTheme.liveRed : ARCTheme.readyGreen).opacity(0.25))
                        .frame(width: abs(thumbX - center), height: 10)
                        .offset(x: min(center, thumbX))
                        .cornerRadius(5)
                    // Thumb
                    Circle()
                        .fill(shuttleActive ? (shuttleRate < 0 ? ARCTheme.liveRed : (shuttleRate == 0 ? ARCTheme.textPrimary : ARCTheme.readyGreen)) : ARCTheme.textPrimary)
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(ARCTheme.background, lineWidth: 2))
                        .offset(x: thumbX - 10)
                        .shadow(radius: shuttleActive ? 3 : 0)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            shuttleActive = true
                            // Map x position to nearest detent.
                            let frac = max(0, min(1, value.location.x / w))
                            let idx = Int((frac * CGFloat(shuttleRates.count - 1)).rounded())
                            let rate = shuttleRates[idx]
                            if rate != shuttleRate { applyShuttle(rate) }
                        }
                        .onEnded { _ in
                            // Spring back to center; park (pause) on release.
                            applyShuttle(0)
                            player.pause()
                            shuttleActive = false
                        }
                )
            }
            .frame(height: 22)
        }
    }

    private func applyShuttle(_ rate: Float) {
        shuttleRate = rate
        guard let item = player.currentItem else { return }
        if rate == 0 { player.rate = 0; return }
        // Honor what the asset can actually do; clamp unsupported rates.
        if rate < 0 && !item.canPlayReverse { return }
        if rate > 2 && !item.canPlayFastForward { player.rate = 2; return }
        if rate < -2 && !item.canPlayFastReverse { player.rate = -2; return }
        if abs(rate) < 1 && !item.canPlaySlowForward && rate > 0 { player.rate = 1; return }
        player.rate = rate
    }

    private func shuttleLabel(_ rate: Float) -> String {
        if rate == 0 { return "STOP" }
        let dir = rate < 0 ? "◀ " : "▶ "
        let mag = abs(rate)
        let num = mag == Float(Int(mag)) ? "\(Int(mag))x" : String(format: "%.1fx", mag)
        return dir + num
    }

    private func transportBtn(_ icon: String, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 32, height: 32)
                .foregroundStyle(ARCTheme.textPrimary)
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    // MARK: - In/Out Controls

    private var inOutControls: some View {
        HStack(spacing: 8) {
            // IN
            HStack(spacing: 4) {
                Text("IN")
                    .font(ARCTheme.mono(12, .heavy))
                    .foregroundStyle(ARCTheme.readyGreen)
                    .frame(width: 22)

                if let inPt = deck.inPoint {
                    Text(timecode(inPt))
                        .font(ARCTheme.mono(12, .medium))
                        .foregroundStyle(ARCTheme.textPrimary)
                } else {
                    Text("--:--")
                        .font(ARCTheme.mono(12, .medium))
                        .foregroundStyle(ARCTheme.textSecondary)
                }

                Button("SET") {
                    deck.setInPoint(currentTime)
                }
                .font(ARCTheme.mono(11, .bold))
                .buttonStyle(.plain)
                .foregroundStyle(ARCTheme.accent)
                .help("Set IN point at current position. Playback starts here.")
            }

            Rectangle()
                .fill(ARCTheme.surfaceLight)
                .frame(width: 1, height: 18)

            // OUT
            HStack(spacing: 4) {
                Text("OUT")
                    .font(ARCTheme.mono(12, .heavy))
                    .foregroundStyle(ARCTheme.liveRed)
                    .frame(width: 30)

                if let outPt = deck.outPoint {
                    Text(timecode(outPt))
                        .font(ARCTheme.mono(12, .medium))
                        .foregroundStyle(ARCTheme.textPrimary)
                } else {
                    Text("--:--")
                        .font(ARCTheme.mono(12, .medium))
                        .foregroundStyle(ARCTheme.textSecondary)
                }

                Button("SET") {
                    deck.setOutPoint(currentTime)
                }
                .font(ARCTheme.mono(11, .bold))
                .buttonStyle(.plain)
                .foregroundStyle(ARCTheme.accent)
                .help("Set OUT point at current position. Playback pauses here.")
            }

            Rectangle()
                .fill(ARCTheme.surfaceLight)
                .frame(width: 1, height: 18)

            // Clear
            Button("CLR") {
                deck.clearInOutPoints()
            }
            .font(ARCTheme.mono(11, .bold))
            .buttonStyle(.plain)
            .foregroundStyle(ARCTheme.textSecondary)
            .help("Clear IN and OUT points")

            Spacer()
        }
    }

    // MARK: - Speed Controls

    private var speedControls: some View {
        HStack(spacing: 6) {
            Text("SPEED")
                .font(ARCTheme.mono(11, .bold))
                .foregroundStyle(ARCTheme.textSecondary)

            ForEach([Float(0.25), 0.5, 1.0, 1.5, 2.0], id: \.self) { rate in
                Button {
                    playbackRate = rate
                    if isPlaying {
                        player.rate = rate
                    }
                } label: {
                    Text(rateLabel(rate))
                        .font(.system(size: 12, weight: playbackRate == rate ? .heavy : .medium, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(playbackRate == rate ? ARCTheme.accent.opacity(0.2) : Color.clear)
                        .foregroundStyle(playbackRate == rate ? ARCTheme.accent : ARCTheme.textPrimary)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    // MARK: - Audio (level fader, fades, live meter)

    private var audioSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("AUDIO")
                    .font(ARCTheme.mono(11, .bold))
                    .foregroundStyle(ARCTheme.textSecondary)

                // Mute / unmute (remembers last level)
                Button {
                    if volume > 0 {
                        lastVolume = volume
                        setVolume(0)
                    } else {
                        setVolume(lastVolume > 0 ? lastVolume : 1.0)
                    }
                } label: {
                    Image(systemName: volume == 0 ? "speaker.slash.fill" : (volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                        .font(.system(size: 13))
                        .foregroundStyle(volume == 0 ? ARCTheme.liveRed : ARCTheme.textPrimary)
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .help(volume == 0 ? "Unmute" : "Mute")

                // Level fader
                Slider(value: Binding(
                    get: { volume },
                    set: { setVolume($0) }
                ), in: 0...1)
                .tint(ARCTheme.accent)
                .disabled(isFading)
                .help("Program level (audible when deck is live)")

                // dB readout
                Text(dbLabel(volume))
                    .font(ARCTheme.mono(12, .heavy))
                    .foregroundStyle(volume == 0 ? ARCTheme.liveRed : ARCTheme.textPrimary)
                    .frame(width: 52, alignment: .trailing)
                    .monospacedDigit()

                // Fade in / out over ~1.5s
                Button("FADE IN") { fade(to: lastVolume > 0 ? lastVolume : 1.0) }
                    .font(ARCTheme.mono(11, .bold))
                    .buttonStyle(.plain)
                    .foregroundStyle(ARCTheme.readyGreen)
                    .help("Ramp level up over 1.5s")
                Button("FADE OUT") {
                    if volume > 0 { lastVolume = volume }
                    fade(to: 0)
                }
                    .font(ARCTheme.mono(11, .bold))
                    .buttonStyle(.plain)
                    .foregroundStyle(ARCTheme.liveRed)
                    .help("Ramp level down to silence over 1.5s")
            }

            // Live stereo level meter (peak, with ballistic decay)
            AudioMeterView(monitor: meter)
        }
    }

    private func setVolume(_ v: Float) {
        let clamped = max(0, min(1, v))
        volume = clamped
        player.volume = clamped
    }

    /// Smoothly ramp program level to a target over ~1.5s.
    private func fade(to target: Float) {
        fadeTimer?.invalidate()
        let start = volume
        let steps = 45
        let dt = 1.5 / Double(steps)
        var i = 0
        isFading = true
        fadeTimer = Timer.commonModes(withTimeInterval: dt, repeats: true) { t in
            i += 1
            let p = Float(i) / Float(steps)
            setVolume(start + (target - start) * p)
            if i >= steps {
                setVolume(target)
                isFading = false
                t.invalidate()
            }
        }
    }

    /// Map linear player volume (0...1) to a dBFS-style readout.
    private func dbLabel(_ v: Float) -> String {
        if v <= 0.0001 { return "−∞" }
        let db = 20 * log10(v)
        if db >= -0.05 { return "0.0 dB" }
        return String(format: "%.1f dB", db)
    }

    // MARK: - Helpers

    private func rateLabel(_ rate: Float) -> String {
        if rate == Float(Int(rate)) {
            return "\(Int(rate))x"
        }
        return String(format: "%.1fx", rate).replacingOccurrences(of: ".0x", with: "x")
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.commonModes(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                let time = CMTimeGetSeconds(player.currentTime())
                if time.isFinite { currentTime = time }
                isPlaying = player.timeControlStatus == .playing

                // Loop: when playing past OUT (or near end), jump back to IN.
                if loopEnabled && isPlaying {
                    let loopOut = deck.outPoint ?? duration
                    if duration > 0 && time >= loopOut - 0.05 {
                        let loopIn = deck.inPoint ?? 0
                        player.seek(to: CMTime(seconds: loopIn, preferredTimescale: 600),
                                    toleranceBefore: .zero, toleranceAfter: .zero)
                        if player.rate == 0 { player.rate = playbackRate }
                    }
                }

                // Keep the meter pointed at the live item if it swapped.
                attachMeter()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func timecode(_ time: TimeInterval) -> String {
        let total = Int(time)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let frames = Int((time - Double(total)) * 30)
        if hours > 0 {
            return String(format: "%d:%02d:%02d:%02d", hours, minutes, seconds, frames)
        }
        return String(format: "%d:%02d:%02d", minutes, seconds, frames)
    }
}

// MARK: - Audio level metering (MTAudioProcessingTap)

/// Thread-safe scratch for peak levels: written by the realtime audio callback,
/// read on the main thread by the meter's display timer.
final class LevelStore {
    private var lock = os_unfair_lock_s()
    private var l: Float = 0
    private var r: Float = 0

    func write(l newL: Float, r newR: Float) {
        os_unfair_lock_lock(&lock)
        l = newL; r = newR
        os_unfair_lock_unlock(&lock)
    }

    /// Read-and-reset so a stalled audio thread decays to silence.
    func read() -> (Float, Float) {
        os_unfair_lock_lock(&lock)
        let out = (l, r)
        l = 0; r = 0
        os_unfair_lock_unlock(&lock)
        return out
    }
}

/// Taps the live clip's audio and publishes peak levels (0...1) per channel.
/// Attaching sets an audioMix on the item; failure is non-fatal (no meter,
/// playback untouched).
@MainActor
final class AudioLevelMonitor: ObservableObject {
    @Published var peakL: Float = 0
    @Published var peakR: Float = 0
    @Published var hasAudio: Bool = false

    private var item: AVPlayerItem?
    private let store = LevelStore()
    /// The tap sits in the item's audio mix, UPSTREAM of AVPlayer.volume,
    /// so the raw levels never moved with the fader (2026-09-12).
    /// The meter shows post-fader: raw peak times the player's volume.
    weak var player: AVPlayer?
    private var displayTimer: Timer?

    func attach(to newItem: AVPlayerItem?) {
        detach()
        guard let newItem else { return }
        item = newItem
        startDisplay()
        Task { await install(on: newItem) }
    }

    func detach() {
        displayTimer?.invalidate(); displayTimer = nil
        item?.audioMix = nil
        item = nil
        peakL = 0; peakR = 0; hasAudio = false
    }

    private func startDisplay() {
        displayTimer?.invalidate()
        displayTimer = Timer.commonModes(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let (l, r) = self.store.read()
            let gain = self.player?.volume ?? 1
            // Fast attack, slow release for a readable meter.
            self.peakL = max(l * gain, self.peakL * 0.82)
            self.peakR = max(r * gain, self.peakR * 0.82)
        }
    }

    private func install(on target: AVPlayerItem) async {
        let asset = target.asset
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard let track = tracks.first else { return }
        guard target === item else { return }  // item changed while loading

        // Hand the store to the tap with a +1 retain; tapFinalize releases it.
        let storePtr = UnsafeMutableRawPointer(Unmanaged.passRetained(store).toOpaque())
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: storePtr,
            init: tapInit,
            finalize: tapFinalize,
            prepare: nil,
            unprepare: nil,
            process: tapProcess)

        var tap: MTAudioProcessingTap?
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                             kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard err == noErr, let tap else {
            // Tap never took ownership: balance the retain above exactly once.
            Unmanaged<LevelStore>.fromOpaque(storePtr).release()
            return
        }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        target.audioMix = mix
        hasAudio = true
    }
}

// C-style tap callbacks (no captured context; state travels via tapStorage).

private func tapInit(tap: MTAudioProcessingTap,
                     clientInfo: UnsafeMutableRawPointer?,
                     tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<LevelStore>.fromOpaque(storage).release()
}

private func tapProcess(tap: MTAudioProcessingTap,
                        numberFrames: CMItemCount,
                        flags: MTAudioProcessingTapFlags,
                        bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
                        numberFramesOut: UnsafeMutablePointer<CMItemCount>,
                        flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                    flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }

    let storage = MTAudioProcessingTapGetStorage(tap)
    let store = Unmanaged<LevelStore>.fromOpaque(storage).takeUnretainedValue()

    let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    var channelPeaks: [Float] = []
    for buffer in abl {
        guard let mData = buffer.mData else { continue }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { continue }
        let samples = mData.assumingMemoryBound(to: Float.self)
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        channelPeaks.append(min(peak, 1.0))
    }

    let l = channelPeaks.first ?? 0
    let r = channelPeaks.count > 1 ? channelPeaks[1] : l
    store.write(l: l, r: r)
}

// MARK: - Meter view

/// Two horizontal peak bars (L/R) with green/amber/red zones, driven by the tap.
struct AudioMeterView: View {
    @ObservedObject var monitor: AudioLevelMonitor

    var body: some View {
        AudioMeterBars(peakL: monitor.peakL, peakR: monitor.peakR)
    }
}

/// The bars alone, for any source of peaks (clip tap, MUSIC process tap).
struct AudioMeterBars: View {
    let peakL: Float
    let peakR: Float
    /// Two 4 pt bars with no L/R labels, to sit under a fader (MUSIC channels).
    var compact: Bool = false
    /// One colour for the whole scale instead of the green / amber / red zones: the grey PRE-FADE
    /// meter under a MUSIC fader (2026-09-19), which shows the source, not what the room gets.
    var mono: Color? = nil

    var body: some View {
        VStack(spacing: compact ? 1 : 3) {
            meterRow(label: "L", level: peakL)
            meterRow(label: "R", level: peakR)
        }
    }

    private func meterRow(label: String, level: Float) -> some View {
        let barH: CGFloat = compact ? 4 : 8
        return HStack(spacing: 6) {
            if !compact {
                Text(label)
                    .font(ARCTheme.mono(9, .heavy))
                    .foregroundStyle(ARCTheme.textSecondary)
                    .frame(width: 10)
            }

            GeometryReader { geo in
                let w = geo.size.width
                // Normalize peak to a dB scale (−48..0) so quiet audio is visible.
                let db = level <= 0.0001 ? -48 : max(-48, 20 * log10(level))
                let frac = CGFloat((db + 48) / 48)
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(ARCTheme.surfaceLight)
                        .frame(height: barH)
                        .cornerRadius(2)
                    // Fixed zones on the scale, lit only when the level reaches
                    // them: green to -12 dBFS, yellow to -3, red above (clip
                    // danger). A gradient stretched over the current width
                    // painted red at any level (2026-09-12).
                    let x = { (d: Double) in w * CGFloat((d + 48) / 48) }
                    let lvl = x(Double(db))
                    HStack(spacing: 0) {
                        if let mono {
                            Rectangle().fill(mono).frame(width: max(0, lvl))
                        } else {
                            Rectangle().fill(ARCTheme.readyGreen).frame(width: max(0, min(lvl, x(-12))))
                            if db > -12 { Rectangle().fill(ARCTheme.warn).frame(width: max(0, min(lvl, x(-3)) - x(-12))) }
                            if db > -3 { Rectangle().fill(ARCTheme.liveRed).frame(width: max(0, lvl - x(-3))) }
                        }
                    }
                    .frame(height: barH)
                    .cornerRadius(2)
                    // Zone ticks at -12 and -3 dBFS
                    ForEach([-12.0, -3.0], id: \.self) { d in
                        Rectangle()
                            .fill(ARCTheme.textSecondary.opacity(0.6))
                            .frame(width: 1, height: barH + 2)
                            .offset(x: w * CGFloat((d + 48) / 48))
                    }
                }
                .frame(height: barH + 2)
            }
            .frame(height: barH + 2)
        }
    }
}
