//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Turns whatever the operator handed us into a playable .arcdeck bundle.
///
/// An .arcdeck is a directory bundle, so it travels as a zip (Drive, AirDrop,
/// email). Safari unzips on download, Chrome does not, and a crew member then
/// sees "Deck.arcdeck.zip" greyed out in the open panel (a tech, 2026-09-15).
/// Accept the zip: unpack it into ~/Movies/ARC Decks and hand back the bundle.
/// A folder that holds exactly one .arcdeck (the unzipped Drive layout) is
/// accepted too. The whole point is that the operator never has to know.
enum DeckArchive {
    static var library: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/ARC Decks", isDirectory: true)
    }

    static func isArcdeck(_ url: URL) -> Bool { url.pathExtension.lowercased() == "arcdeck" }
    static func isZip(_ url: URL) -> Bool { url.pathExtension.lowercased() == "zip" }

    enum ResolveError: LocalizedError {
        case noDeckInside(URL), unzipFailed(Int32), notADeck(URL)
        var errorDescription: String? {
            switch self {
            case .noDeckInside(let u): "\(u.lastPathComponent) holds no .arcdeck"
            case .unzipFailed(let rc): "could not unzip (ditto exit \(rc))"
            case .notADeck(let u): "\(u.lastPathComponent) is not an .arcdeck, PDF or video"
            }
        }
    }

    /// Bundle URL for `url`, unpacking into `library` when it is a zip. Blocking; call off the main thread for zips.
    static func resolve(_ url: URL, library: URL = DeckArchive.library) throws -> URL {
        if isArcdeck(url) { return url }
        if isZip(url) { return try unpack(url, into: library) }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
           let inner = firstArcdeck(in: url, depth: 2) { return inner }
        throw ResolveError.notADeck(url)
    }

    /// The .arcdeck nearest the top of `dir`, if any (a bundle's own contents are not searched).
    static func firstArcdeck(in dir: URL, depth: Int) -> URL? {
        guard depth >= 0, let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        let sorted = items.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let hit = sorted.first(where: { isArcdeck($0) }) { return hit }
        for item in sorted where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !item.lastPathComponent.hasPrefix("__MACOSX") {
            if let hit = firstArcdeck(in: item, depth: depth - 1) { return hit }
        }
        return nil
    }

    /// Unzips with ditto (Apple's, so Mac metadata entries fold back into
    /// xattrs instead of littering the bundle) into a staging folder, then
    /// moves the bundle into the library, replacing a same-named older copy:
    /// a re-download is a newer deck, not a second one.
    static func unpack(_ zip: URL, into library: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let staging = library.appendingPathComponent(".unpack-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, staging.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ResolveError.unzipFailed(p.terminationStatus) }
        guard let found = firstArcdeck(in: staging, depth: 3) else { throw ResolveError.noDeckInside(zip) }
        let dest = library.appendingPathComponent(found.lastPathComponent, isDirectory: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: found, to: dest)
        return dest
    }
}
