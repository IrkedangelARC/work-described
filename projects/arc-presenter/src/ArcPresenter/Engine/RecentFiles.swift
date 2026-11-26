//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

@MainActor
@Observable
final class RecentFiles {
    private static let key = "recentPDFPaths"
    private static let maxCount = 5

    private(set) var paths: [URL] = []

    init() {
        load()
    }

    func add(_ url: URL) {
        paths.removeAll { $0 == url }
        paths.insert(url, at: 0)
        if paths.count > Self.maxCount {
            paths = Array(paths.prefix(Self.maxCount))
        }
        save()
    }

    func clear() {
        paths.removeAll()
        save()
    }

    private func load() {
        guard let bookmarks = UserDefaults.standard.array(forKey: Self.key) as? [Data] else { return }
        var hadStale = false
        paths = bookmarks.compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                return nil
            }
            if stale { hadStale = true }
            return url
        }
        if hadStale { save() }
    }

    private func save() {
        let bookmarks = paths.compactMap { url in
            try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarks, forKey: Self.key)
    }
}
