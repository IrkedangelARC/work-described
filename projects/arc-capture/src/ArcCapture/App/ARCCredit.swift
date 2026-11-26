//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import PDFKit

/// Who made this, said once and used everywhere the app signs its work: the About box and the
/// PDF every capture writes (2026-11-25, the free public build: "make sure this is credited to my
/// company"). The slides stay the presenter's: only the PDF's Creator and Producer fields name the
/// tool, never its Author or Title.
enum ARCCredit {
    static let maker = "ARC Event Productions"
    static let place = "San Jose, California"
    static let site = "arceventproductions.com"
    static let tagline = "We don't sell failure\u{2122}"
    static let siteURL = URL(string: "https://arceventproductions.com")!

    static var version: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "" }
    /// "ARC Capture 3.4.1 by ARC Event Productions".
    static var signature: String { "ARC Capture\(version.isEmpty ? "" : " " + version) by \(maker)" }

    /// Name the tool in a PDF it is about to write. Fields already set are replaced.
    static func stamp(_ document: PDFDocument) {
        var attrs = document.documentAttributes ?? [:]
        attrs[PDFDocumentAttribute.creatorAttribute] = signature
        attrs[PDFDocumentAttribute.producerAttribute] = "\(maker), \(site)"
        document.documentAttributes = attrs
    }

    /// The same credit for a PDF drawn through Quartz (the capture's own writer, PDFAssembler). Quartz
    /// writes its own Producer, so the Creator field carries the tool and the company.
    static var quartzInfo: CFDictionary { [kCGPDFContextCreator as String: signature] as CFDictionary }

    @MainActor static func showAbout() {
        let centered = NSMutableParagraphStyle(); centered.alignment = .center
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: centered]
        let credits = NSMutableAttributedString(string: "Made by \(maker)\n\(tagline)\n\(place)\n", attributes: body)
        var link = body; link[.link] = siteURL
        credits.append(NSAttributedString(string: site, attributes: link))
        credits.append(NSAttributedString(string: "\n\nFree software under the Apache License 2.0.\nARC, the ARC mark and \(tagline) belong to \(maker).", attributes: body))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}
