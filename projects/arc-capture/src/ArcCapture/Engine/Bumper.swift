//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import AVFoundation
import ARCShowFormat

/// The logo pages around a deck (2026-09-17: "We will add title or logo
/// slides before, between and after all decks. Use the arc logo for now").
///
/// Opening: what is on screen before the presenter's first slide. Closing:
/// what the show lands on after the last one, and the page the LAST slide's
/// builds are recorded against: they used to be thrown away, because the
/// recording made while leaving a slide belongs to the page that follows it
/// and nothing followed the last slide.
enum Bumper {
    private final class Token {}

    /// The white ARC mark on the ink ground, or a show's own `bumper.png` fitted to the frame.
    static func image(size: CGSize, custom: URL? = nil) -> NSImage {
        let size = CGSize(width: max(320, size.width), height: max(180, size.height))
        let art = custom.flatMap { NSImage(contentsOf: $0) }
        let logo = art ?? (logoURL.flatMap { NSImage(contentsOf: $0) })
        return NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255, alpha: 1).setFill(); rect.fill()   // ARCTheme ink
            guard let logo, logo.size.width > 0, logo.size.height > 0 else { return true }
            // The house mark sits at 42 % of the width; a show's own art fills the frame.
            let scale = art != nil ? min(rect.width / logo.size.width, rect.height / logo.size.height)
                                   : min(rect.width * 0.42 / logo.size.width, rect.height * 0.6 / logo.size.height)
            let w = logo.size.width * scale, h = logo.size.height * scale
            logo.draw(in: CGRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    static var logoURL: URL? {
        Bundle.main.url(forResource: "arc-logo-white", withExtension: "png") ?? Bundle(for: Token.self).url(forResource: "arc-logo-white", withExtension: "png")
    }

    /// The recording made while leaving the LAST slide, and its click marks.
    struct Tail { let clip: URL; let clicks: [Double] }

    /// opening logo + the slides (renumbered) + closing logo. The closing page
    /// carries the tail recording only when it holds builds (two marks or
    /// more: a build, then the click that left); the splitter moves those to
    /// the last slide and drops what is left, PowerPoint's way out to its own
    /// end-of-show screen.
    static func wrap(slides: [CaptureResult], tail: Tail?, logo: NSImage, at date: Date = Date()) -> [CaptureResult] {
        func page(_ id: Int, _ role: DeckManifest.Role) -> CaptureResult {
            var p = CaptureResult(id: id, pptxSlide: nil, slideType: .image, image: logo, videoURL: nil, capturedAt: date, settleMs: 0, motionFrames: 0, endedBy: "bumper")
            p.role = role
            return p
        }
        var out = [page(1, .opening)]
        for s in slides { var c = s; c.id = s.id + 1; out.append(c) }
        var closing = page(out.count + 1, .closing)
        if let tail, tail.clicks.count >= 2, FileManager.default.fileExists(atPath: tail.clip.path) {
            closing = CaptureResult(id: closing.id, pptxSlide: nil, slideType: .video, image: logo, videoURL: tail.clip, capturedAt: date, settleMs: 0, motionFrames: 0, endedBy: "bumper")
            closing.role = .closing
            closing.clicks = tail.clicks
            closing.entryClick = tail.clicks.count - 1
        }
        out.append(closing)
        return out
    }
}
