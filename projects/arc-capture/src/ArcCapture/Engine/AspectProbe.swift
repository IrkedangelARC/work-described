//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import PDFKit
import ImageIO

/// Width / height of a source file, read without opening its app: a pptx's slide size from presentation.xml,
/// a PDF's first page, an image's pixels. nil = not known (Keynote, a movie): never a guess.
enum AspectProbe {
    static func aspect(of url: URL) -> Double? {
        switch url.pathExtension.lowercased() {
        case "pptx", "pptm", "ppsx":
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-p", url.path, "ppt/presentation.xml"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return slideSize(inPresentationXML: String(decoding: data, as: UTF8.self))
        case "pdf":
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            let b = page.bounds(for: .mediaBox)
            let turned = page.rotation % 180 != 0
            return b.height > 0 ? Double(turned ? b.height / b.width : b.width / b.height) : nil
        case "png", "jpg", "jpeg", "heic", "tif", "tiff":
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double, h > 0 else { return nil }
            return w / h
        default: return nil
        }
    }

    /// `<p:sldSz cx="12192000" cy="6858000"/>`
    static func slideSize(inPresentationXML xml: String) -> Double? {
        guard let r = xml.range(of: #"<p:sldSz[^>]*>"#, options: .regularExpression) else { return nil }
        let tag = String(xml[r])
        func n(_ a: String) -> Double? { tag.range(of: "\\b\(a)=\"(\\d+)\"", options: .regularExpression).map { String(tag[$0]) }.flatMap { Double($0.filter(\.isNumber)) } }
        guard let cx = n("cx"), let cy = n("cy"), cy > 0 else { return nil }
        return cx / cy
    }
}
