//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import CryptoKit
import PDFKit

/// Per-slide fingerprints for the show ledger (V3, design section 4.2): a
/// recapture diffs them to capture only the slides that changed, and
/// Presenter matches pages between versions with them. Computed from the
/// SOURCE without running a show: the slide XML and its relationships inside
/// a .pptx, the page inside a PDF, the page model of a Google Slides deck.
enum SlideHasher {
    /// 16 hex chars of SHA-256: short enough for show.json, plenty for a diff.
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func fileHash(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return hex(data)
    }

    /// One hash per slide of a .pptx / .pptm / .ppt (zip): slideN.xml plus its
    /// .rels (which names the media), in PRESENTATION order, so index i is the
    /// slide PowerPoint shows i-th and `go to slide i` lands on it. Empty if
    /// the archive cannot be listed.
    static func pptxSlideHashes(_ url: URL) -> [String] {
        guard let listing = run("/usr/bin/unzip", ["-Z1", url.path]) else { return [] }
        let names = listing.split(separator: "\n").map(String.init)
        let fileNumbers = names.compactMap { n -> Int? in
            guard n.hasPrefix("ppt/slides/slide"), n.hasSuffix(".xml") else { return nil }
            return Int(n.dropFirst("ppt/slides/slide".count).dropLast(".xml".count))
        }.sorted()
        // The order is p:sldIdLst resolved through presentation.xml.rels; the
        // slideN.xml numbers are arbitrary after edits. MEASURED 2026-09-17:
        // 0 of 58 corpus decks disagree, but a deck that does would have the
        // wrong slides recaptured. File order is the fallback when the list
        // cannot be read or does not account for every slide file.
        let listed = presentationOrder(
            presentationXML: run("/usr/bin/unzip", ["-p", url.path, "ppt/presentation.xml"]) ?? "",
            relsXML: run("/usr/bin/unzip", ["-p", url.path, "ppt/_rels/presentation.xml.rels"]) ?? "")
        let slideNumbers = Set(listed) == Set(fileNumbers) && listed.count == fileNumbers.count ? listed : fileNumbers
        return slideNumbers.map { n in
            let xml = "ppt/slides/slide\(n).xml", rels = "ppt/slides/_rels/slide\(n).xml.rels"
            var parts = [xml]
            if names.contains(rels) { parts.append(rels) }
            let data = runData("/usr/bin/unzip", ["-p", url.path] + parts) ?? Data()
            return hex(data)
        }
    }

    /// One hash per PDF page: its text, its box, and a 64x36 render, so a
    /// picture-only edit still changes the hash.
    static func pdfPageHashes(_ url: URL) -> [String] {
        guard let doc = PDFDocument(url: url) else { return [] }
        return (0..<doc.pageCount).map { i in
            guard let page = doc.page(at: i) else { return "" }
            var data = Data((page.string ?? "").utf8)
            let b = page.bounds(for: .cropBox)
            data.append(Data("\(Int(b.width))x\(Int(b.height))r\(page.rotation)".utf8))
            let thumb = page.thumbnail(of: NSSize(width: 64, height: 36), for: .cropBox)
            if let tiff = thumb.tiffRepresentation { data.append(tiff) }
            return hex(data)
        }
    }

    /// One hash per Google Slides page from the page model the driver read.
    static func slidesHashes(_ info: SlidesInfo) -> [String] {
        info.slides.sorted { $0.index < $1.index }.map { s in
            let videos = s.videos.map { "\($0.source):\($0.id):\($0.start)-\($0.end):\($0.autoPlay)" }.joined(separator: ",")
            return hex(Data("\(s.objectId)|\(s.skipped)|\(s.buildSteps)|\(s.imageURLs.joined(separator: ","))|\(videos)".utf8))
        }
    }

    /// slideN.xml file numbers in show order: each `p:sldId` of `p:sldIdLst`,
    /// its `r:id` resolved to a `slides/slideN.xml` target. Empty when either
    /// part is missing or an id does not resolve to a slide.
    static func presentationOrder(presentationXML: String, relsXML: String) -> [Int] {
        func attr(_ name: String, in tag: Substring) -> String? {
            guard let r = tag.range(of: "\(name)=\"") else { return nil }
            let rest = tag[r.upperBound...]
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
        }
        func tags(_ name: String, in xml: Substring) -> [Substring] {
            var out: [Substring] = [], cursor = xml.startIndex
            while let open = xml.range(of: "<\(name)", range: cursor..<xml.endIndex),
                  let close = xml.range(of: ">", range: open.upperBound..<xml.endIndex) {
                // "<p:sldId" also opens "<p:sldIdLst": the name must end here.
                if let next = xml[open.upperBound...].first, next == " " || next == "/" || next == ">" || next.isNewline || next == "\t" {
                    out.append(xml[open.lowerBound..<close.upperBound])
                }
                cursor = close.upperBound
            }
            return out
        }
        var targets: [String: Int] = [:]
        for tag in tags("Relationship", in: Substring(relsXML)) {
            guard let id = attr("Id", in: tag), let target = attr("Target", in: tag),
                  let file = target.split(separator: "/").last, file.hasPrefix("slide"), file.hasSuffix(".xml"),
                  target.contains("slides/"), let n = Int(file.dropFirst("slide".count).dropLast(".xml".count)) else { continue }
            targets[id] = n
        }
        guard let start = presentationXML.range(of: "<p:sldIdLst"), let end = presentationXML.range(of: "</p:sldIdLst>") ,
              start.upperBound <= end.lowerBound else { return [] }
        var order: [Int] = []
        for tag in tags("p:sldId", in: presentationXML[start.upperBound..<end.lowerBound]) {
            guard let rid = attr("r:id", in: tag), let n = targets[rid] else { return [] }
            order.append(n)
        }
        return order
    }

    /// 1-based slide numbers in `new` whose hash does not appear in `old`
    /// (set semantics, so inserted slides shift nothing).
    static func changedSlides(old: [String], new: [String]) -> [Int] {
        let known = Set(old)
        return new.enumerated().compactMap { known.contains($0.element) ? nil : $0.offset + 1 }
    }

    private static func run(_ tool: String, _ args: [String]) -> String? {
        runData(tool, args).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func runData(_ tool: String, _ args: [String]) -> Data? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
}
