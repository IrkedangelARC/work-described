//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AVFoundation

/// Live countdown of time REMAINING on a playing clip. Reads duration from the
/// player's own item, so it works for both arcdeck per-slide clips and
/// single-video decks. Goes amber under 10s and red under 5s — the operator's
/// and presenter's cue that the clip is about to end.
///
/// Driven by TimelineView (not a hand-managed Timer): SwiftUI owns the tick, so
/// it can't desync when a parent re-render transiently drops and re-adds this
/// view (which would skip a Timer-based onAppear and freeze the readout).
struct VideoRemainingView: View {
    let player: AVPlayer
    var compact: Bool = false          // operator inline vs. confidence-monitor badge

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let s = sample()
            readout(remaining: s.remaining, isPlaying: s.isPlaying)
        }
        // New player instance (arcdeck slide change) → fresh timeline binding.
        .id(ObjectIdentifier(player))
    }

    @ViewBuilder
    private func readout(remaining: TimeInterval, isPlaying: Bool) -> some View {
        let warn: Color = remaining <= 5 ? ARCTheme.liveRed
            : (remaining <= 10 ? Color.orange : (compact ? ARCTheme.textPrimary : .white))

        if compact {
            HStack(spacing: 4) {
                Text("-\(timecode(remaining))")
                    .font(ARCTheme.mono(14, .bold))
                    .foregroundStyle(warn)
                Text("LEFT")
                    .font(ARCTheme.mono(10, .semibold))
                    .foregroundStyle(ARCTheme.textSecondary)
            }
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Text("-\(timecode(remaining))")
                    .font(ARCTheme.mono(40, .heavy))
                    .foregroundStyle(warn)
                    .monospacedDigit()
                Text(isPlaying ? "REMAINING" : "PAUSED")
                    .font(ARCTheme.mono(15, .bold))
                    .foregroundStyle(isPlaying ? Color.white.opacity(0.5) : Color.orange)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.55))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(warn.opacity(0.5), lineWidth: remaining <= 10 ? 2 : 0)
            )
        }
    }

    /// Sample the player's current remaining time and play state.
    private func sample() -> (remaining: TimeInterval, isPlaying: Bool) {
        var duration: TimeInterval = 0
        if let item = player.currentItem {
            let d = CMTimeGetSeconds(item.duration)
            if d.isFinite && d > 0 { duration = d }
        }
        let t = CMTimeGetSeconds(player.currentTime())
        let remaining = (t.isFinite && duration > 0) ? max(0, duration - t) : 0
        return (remaining, player.timeControlStatus == .playing)
    }

    private func timecode(_ time: TimeInterval) -> String {
        let total = Int(time.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
