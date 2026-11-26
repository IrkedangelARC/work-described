//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ARCShowFormat

/// Whether a deck's files are actually on this disk. `~/Documents/ARC Shows`
/// is one iCloud folder on the intake Mac and the show Macs (measured
/// 2026-09-18): a new version's show.json lands first, the deck's directory
/// fills over the next minute, and a partly-filled directory whose files
/// are each complete looks finished to a directory walk (v6 read "ready"
/// 8 s after its directory appeared and then would not open). So the check
/// starts from what the manifest says the deck holds, and a file counts as
/// here only when it exists, the kernel does not flag it dataless, its
/// blocks are allocated, and iCloud calls it current.
enum Materialization {
    struct Report: Equatable {
        var local: Int
        var total: Int
        var missing: [String] = []
        /// Nothing expected (no manifest yet) is NOT local.
        var isLocal: Bool { total > 0 && local == total }
    }

    private static let SF_DATALESS: UInt32 = 0x4000_0000

    /// One `lstat` per expected file; a file that is not here has its
    /// download requested (iCloud) when `requestDownload`.
    static func check(_ deck: URL, requestDownload: Bool = true) -> Report {
        let manifestURL = deck.appendingPathComponent("manifest.json")
        guard isHere(manifestURL, requestDownload: requestDownload),
              let manifest = DeckManifest.load(from: manifestURL).manifest else {
            return Report(local: 0, total: 1, missing: ["manifest.json"])
        }
        var expected = ["slides.pdf"]
        for slide in manifest.slides { expected += slide.mediaFiles; expected += slide.stillFiles }
        var local = 0, missing: [String] = []
        for rel in expected {
            if isHere(deck.appendingPathComponent(rel), requestDownload: requestDownload) { local += 1 } else { missing.append(rel) }
        }
        return Report(local: local + 1, total: expected.count + 1, missing: missing)   // +1: the manifest itself
    }

    static func isHere(_ url: URL, requestDownload: Bool) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        var here = true
        if st.st_flags & SF_DATALESS != 0 { here = false }
        if st.st_size > 0, st.st_blocks == 0 { here = false }
        if here, let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
           v.isUbiquitousItem == true, let s = v.ubiquitousItemDownloadingStatus, s != .current { here = false }
        if !here, requestDownload { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
        return here
    }
}
