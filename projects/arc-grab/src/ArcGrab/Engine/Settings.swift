//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Persisted preferences: the last-used options and the queue concurrency.
@Observable @MainActor
final class Settings {
    private static let optionsKey = "grab.options"
    private static let concurrencyKey = "grab.concurrency"

    var options: GrabOptions { didSet { save() } }
    var concurrency: Int { didSet { UserDefaults.standard.set(concurrency, forKey: Settings.concurrencyKey) } }

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Settings.optionsKey),
           let o = try? JSONDecoder().decode(GrabOptions.self, from: data) {
            var isDir: ObjCBool = false
            let parent = (o.destination as NSString).deletingLastPathComponent
            var fixed = o
            if !(FileManager.default.fileExists(atPath: parent, isDirectory: &isDir) && isDir.boolValue) {
                fixed.destination = GrabOptions.defaultDestination
            }
            fixed.videoPassword = ""
            options = fixed
        } else {
            options = GrabOptions()
        }
        let c = d.integer(forKey: Settings.concurrencyKey)
        concurrency = (1...3).contains(c) ? c : 1
    }

    /// The PASSWORD field is per job and never written to disk (UserDefaults is a plaintext plist).
    private func save() {
        var o = options
        o.videoPassword = ""
        if let data = try? JSONEncoder().encode(o) {
            UserDefaults.standard.set(data, forKey: Settings.optionsKey)
        }
    }
}
