//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import CoreVideo
import Accelerate

/// The pure arithmetic behind settle and motion detection: a coarse
/// fingerprint of a frame and the normalised difference between two of them.
/// No actor, no AppKit, so the thresholds are unit-testable and the work can
/// run off the main actor.
enum FrameAnalysis {

    /// Fingerprint grid. 320x180 of BGR samples = 172,800 bytes per frame.
    static let width = 320
    static let height = 180

    /// Normalised mean absolute difference below which two frames count as
    /// identical for SETTLE purposes (0.5% of full scale).
    static let settleThreshold: Float = 0.005
    /// Any change above this counts as a "changed frame" for motion counting.
    /// Catches subtle partial-slide animations that fall below settleThreshold.
    static let motionCountThreshold: Float = 0.001
    /// Cross-slide duplicate detection (end of show). Much tighter than
    /// settleThreshold: two different slides on the same template can sit
    /// within 0.5% of each other; a true repeat is near-identical.
    static let duplicateThreshold: Float = 0.001

    /// Sample a 32BGRA pixel buffer on a coarse grid into a BGR byte array.
    static func fingerprint(_ pixelBuffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
        return fingerprint(base: base.assumingMemoryBound(to: UInt8.self), width: w, height: h, bytesPerRow: bytesPerRow)
    }

    /// Same, over raw bytes (tests feed synthetic frames through this).
    static func fingerprint(base: UnsafePointer<UInt8>, width w: Int, height h: Int, bytesPerRow: Int) -> [UInt8] {
        let stepX = max(1, w / width)
        let stepY = max(1, h / height)
        var out = [UInt8]()
        out.reserveCapacity((w / stepX + 1) * (h / stepY + 1) * 3)
        var y = 0
        while y < h {
            var x = 0
            let row = y * bytesPerRow
            while x < w {
                let o = row + x * 4
                out.append(base[o]); out.append(base[o + 1]); out.append(base[o + 2])
                x += stepX
            }
            y += stepY
        }
        return out
    }

    /// Mean absolute difference over the shorter of the two, normalised to 0…1.
    /// Empty input = maximal difference (never a false "identical").
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 1.0 }
        var total: Float = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                var fa = [Float](repeating: 0, count: n)
                var fb = [Float](repeating: 0, count: n)
                vDSP_vfltu8(pa.baseAddress!, 1, &fa, 1, vDSP_Length(n))
                vDSP_vfltu8(pb.baseAddress!, 1, &fb, 1, vDSP_Length(n))
                var d = [Float](repeating: 0, count: n)
                vDSP_vsub(fb, 1, fa, 1, &d, 1, vDSP_Length(n))
                vDSP_vabs(d, 1, &d, 1, vDSP_Length(n))
                vDSP_sve(d, 1, &total, vDSP_Length(n))
            }
        }
        return total / Float(n) / 255.0
    }

    static func isSettledPair(_ a: [UInt8], _ b: [UInt8]) -> Bool { difference(a, b) < settleThreshold }
    static func isChangedPair(_ a: [UInt8], _ b: [UInt8]) -> Bool { difference(a, b) >= motionCountThreshold }
    static func isDuplicateSlide(_ a: [UInt8]?, _ b: [UInt8]?) -> Bool {
        guard let a, let b else { return false }
        return difference(a, b) < duplicateThreshold
    }
}
