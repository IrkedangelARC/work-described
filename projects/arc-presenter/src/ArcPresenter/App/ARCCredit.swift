//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

/// Who made this, said once: the About box of the app (2026-11-25, the free public build, credited
/// to the company the same way ARC Capture is).
enum ARCCredit {
    static let maker = "ARC Event Productions"
    static let place = "San Jose, California"
    static let site = "arceventproductions.com"
    static let tagline = "We don't sell failure\u{2122}"
    static let siteURL = URL(string: "https://arceventproductions.com")!

    static var version: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "" }
    /// "ARC Presenter 5.6.1 by ARC Event Productions".
    static var signature: String { "ARC Presenter\(version.isEmpty ? "" : " " + version) by \(maker)" }

    /// The text of the About box, apart from the link.
    static var creditLines: String { "Made by \(maker)\n\(tagline)\n\(place)\n" }
    static var licenseLines: String { "\n\nFree software under the Apache License 2.0.\nARC, the ARC mark and \(tagline) belong to \(maker).\nSDI output is built against the Blackmagic DeckLink SDK interface." }

    @MainActor static func showAbout() {
        let centered = NSMutableParagraphStyle(); centered.alignment = .center
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: centered]
        let credits = NSMutableAttributedString(string: creditLines, attributes: body)
        var link = body; link[.link] = siteURL
        credits.append(NSAttributedString(string: site, attributes: link))
        credits.append(NSAttributedString(string: licenseLines, attributes: body))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
