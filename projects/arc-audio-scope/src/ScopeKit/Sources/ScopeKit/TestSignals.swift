//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Known signals. The golden tests assert numbers against them, and the app can play them
/// through the analyser in place of the microphone (TEST SIGNAL source) so a screen can be
/// checked without a room.
public enum TestSignals {
    /// Deterministic white noise, unit RMS.
    public static func white(_ count: Int, seed: UInt64 = 1) -> [Float] {
        var s = seed &* 2862933555777941757 &+ 3037000493
        func u() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 53)
        }
        return (0..<count).map { _ in Float(sqrt(-2 * log(max(u(), 1e-12))) * cos(2 * Double.pi * u())) }
    }

    /// Pink noise, unit RMS: white noise through Kellet's refined filter (a cascade of first-order
    /// shelves), within a few tenths of a dB of 3 dB per octave from 30 Hz to 15 kHz at 48 kHz.
    public static func pink(_ count: Int, seed: UInt64 = 1) -> [Float] {
        let w = white(count, seed: seed)
        var b = [Double](repeating: 0, count: 7)
        var out = [Float](repeating: 0, count: count)
        var sumSq = 0.0
        for i in 0..<count {
            let x = Double(w[i])
            b[0] = 0.99886 * b[0] + x * 0.0555179
            b[1] = 0.99332 * b[1] + x * 0.0750759
            b[2] = 0.96900 * b[2] + x * 0.1538520
            b[3] = 0.86650 * b[3] + x * 0.3104856
            b[4] = 0.55000 * b[4] + x * 0.5329522
            b[5] = -0.7616 * b[5] - x * 0.0168980
            let y = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + x * 0.5362
            b[6] = x * 0.115926
            out[i] = Float(y)
            sumSq += y * y
        }
        let g = Float(1 / sqrt(max(sumSq / Double(max(count, 1)), 1e-20)))
        for i in 0..<count { out[i] *= g }
        return out
    }

    public static func sine(_ hz: Double, peakDBFS: Double, seconds: Double, sampleRate: Double) -> [Float] {
        let a = pow(10, peakDBFS / 20)
        return (0..<Int(seconds * sampleRate)).map { Float(a * sin(2 * Double.pi * hz * Double($0) / sampleRate)) }
    }

    /// A quiet room, then hits: each a noise burst that dies like a room (`roomT60`). With `ringHz`,
    /// every hit also starts a tone that dies much more slowly (`ringT60`): the trailing line on
    /// the waterfall. One second of room tone, then a hit every `gap` seconds.
    public static func ringScene(sampleRate: Double, hits: Int = 3, gap: Double = 3, ringHz: Double? = 2400,
                                 ringT60: Double = 2.0, ringPeakDBFS: Double = -26, roomT60: Double = 0.3,
                                 burstRMSDBFS: Double = -20, floorRMSDBFS: Double = -80, pinkBurst: Bool = false) -> [Float] {
        let total = Int(sampleRate * (1 + gap * Double(hits)))
        let floorGain = Float(pow(10, floorRMSDBFS / 20))
        var x = white(total, seed: 7).map { $0 * floorGain }
        let burst = pinkBurst ? pink(total, seed: 99) : white(total, seed: 99)
        let burstGain = pow(10, burstRMSDBFS / 20), ringGain = pow(10, ringPeakDBFS / 20)
        for h in 0..<hits {
            let start = Int(sampleRate * (1 + gap * Double(h)))
            for i in start..<min(total, start + Int(sampleRate * gap)) {
                let t = Double(i - start) / sampleRate
                x[i] += burst[i] * Float(burstGain * pow(10, -3 * t / roomT60))
                if let ringHz {
                    x[i] += Float(ringGain * pow(10, -3 * t / ringT60) * sin(2 * Double.pi * ringHz * t))
                }
            }
        }
        return x
    }
}
