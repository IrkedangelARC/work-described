//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Synchronization

public enum GeneratorSignal: String, Codable, CaseIterable, Sendable {
    case pink = "PINK", white = "WHITE", sine = "SINE", sweep = "SWEEP"
}

public struct GeneratorSettings: Codable, Equatable, Sendable {
    public var signal = GeneratorSignal.pink
    /// dBFS RMS, the convention of every level in the app (a full-scale sine is -3.01).
    public var levelDBFS = -30.0
    public var frequency = 1000.0
    /// The sweep runs 20 Hz to 20 kHz on a log scale in this many seconds, then starts over.
    public var sweepSeconds = 5.0
    /// Loudest level that can be asked for: noise needs room for its peaks.
    public static func ceiling(_ signal: GeneratorSignal) -> Double { signal == .pink || signal == .white ? -12 : -3.01 }
    public static let floorDBFS = -80.0

    public init() {}

    public var clampedLevel: Double { min(max(levelDBFS, Self.floorDBFS), Self.ceiling(signal)) }
}

/// The test signal source. `render` is called from the audio thread: it allocates nothing and
/// takes no lock. Starts, stops and level changes ramp over 20 ms so nothing clicks into a PA.
public final class SignalGenerator: @unchecked Sendable {
    public let sampleRate: Double
    /// Set from any thread, read by the audio thread: each field is its own atomic, so the
    /// audio thread never waits and never reads half a change.
    public var settings: GeneratorSettings {
        get {
            var s = GeneratorSettings()
            s.signal = GeneratorSignal.allCases[min(max(aSignal.load(ordering: .relaxed), 0), GeneratorSignal.allCases.count - 1)]
            s.levelDBFS = Double(bitPattern: aLevel.load(ordering: .relaxed))
            s.frequency = Double(bitPattern: aFrequency.load(ordering: .relaxed))
            s.sweepSeconds = Double(bitPattern: aSweep.load(ordering: .relaxed))
            return s
        }
        set {
            aSignal.store(GeneratorSignal.allCases.firstIndex(of: newValue.signal) ?? 0, ordering: .relaxed)
            aLevel.store(newValue.levelDBFS.bitPattern, ordering: .relaxed)
            aFrequency.store(newValue.frequency.bitPattern, ordering: .relaxed)
            aSweep.store(newValue.sweepSeconds.bitPattern, ordering: .relaxed)
        }
    }
    public var running: Bool {
        get { aRunning.load(ordering: .relaxed) }
        set { aRunning.store(newValue, ordering: .relaxed) }
    }
    private let aSignal = Atomic<Int>(0)
    private let aLevel = Atomic<UInt64>(GeneratorSettings().levelDBFS.bitPattern)
    private let aFrequency = Atomic<UInt64>(GeneratorSettings().frequency.bitPattern)
    private let aSweep = Atomic<UInt64>(GeneratorSettings().sweepSeconds.bitPattern)
    private let aRunning = Atomic<Bool>(false)

    private var gain = 0.0
    private var rampTarget = 0.0
    private var rampSpan = 0.0
    private let rampStep: Double
    private var phase = 0.0
    private var sweepPosition = 0.0
    private var rng: UInt64 = 0x9E3779B97F4A7C15
    private var b = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    /// RMS of the pink filter's output for unit white noise in, measured once.
    private var pinkGain = 1.0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        rampStep = 1 / (0.020 * sampleRate)
        var sum = 0.0
        let n = 1 << 17
        for _ in 0..<n { let y = pinkSample(); sum += y * y }
        let rms = sqrt(sum / Double(n))
        pinkGain = 1 / rms
        b = (0, 0, 0, 0, 0, 0, 0)
    }

    /// True while anything is still coming out (running, or fading out).
    public var audible: Bool { running || gain > 0 }

    @inline(__always) private func uniform() -> Double {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Double(rng >> 11) / Double(1 << 53)
    }

    /// Unit variance white noise (sum of twelve uniforms: bounded, so its peaks are too).
    @inline(__always) private func whiteSample() -> Double {
        var s = -6.0
        for _ in 0..<12 { s += uniform() }
        return s
    }

    @inline(__always) private func pinkSample() -> Double {
        let x = whiteSample()
        b.0 = 0.99886 * b.0 + x * 0.0555179
        b.1 = 0.99332 * b.1 + x * 0.0750759
        b.2 = 0.96900 * b.2 + x * 0.1538520
        b.3 = 0.86650 * b.3 + x * 0.3104856
        b.4 = 0.55000 * b.4 + x * 0.5329522
        b.5 = -0.7616 * b.5 - x * 0.0168980
        let y = b.0 + b.1 + b.2 + b.3 + b.4 + b.5 + b.6 + x * 0.5362
        b.6 = x * 0.115926
        return y * pinkGain
    }

    public func render(into out: UnsafeMutablePointer<Float>, count: Int) {
        let s = settings
        let target = running ? pow(10, s.clampedLevel / 20) : 0
        let sqrt2 = 2.0.squareRoot()
        // A straight 20 ms ramp from wherever the gain is to wherever it is going.
        if target != rampTarget { rampTarget = target; rampSpan = abs(target - gain) }
        let step = rampSpan * rampStep
        for i in 0..<count {
            if gain < target { gain = min(gain + step, target) }
            else if gain > target { gain = max(gain - step, target) }
            guard gain > 0 else { out[i] = 0; continue }
            var v: Double
            switch s.signal {
            case .white: v = whiteSample()
            case .pink: v = pinkSample()
            case .sine:
                v = sqrt2 * sin(phase)
                phase += 2 * Double.pi * min(max(s.frequency, 10), 0.45 * sampleRate) / sampleRate
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            case .sweep:
                let f = 20 * pow(1000, sweepPosition)
                v = sqrt2 * sin(phase)
                phase += 2 * Double.pi * f / sampleRate
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                sweepPosition += 1 / (max(s.sweepSeconds, 0.5) * sampleRate)
                if sweepPosition >= 1 { sweepPosition = 0 }
            }
            out[i] = Float(min(max(v * gain, -1), 1))
        }
    }
}
