//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AppKit
import AVFoundation
import PDFKit
import ARCShowFormat

/// A show deck NEVER carries a black page nobody asked for (2026-09-19: "there should NEVER be a
/// black slide where a black slide was not asked for. At the very least there should be a holding slide
/// that clearly says there is a problem and there should be an alert and an explicit approval of that
/// omission"). `BlackPages.find` names the black pages of a deck (R12 in the review queue); the build
/// refuses to run while one is undecided; an accepted one is replaced by `ProblemSlide`, an explicit
/// LEAVE IT BLACK keeps it.
enum BlackPages {
    struct Hit: Equatable { let page: Int; let reason: String }
    /// A page is black when almost no pixel is lit: fewer than one in a thousand above a quarter brightness. A
    /// dark-themed slide with white text lights two or three in a hundred (5.92 page 3 read as black by mean
    /// luminance, 2026-09-19); a black page lights none.
    static let litFraction: CGFloat = 0.001
    static let litLevel: CGFloat = 0.25

    static func find(in deck: URL) async -> [Hit] {
        guard let manifest = DeckManifest.load(from: deck.appendingPathComponent("manifest.json")).manifest,
              let pdf = PDFDocument(url: deck.appendingPathComponent("slides.pdf")) else { return [] }
        var hits: [Hit] = []
        for s in manifest.slides where s.role == nil {
            guard let page = pdf.page(at: s.slide - 1) else { continue }
            // A page with builds is seen finished, as its last state still: PowerPoint's PDF draws a linked
            // picture black where the screen showed it (7.94 slide 9, 2026-09-19); the room sees the still.
            let finished = s.builds?.last.map { deck.appendingPathComponent($0.still) }.flatMap { NSImage(contentsOf: $0) }
            let still = finished ?? page.thumbnail(of: CGSize(width: 160, height: 90), for: .mediaBox)
            let pageBlack = isBlack(still)
            var movieBlack = false
            if let rel = s.file {
                movieBlack = await clipIsBlack(deck.appendingPathComponent(rel))
            }
            if pageBlack && (s.file == nil || movieBlack) {
                hits.append(Hit(page: s.slide, reason: s.file == nil ? "the page is black" : "the page and its movie are black from start to end"))
            } else if movieBlack {
                hits.append(Hit(page: s.slide, reason: "the movie is black from start to end (the page's still is not)"))
            }
        }
        return hits
    }

    /// The clip's last second is black: a way in whose hold, the poster, was never drawn.
    static func clipTailIsBlack(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return false }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 90)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600); gen.requestedTimeToleranceAfter = .zero
        for back in [0.05, 0.6] {
            let t = CMTime(seconds: max(0, duration.seconds - back), preferredTimescale: 600)
            guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else { return false }
            if !isBlack(NSImage(cgImage: cg, size: .zero)) { return false }
        }
        return true
    }

    /// Three frames across the clip, all black.
    static func clipIsBlack(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return false }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 90)
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        for f in [0.1, 0.5, 0.9] {
            let t = CMTime(seconds: duration.seconds * f, preferredTimescale: 600)
            guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else { return false }
            if !isBlack(NSImage(cgImage: cg, size: .zero)) { return false }
        }
        return true
    }

    /// The share of pixels lit above `litLevel`, read on a grid of up to 160 x 90 points.
    static func litShare(of image: NSImage) -> CGFloat {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return 1 }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return 1 }
        var lit = 0; var n = 0
        let sx = max(1, w / 160), sy = max(1, h / 90)
        for y in stride(from: 0, to: h, by: sy) { for x in stride(from: 0, to: w, by: sx) {
            if let c = rep.colorAt(x: x, y: y) {
                let l = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                if l >= litLevel { lit += 1 }
                n += 1
            }
        } }
        return n == 0 ? 1 : CGFloat(lit) / CGFloat(n)
    }

    static func isBlack(_ image: NSImage) -> Bool { litShare(of: image) < litFraction }
}

/// The slide the show carries where a page could not be captured: it SAYS so, in ARC's own type, so the room
/// sees a notice and the operator knows, never a black page.
enum ProblemSlide {
    static func image(size: CGSize, item: String, title: String, page: Int, reason: String) -> NSImage {
        let size = CGSize(width: max(640, size.width), height: max(360, size.height))
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(red: 0x0B/255, green: 0x0B/255, blue: 0x0C/255, alpha: 1).setFill()          // ARC ink
        NSRect(origin: .zero, size: size).fill()
        let red = NSColor(red: 0xC1/255, green: 0x27/255, blue: 0x2D/255, alpha: 1)       // the ONE red, arc_brand.json
        let bandH = size.height * 0.16
        red.setFill()
        NSRect(x: 0, y: size.height - bandH, width: size.width, height: bandH).fill()
        func font(_ pt: CGFloat, bold: Bool = true) -> NSFont {
            NSFont(name: bold ? "Futura-Bold" : "Futura-Medium", size: pt) ?? NSFont.systemFont(ofSize: pt, weight: bold ? .heavy : .medium)
        }
        func draw(_ text: String, y: CGFloat, pt: CGFloat, color: NSColor, bold: Bool = true) {
            let p = NSMutableParagraphStyle(); p.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: font(pt, bold: bold), .foregroundColor: color, .paragraphStyle: p]
            let h = pt * 1.4
            NSAttributedString(string: text, attributes: attrs).draw(in: NSRect(x: size.width * 0.06, y: y, width: size.width * 0.88, height: h))
        }
        let s = size.height / 1080
        draw("PAGE NOT CAPTURED", y: size.height - bandH + bandH * 0.22, pt: 72 * s, color: .white)
        draw("\(item)  \(title)", y: size.height * 0.58, pt: 56 * s, color: .white)
        draw("SLIDE \(page)", y: size.height * 0.46, pt: 48 * s, color: NSColor(white: 0.85, alpha: 1))
        draw(reason, y: size.height * 0.30, pt: 34 * s, color: NSColor(white: 0.62, alpha: 1), bold: false)
        draw("ARC Capture put this slide here in place of a black page. Decide it in REVIEW.", y: size.height * 0.10, pt: 26 * s, color: NSColor(white: 0.45, alpha: 1), bold: false)
        img.unlockFocus()
        return img
    }
}
