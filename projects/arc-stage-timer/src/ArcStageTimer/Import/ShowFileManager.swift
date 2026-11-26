//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Manages saving and loading shows as ROS JSON files in a local directory.
enum ShowFileManager {

    /// The local folder for saved shows (Documents/SavedShows/)
    static var savedShowsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("SavedShows", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Save

    /// Save a show to the local library. Returns the file URL on success.
    @discardableResult
    static func save(_ show: Show) throws -> URL {
        guard let data = ROSImporter.exportShow(show) else {
            throw ShowFileError.exportFailed
        }
        let filename = sanitizedFilename(for: show)
        let url = savedShowsDirectory.appendingPathComponent(filename)

        // If a file with the same name exists, overwrite it
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - List

    /// List all saved show files with metadata.
    static func listSavedShows() -> [SavedShowInfo] {
        let fm = FileManager.default
        let dir = savedShowsDirectory
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return []
        }

        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> SavedShowInfo? in
                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }

                let name = json["event_name"] as? String ?? url.deletingPathExtension().lastPathComponent
                let arcNumber = json["arc_number"] as? String
                let dateStr = json["event_date"] as? String
                let venue = json["venue"] as? String
                let cueCount = (json["sessions"] as? [[String: Any]])?.count ?? 0

                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let savedDate = attrs?[.modificationDate] as? Date ?? .now
                let fileSize = attrs?[.size] as? Int ?? 0

                return SavedShowInfo(
                    url: url,
                    name: name,
                    arcNumber: arcNumber,
                    eventDate: dateStr,
                    venue: venue,
                    cueCount: cueCount,
                    savedDate: savedDate,
                    fileSize: fileSize
                )
            }
            .sorted { $0.savedDate > $1.savedDate }
    }

    // MARK: - Load

    /// Load a show from a saved file URL.
    static func load(from url: URL) throws -> Show {
        let data = try Data(contentsOf: url)
        return try ROSImporter.importShow(from: data)
    }

    // MARK: - Delete

    /// Delete a saved show file.
    static func delete(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Helpers

    private static func sanitizedFilename(for show: Show) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: show.date)

        var parts = [show.name]
        if let arc = show.arcNumber, !arc.isEmpty {
            parts.append(arc)
        }
        parts.append(dateStr)

        let raw = parts.joined(separator: "_")
        // Replace unsafe characters
        let safe = raw.replacingOccurrences(of: "[^a-zA-Z0-9_\\-]", with: "-", options: .regularExpression)
        return safe + ".json"
    }
}

// MARK: - Supporting Types

struct SavedShowInfo: Identifiable {
    let url: URL
    let name: String
    let arcNumber: String?
    let eventDate: String?
    let venue: String?
    let cueCount: Int
    let savedDate: Date
    let fileSize: Int

    var id: URL { url }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }

    var formattedSavedDate: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: savedDate)
    }
}

enum ShowFileError: LocalizedError {
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .exportFailed: "Failed to export show data."
        }
    }
}
