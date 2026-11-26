//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Manages saving, loading, and deleting design presets as JSON files.
/// Storage: ~/Library/Application Support/ArcLowerThirds/Presets/
@Observable
class PresetManager {
    private(set) var presets: [DesignPreset] = []
    var errorMessage: String?

    private var presetsDirectory: URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("ArcLowerThirds/Presets")
        }
        return appSupport.appendingPathComponent("ArcLowerThirds/Presets")
    }

    init() {
        ensureDirectory()
        loadAll()
    }

    // MARK: - Public API

    func save(_ preset: DesignPreset) {
        let url = fileURL(for: preset)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(preset)
            try data.write(to: url)
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
        loadAll()
    }

    func delete(_ preset: DesignPreset) {
        let url = fileURL(for: preset)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
        loadAll()
    }

    func apply(_ preset: DesignPreset, to graphic: Graphic) {
        preset.apply(to: graphic)
    }

    func duplicate(_ preset: DesignPreset) {
        var copy = preset
        copy.id = UUID()
        copy.name = "\(preset.name) (Copy)"
        copy.createdAt = Date()
        save(copy)
    }

    func rename(_ preset: DesignPreset, to newName: String) {
        var updated = preset
        updated.name = newName
        delete(preset)
        save(updated)
    }

    /// Presets grouped by template type
    var presetsByTemplate: [String: [DesignPreset]] {
        Dictionary(grouping: presets, by: { $0.template })
    }

    func search(_ query: String) -> [DesignPreset] {
        guard !query.isEmpty else { return presets }
        let q = query.lowercased()
        return presets.filter { $0.name.lowercased().contains(q) }
    }

    /// Import all presets from a JSON file (array of DesignPreset)
    func importPresets(from url: URL) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let imported = try? decoder.decode([DesignPreset].self, from: data) else {
            errorMessage = "Could not read presets file"
            return
        }
        for preset in imported {
            save(preset)
        }
    }

    // MARK: - Private

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
    }

    private func fileURL(for preset: DesignPreset) -> URL {
        presetsDirectory.appendingPathComponent("\(preset.id.uuidString).json")
    }

    private func loadAll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: presetsDirectory, includingPropertiesForKeys: nil) else {
            presets = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        presets = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> DesignPreset? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(DesignPreset.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
