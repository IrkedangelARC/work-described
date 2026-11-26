//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import CoreMedia
import AVFoundation

/// Peak level of captured app audio, so the session can tell "the movie
/// stopped" (picture AND sound still) from "the picture froze while the
/// song went on" (Sample Deck short slide 4, 2026-09-12: PowerPoint stopped
/// playback at 68 s and the clip ran silent for 158 s more).
final class AudioMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastAudible = Date.distantPast
    private var lastPeak: Float = 0
    /// -50 dBFS: below this the room is silent for our purposes.
    static let audibleThreshold: Float = 0.003

    func note(_ sb: CMSampleBuffer) {
        let p = Self.peak(sb)
        lock.lock(); lastPeak = p; if p > Self.audibleThreshold { lastAudible = Date() }; lock.unlock()
    }
    var lastAudibleAt: Date { lock.lock(); defer { lock.unlock() }; return lastAudible }
    var peak: Float { lock.lock(); defer { lock.unlock() }; return lastPeak }
    func reset() { lock.lock(); lastAudible = .distantPast; lastPeak = 0; lock.unlock() }

    /// Max |sample| over every channel of a Float32 PCM buffer (SCK's format).
    static func peak(_ sb: CMSampleBuffer) -> Float {
        // SCK hands over NON-interleaved stereo: two buffers. A one-buffer
        // list came back with an error and the meter heard nothing (short4).
        var needed = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard needed > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        guard status == noErr else { return 0 }
        var m: Float = 0
        for buf in UnsafeMutableAudioBufferListPointer(ablPtr) {
            guard let data = buf.mData else { continue }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let p = data.assumingMemoryBound(to: Float.self)
            var i = 0
            while i < n { let v = abs(p[i]); if v > m { m = v }; i += 4 }   // every 4th sample is plenty for a peak
        }
        return m
    }
}
