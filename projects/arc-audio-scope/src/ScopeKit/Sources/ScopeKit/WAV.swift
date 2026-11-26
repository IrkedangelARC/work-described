//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// A mono PCM WAV file in memory: the few seconds a MARK analysed, to keep with the show or play back.
public enum WAV {
    /// `bits`: 16 or 24. `gain` multiplies the samples first; anything past full scale is clipped.
    public static func data(_ samples: [Float], sampleRate: Double, bits: Int = 24, gain: Float = 1) -> Data {
        let bytes = bits / 8, size = samples.count * bytes
        var d = Data(capacity: 44 + size)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + size)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(Int(sampleRate.rounded())); u32(Int(sampleRate.rounded()) * bytes); u16(bytes); u16(bits)
        d.append(contentsOf: Array("data".utf8)); u32(size)
        let full = Float((1 << (bits - 1)) - 1)
        for s in samples {
            let v = Int32((min(max(s * gain, -1), 1) * full).rounded())
            for i in 0..<bytes { d.append(UInt8(truncatingIfNeeded: v >> (8 * i))) }
        }
        return d
    }

    /// The gain that brings the loudest sample to `peak` (0...1), capped so silence is not blown up.
    public static func normalizingGain(_ samples: [Float], peak: Float = 0.7, limit: Float = 1000) -> Float {
        let top = samples.reduce(Float(0)) { max($0, abs($1)) }
        return top > 0 ? min(peak / top, limit) : 1
    }
}
