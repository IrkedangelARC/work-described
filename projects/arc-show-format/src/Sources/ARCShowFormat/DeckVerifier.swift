//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import PDFKit
import AVFoundation
import ImageIO

/// Is this .arcdeck fit to play? One implementation for Capture (before
/// COMPLETE), the show builder (every input), Presenter (on load, pre-show)
/// and the preflight. Runs off the caller's thread.
public struct DeckVerdict: Equatable, Sendable {
    public var ok: Bool
    public var pages: Int
    public var clips: Int
    public var problems: [String]
    public var warnings: [String]
    public var detail: String {
        if ok { return "\(pages) page\(pages == 1 ? "" : "s"), \(clips) clip\(clips == 1 ? "" : "s") playable" + (warnings.isEmpty ? "" : " (\(warnings.count) warning\(warnings.count == 1 ? "" : "s"))") }
        return problems.prefix(3).joined(separator: "; ")
    }
}

public enum DeckVerifier {
    public static func verify(arcdeck url: URL) async -> DeckVerdict {
        await Task.detached(priority: .userInitiated) { await verifyNow(arcdeck: url) }.value
    }

    /// Synchronous body (call off main).
    public static func verifyNow(arcdeck url: URL) async -> DeckVerdict {
        let fm = FileManager.default
        var problems: [String] = [], warnings: [String] = []
        guard fm.fileExists(atPath: url.path) else {
            return DeckVerdict(ok: false, pages: 0, clips: 0, problems: ["missing: \(url.path)"], warnings: [])
        }
        let pdfURL = url.appendingPathComponent("slides.pdf")
        guard let doc = PDFDocument(url: pdfURL) else {
            return DeckVerdict(ok: false, pages: 0, clips: 0, problems: ["slides.pdf missing or will not open"], warnings: [])
        }
        let pages = doc.pageCount
        if pages == 0 { problems.append("slides.pdf has no pages") }

        let manifestURL = url.appendingPathComponent("manifest.json")
        let loaded = DeckManifest.load(from: manifestURL)
        warnings.append(contentsOf: loaded.warnings)
        if !fm.fileExists(atPath: manifestURL.path) { warnings.append("no manifest.json: stills only") }
        var clips = 0
        if let manifest = loaded.manifest {
            if let last = manifest.slides.map(\.slide).max(), last > pages {
                problems.append("manifest names slide \(last) but slides.pdf has \(pages) pages")
            }
            var referenced = Set<String>()
            for slide in manifest.slides {
                for file in slide.mediaFiles {
                    referenced.insert(file)
                    clips += 1
                    let clip = url.appendingPathComponent(file)
                    guard fm.fileExists(atPath: clip.path) else { problems.append("\(file) missing"); continue }
                    let playable = (try? await AVURLAsset(url: clip).load(.isPlayable)) ?? false
                    if !playable { problems.append("\(file) not playable") }
                }
            }
            // Version 3: a build's state still is what Presenter CUTS to on a
            // back-step, so a missing or unreadable one is a fault, not a warning.
            for slide in manifest.slides {
                for still in slide.stillFiles {
                    let file = url.appendingPathComponent(still)
                    guard fm.fileExists(atPath: file.path) else { problems.append("\(still) missing"); continue }
                    guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(src) > 0,
                          CGImageSourceCreateImageAtIndex(src, 0, nil) != nil else { problems.append("\(still) will not decode"); continue }
                }
                if let builds = slide.builds, !builds.isEmpty, slide.initialStill == nil {
                    problems.append("slide \(slide.slide) has \(builds.count) build(s) and no initial still")
                }
            }
            // Orphans: media in the bundle nothing references.
            let mediaDir = url.appendingPathComponent("media")
            if let files = try? fm.contentsOfDirectory(atPath: mediaDir.path) {
                for f in files where !f.hasPrefix(".") && !referenced.contains("media/\(f)") {
                    warnings.append("media/\(f) is not referenced by the manifest")
                }
            }
        }
        return DeckVerdict(ok: problems.isEmpty, pages: pages, clips: clips, problems: problems, warnings: warnings)
    }
}
