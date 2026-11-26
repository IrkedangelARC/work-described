//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import CoreGraphics
import Foundation
import ImageIO
import ScopeKit

/// Where shows live and where exports go. Shows are kept by name in one folder, so the same
/// list works on the iPad, where there is no file panel worth using mid-show.
enum ShowLibrary {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ARC Audio Scope")
    static let folder = root.appendingPathComponent("Shows")
    /// The single show every build before named shows kept.
    static let legacy = root.appendingPathComponent("Current.\(ShowFile.fileExtension)")
    static let defaultName = "Current"

    static func url(_ name: String) -> URL { folder.appendingPathComponent("\(name).\(ShowFile.fileExtension)") }
    static func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).appendingPathComponent("show.json").path) }

    /// Newest first.
    static func names() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { $0.pathExtension == ShowFile.fileExtension }
            .map { ($0.deletingPathExtension().lastPathComponent,
                    (try? $0.appendingPathComponent("show.json").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// A name that is safe as a folder name, or nil when nothing is left of it.
    static func clean(_ raw: String) -> String? {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let name = String(raw.unicodeScalars.filter { !bad.contains($0) }).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.hasPrefix(".") else { return nil }
        return String(name.prefix(60))
    }

    static var lastName: String? {
        get { UserDefaults.standard.string(forKey: "currentShow") }
        set { UserDefaults.standard.set(newValue, forKey: "currentShow") }
    }

    /// The show to open at launch. The first launch of a build with named shows copies the old
    /// single show in as "Current" (the old one is left where it was).
    static func launchName() -> String {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !exists(defaultName), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.copyItem(at: legacy, to: url(defaultName))
        }
        if let last = lastName, exists(last) { return last }
        return defaultName
    }

    /// Exports go where the operator can see them: a folder in the home folder on the Mac, the
    /// app's Documents (shown in Files) on the iPad.
    static func exportFolder(show: String, date: Date) -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ARC Audio Scope")
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("Exports").appendingPathComponent(show).appendingPathComponent(stamp.string(from: date))
    }

    /// A one page PDF of a PNG, at the PNG's own size in points.
    static func writePDF(png: Data, to url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
        return true
    }
}
