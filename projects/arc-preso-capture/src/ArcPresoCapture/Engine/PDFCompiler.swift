//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import CoreGraphics
import Foundation
import PDFKit

enum PDFCompiler {
    static func writePNG(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    static func writePDF(images: [CGImage], to url: URL) throws {
        let doc = PDFDocument()
        for (i, img) in images.enumerated() {
            let nsImage = NSImage(
                cgImage: img,
                size: NSSize(width: img.width, height: img.height)
            )
            guard let page = PDFPage(image: nsImage) else { continue }
            doc.insert(page, at: i)
        }
        guard doc.write(to: url) else {
            throw NSError(
                domain: "PDFCompiler",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to write PDF"]
            )
        }
    }
}
