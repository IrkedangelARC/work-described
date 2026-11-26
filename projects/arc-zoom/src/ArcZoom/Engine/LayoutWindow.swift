//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import CoreVideo

/// An output window: what the ROOM sees, and what ARC Presenter takes as a source.
///
/// Three rules it exists to obey, all measured on 2026-09-20 against the Zoom client
/// (`arc-presenter-v5/docs/DRILL_2026-09-20_zoom_source.md`):
///   - ORDINARY window level. Zoom's own share picker lists nothing above it (finding 13), and so does
///     ARC Presenter's window picker. The program window of Presenter sits at the shielding level and
///     Zoom cannot see it; these must not repeat that.
///   - A FIXED, boring TITLE. Presenter takes a window by name, so the name is the contract:
///     "ARC Zoom Program", "ARC Zoom Gallery", "ARC Zoom Strip".
///   - It never collapses, hides or resizes itself. Zoom's meeting window collapsing off screen on every
///     share start is the fault that cost the morning (finding 6); a window we own cannot do that.
@MainActor
final class LayoutWindow {
    enum Kind: String, CaseIterable, Sendable {
        case program, gallery, strip

        var title: String {
            switch self {
            case .program: return "ARC Zoom Program"
            case .gallery: return "ARC Zoom Gallery"
            case .strip:   return "ARC Zoom Strip"
            }
        }

        /// The size that makes sense for each, in points, before the operator changes it.
        var defaultSize: CGSize {
            switch self {
            case .program: return CGSize(width: 1280, height: 720)
            case .gallery: return CGSize(width: 1280, height: 720)
            case .strip:   return CGSize(width: 1920, height: 200)
            }
        }
    }

    let kind: Kind
    private(set) var window: NSWindow?
    let host = TileHostView()

    var isOpen: Bool { window?.isVisible ?? false }
    var size: CGSize { window?.contentView?.bounds.size ?? .zero }

    init(kind: Kind) { self.kind = kind }

    func open(size: CGSize? = nil) {
        let wanted = size ?? kind.defaultSize
        if let w = window {
            // Held on a display by the DisplayManager (shielding level): its size is the display's, and it
            // is never resized or reordered from here (2026-09-20: OPEN after OFF shrank the live program
            // to 1280x720 in the middle of the ALOLG).
            if w.level.rawValue >= Int(CGShieldingWindowLevel()) { w.orderFrontRegardless(); return }
            if w.contentView?.bounds.size != wanted {
                w.setContentSize(NSSize(width: wanted.width, height: wanted.height))
            }
            w.orderBack(nil)
            return
        }
        // BORDERLESS, because this window is a PICTURE: a title bar lands in whatever captures it, and
        // the first Presenter take of this window had ARC Zoom's own title bar across the top of the
        // room's screen (2026-09-20). The window server still reports `title`, which is what Presenter's
        // and Zoom's pickers list by, so nothing is lost. Resizable and draggable by its background, so
        // the operator can still place and size it without a frame.
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: wanted.width, height: wanted.height)),
                         styleMask: [.borderless, .resizable],
                         backing: .buffered, defer: false)
        w.title = kind.title
        w.level = .normal                      // never .screenSaver / shielding: pickers drop those
        w.isOpaque = true
        w.backgroundColor = .black
        w.collectionBehavior = [.fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.hasShadow = false
        w.contentView = host
        // NO frame autosave. An output window is the size that was ASKED for: a saved frame from an
        // earlier run silently restored 1280x752 over a 1280x720 request (2026-09-20), and a capture
        // sized to the wrong thing is the kind of fault nobody spots until it is on a wall. Cascaded so
        // the three never land exactly on top of each other.
        w.setFrame(NSRect(origin: Self.origin(for: kind), size: NSSize(width: wanted.width, height: wanted.height)), display: true)
        w.orderBack(nil)
        window = w
        ShowLog.log("\(kind.title) open at \(Int(wanted.width))x\(Int(wanted.height))")
    }

    func close() {
        guard let w = window else { return }
        w.orderOut(nil)
        host.clear()
        ShowLog.log("\(kind.title) closed")
    }

    /// On a display right now (the DisplayManager put it there). Such a window is never closed by the
    /// window controls: OFF means BLACK, because an output must never show the desktop.
    var isHeldOnDisplay: Bool { (window?.level.rawValue ?? 0) >= Int(CGShieldingWindowLevel()) && isOpen }

    /// Bottom-left of each window, cascaded on the operator's screen so the three are all reachable.
    private static func origin(for kind: Kind) -> CGPoint {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let v = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let step: CGFloat = 40
        let n = CGFloat(Kind.allCases.firstIndex(of: kind) ?? 0)
        return CGPoint(x: v.minX + 24 + n * step, y: v.minY + 24 + n * step)
    }

    var json: String {
        let s = size
        return "{\"kind\":\"\(kind.rawValue)\",\"title\":\"\(kind.title)\",\"open\":\(isOpen),\"w\":\(Int(s.width)),\"h\":\(Int(s.height))}"
    }
}

/// The view inside an output window: one CALayer per TILE (a participant in a region, or a placeholder),
/// plus a name plate. Keyed per region so one participant can be the speaker AND sit in the strip.
/// Flipped, so layout math is top-left like everything else in the app.
final class TileHostView: NSView {
    struct Entry: Equatable {
        let key: String
        /// nil = a placeholder (the SHARE slot with nobody sharing): dark, labelled, no video.
        let participant: UInt32?
        let frame: CGRect
        let label: String
    }

    private var tiles: [String: Tile] = [:]

    private final class Tile {
        let video = CALayer()
        let plate = CALayer()
        let label = CATextLayer()
        var participant: UInt32?
        /// Held so the IOSurface under the layer is never recycled while it is on screen.
        var retained: CVPixelBuffer?
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    /// Previews inside the operator window are laid out by SwiftUI; this tells the Sidecar to redraw.
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The tiles to show, in drawing order. Tiles for keys not listed go away.
    func set(entries: [Entry]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let keys = Set(entries.map(\.key))
        for k in tiles.keys where !keys.contains(k) { remove(k) }
        for e in entries {
            let tile = tiles[e.key] ?? makeTile(for: e.key)
            tile.participant = e.participant
            tile.video.frame = e.frame
            tile.video.zPosition = 0
            let placeholder = e.participant == nil
            tile.video.backgroundColor = CGColor(gray: placeholder ? 0.14 : 0.08, alpha: 1)
            if placeholder { tile.video.contents = nil; tile.retained = nil }
            let plateH: CGFloat = max(18, min(34, e.frame.height * 0.10))
            tile.plate.frame = placeholder ? CGRect(x: e.frame.minX, y: e.frame.midY - plateH / 2, width: e.frame.width, height: plateH)
                                           : CGRect(x: e.frame.minX, y: e.frame.maxY - plateH, width: e.frame.width, height: plateH)
            tile.label.frame = tile.plate.frame.insetBy(dx: 8, dy: 0)
            tile.label.fontSize = plateH * 0.62
            tile.label.string = e.label
            tile.label.alignmentMode = placeholder ? .center : .left
            tile.plate.isHidden = plateH < 14 && !placeholder
            tile.label.isHidden = tile.plate.isHidden
            // Drawing order = list order: a PiP listed last sits on top of a share.
            for l in [tile.video, tile.plate, tile.label] { l.removeFromSuperlayer(); layer?.addSublayer(l) }
        }
    }

    /// The old API, kept for callers that place participants directly.
    func set(order: [UInt32], rects: [CGRect], names: [UInt32: String]) {
        set(entries: zip(order, rects).map { id, r in Entry(key: "0.\(id)", participant: id, frame: r, label: names[id] ?? "\(id)") })
    }

    /// A new frame for one participant: every tile showing that participant takes it. Zero copy: the
    /// layer takes the buffer's IOSurface.
    func show(_ buffer: CVPixelBuffer, for id: UInt32) {
        guard let surface = CVPixelBufferGetIOSurface(buffer) else { return }
        let mine = tiles.values.filter { $0.participant == id }
        guard !mine.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for tile in mine {
            tile.retained = buffer
            tile.video.contents = surface.takeUnretainedValue()
        }
        CATransaction.commit()
    }

    func clear() { for k in tiles.keys { remove(k) } }

    private func makeTile(for key: String) -> Tile {
        let tile = Tile()
        tile.video.backgroundColor = CGColor(gray: 0.08, alpha: 1)
        tile.video.contentsGravity = .resizeAspect
        tile.video.magnificationFilter = .linear
        tile.video.minificationFilter = .linear
        tile.plate.backgroundColor = CGColor(gray: 0, alpha: 0.55)
        tile.label.foregroundColor = CGColor(gray: 1, alpha: 1)
        tile.label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        tile.label.alignmentMode = .left
        tile.label.truncationMode = .middle
        tile.label.contentsScale = window?.backingScaleFactor ?? 2
        layer?.addSublayer(tile.video)
        layer?.addSublayer(tile.plate)
        layer?.addSublayer(tile.label)
        tiles[key] = tile
        return tile
    }

    private func remove(_ key: String) {
        guard let tile = tiles.removeValue(forKey: key) else { return }
        tile.video.removeFromSuperlayer()
        tile.plate.removeFromSuperlayer()
        tile.label.removeFromSuperlayer()
        tile.retained = nil
    }
}
