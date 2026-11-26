//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AVFoundation
import os

/// NSViewRepresentable over a double-buffered pair of AVPlayerLayers.
///
/// Why not one layer: handing a single AVPlayerLayer a new AVPlayer paints
/// the layer's background until the new clip's first frame is decoded. With
/// a click clip on every page of a captured deck that was a flash of black
/// on every click (field report 2026-09-04). Here the NEXT page's player is
/// attached to a hidden back layer ahead of time, so a forward click is a
/// zero-gap swap; any other change keeps the previous frame up until the new
/// clip reports `isReadyForDisplay` (0.4 s backstop). Neither layer paints
/// a background, so whatever the view sits on (the page still) shows through
/// rather than black.
struct AVPlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer?
    var nextPlayer: AVPlayer?
    /// Set on the program output only: its swaps go to show.log with latency, clip and time
    /// (the os_log copy ages out of the system log within minutes, 2026-09-30).
    var logName: String?

    init(player: AVPlayer?, nextPlayer: AVPlayer? = nil, logName: String? = nil) {
        self.player = player
        self.nextPlayer = nextPlayer
        self.logName = logName
    }

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.logName = logName
        view.present(player)
        view.prefetch(nextPlayer)
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.present(player)
        nsView.prefetch(nextPlayer)
    }
}

/// Two AVPlayerLayers, front (visible) and back (opacity 0, pre-armed).
final class PlayerLayerView: NSView {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ArcPresenter",
                                    category: "PlayerLayer")
    private var front = AVPlayerLayer()
    private var back = AVPlayerLayer()
    private var readyObservation: NSKeyValueObservation?
    private var swapBackstop: DispatchWorkItem?
    private var wantedNext: AVPlayer?
    /// The player the view was last asked to show (nil = still page).
    private(set) var presented: AVPlayer?
    /// Diagnostics: how the last swap happened ("prefetched", "cold", "backstop").
    private(set) var lastSwapKind = "none"
    var logName: String?
    private var presentedAt = Date()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = nil
        for l in [front, back] {
            configure(l)
            l.frame = bounds
            layer?.addSublayer(l)
        }
        noAnim {
            front.zPosition = 1; front.opacity = 0
            back.zPosition = 0; back.opacity = 0
        }
    }

    private func configure(_ l: AVPlayerLayer) {
        l.videoGravity = .resizeAspect
        l.backgroundColor = nil
        // No implicit animation on ANY geometry or opacity change, at the
        // layer itself: a frame change arriving through autoresizing or
        // outside a disabled transaction animated the video from a
        // smaller rect in the corner to full size (the operator saw the clip
        // "shrink to 80% in the upper left" on 2026-09-12). layout()
        // sets the frames explicitly, so autoresizing is not needed.
        l.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
                     "opacity": NSNull(), "contents": NSNull(), "transform": NSNull()]
    }

    override func layout() {
        super.layout()
        noAnim { front.frame = bounds; back.frame = bounds }
    }

    private func noAnim(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: - Public

    /// Show `p` (nil = no clip on this page; the layer goes transparent).
    func present(_ p: AVPlayer?) {
        guard p !== presented else { return }
        presented = p
        presentedAt = Date()
        readyObservation = nil
        swapBackstop?.cancel()

        guard let p else {
            if let logName, front.player != nil { ShowLog.log("\(logName) clip off (page still shows)") }
            noAnim { front.opacity = 0 }
            front.player = nil
            rearmPrefetch()
            return
        }
        if back.player === p {
            swapLayers(kind: "prefetched")
            return
        }
        if front.player === p {
            noAnim { front.opacity = 1 }
            return
        }
        // Cold: attach behind, reveal on first decoded frame; the front keeps
        // the previous clip's last frame (or stays transparent) meanwhile.
        // A NEW layer: one that held another player still reports that player's
        // isReadyForDisplay right after the hand-over, so "cold-ready" revealed a
        // layer with no frame of `p` (the slide 2 -> 3 flash, 2026-09-30).
        replaceBack()
        back.player = p
        if back.isReadyForDisplay {
            swapLayers(kind: "cold-ready")
            return
        }
        readyObservation = back.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.commitColdSwap(for: p, kind: "cold") }
        }
        let backstop = DispatchWorkItem { [weak self] in self?.commitColdSwap(for: p, kind: "backstop") }
        swapBackstop = backstop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: backstop)
    }

    /// Pre-arm the back layer with the clip most likely to be shown next.
    func prefetch(_ n: AVPlayer?) {
        wantedNext = n
        rearmPrefetch()
    }

    // MARK: - Private

    private func replaceBack() {
        let fresh = AVPlayerLayer()
        configure(fresh)
        noAnim {
            fresh.frame = bounds; fresh.zPosition = 0; fresh.opacity = 0
            layer?.replaceSublayer(back, with: fresh)
        }
        back.player = nil
        back = fresh
    }

    private func rearmPrefetch() {
        guard let n = wantedNext, n !== front.player else { return }
        // Never disturb a pending cold attach of the presented player.
        if let pending = presented, back.player === pending { return }
        if back.player !== n { back.player = n }
    }

    private func commitColdSwap(for p: AVPlayer, kind: String) {
        guard presented === p, back.player === p else { return }
        readyObservation = nil
        swapBackstop?.cancel()
        swapLayers(kind: kind)
    }

    private func swapLayers(kind: String) {
        noAnim {
            swap(&front, &back)
            front.zPosition = 1; front.opacity = 1
            back.zPosition = 0; back.opacity = 0
        }
        back.player = nil
        lastSwapKind = kind
        Self.log.info("swap \(kind, privacy: .public)")
        if let logName, let p = front.player {
            let clip = (p.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent ?? "?"
            let ms = Int(Date().timeIntervalSince(presentedAt) * 1000)
            ShowLog.log("\(logName) swap \(kind) +\(ms) ms \(clip) at \(String(format: "%.3f", p.currentTime().seconds)) s, ready \(front.isReadyForDisplay)")
        }
        rearmPrefetch()
    }
}
