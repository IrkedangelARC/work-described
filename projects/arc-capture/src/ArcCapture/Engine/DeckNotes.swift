//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ARCShowFormat

/// Speaker notes into the deck: `notes.json`, `{"<page>": "text"}`, which is
/// what ARC Presenter reads for its confidence monitor. The show-folder
/// capture never wrote it, so every deck it made reached the stage with no
/// notes although the source had them (3.01: 16 notes slides, 0 in the deck,
/// 2026-09-17). Keyed by the deck's PAGE, not the source's slide: hidden slides
/// and the opening logo page shift one against the other.
enum DeckNotes {
    /// Returns how many pages got notes. A source that is not a PowerPoint file, or has none, writes nothing.
    @discardableResult
    static func write(source: URL, into deck: URL) -> Int {
        guard ["pptx", "pptm", "ppsx"].contains(source.pathExtension.lowercased()),
              let manifest = DeckManifest.load(from: deck.appendingPathComponent("manifest.json")).manifest else { return 0 }
        let bySlide = ShowBuilder.pptxNotes(source)
        guard !bySlide.isEmpty else { return 0 }
        var byPage: [String: String] = [:]
        for page in manifest.slides where page.role == nil {
            guard let n = page.pptxSlide, let text = bySlide[n] else { continue }
            byPage[String(page.slide)] = unescape(text)
        }
        guard !byPage.isEmpty, let data = try? JSONEncoder().encode(byPage) else { return 0 }
        try? data.write(to: deck.appendingPathComponent("notes.json"), options: .atomic)
        return byPage.count
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
}
