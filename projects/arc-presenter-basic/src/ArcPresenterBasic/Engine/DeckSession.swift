//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

enum SessionMode {
    case live
    case browse
}

@MainActor
@Observable
final class DeckSession {
    let liveEngine: SlideEngine
    let liveCache: PageCache
    private(set) var browseEngine: SlideEngine?
    private(set) var browseCache: PageCache?
    private(set) var mode: SessionMode = .live

    /// Render size for the page cache. Set by the operator UI from
    /// DisplayManager.renderTargetSize so caches pre-render at the actual
    /// output resolution.
    var renderTargetSize: CGSize = PageCache.maxRenderSize

    init(liveEngine: SlideEngine, liveCache: PageCache) {
        self.liveEngine = liveEngine
        self.liveCache = liveCache
    }

    convenience init() {
        self.init(liveEngine: SlideEngine(), liveCache: PageCache())
    }

    var hasBrowseDeck: Bool { browseEngine != nil }

    var activeEngine: SlideEngine {
        switch mode {
        case .live: return liveEngine
        case .browse: return browseEngine ?? liveEngine
        }
    }

    var activeCache: PageCache {
        switch mode {
        case .live: return liveCache
        case .browse: return browseCache ?? liveCache
        }
    }

    /// Open a PDF. If no live deck is loaded yet, it goes straight to live;
    /// otherwise it loads as a browse deck and switches the operator to BROWSE.
    @discardableResult
    func openPDF(url: URL) -> Bool {
        if !liveEngine.isLoaded {
            return loadLive(url: url)
        }
        return loadBrowse(url: url)
    }

    /// Promote the browse deck to live, dropping the current live deck.
    /// Operator returns to LIVE mode; output now shows the new deck at page 1.
    func sendBrowseToOutput() {
        guard let browseEngine, let browseCache else { return }
        guard let url = browseEngine.sourceURL else { return }

        liveEngine.unload()
        liveCache.clear()

        _ = liveEngine.loadPDF(url: url)
        liveCache.build(from: url, pageCount: liveEngine.pageCount, targetSize: renderTargetSize)

        browseEngine.unload()
        browseCache.clear()
        self.browseEngine = nil
        self.browseCache = nil
        self.mode = .live
    }

    func closeBrowse() {
        browseEngine?.unload()
        browseCache?.clear()
        browseEngine = nil
        browseCache = nil
        mode = .live
    }

    func switchToLive() { mode = .live }
    func switchToBrowse() { if hasBrowseDeck { mode = .browse } }

    func toggleMode() {
        guard hasBrowseDeck else { return }
        mode = (mode == .live) ? .browse : .live
    }

    func reset() {
        liveEngine.unload()
        liveCache.clear()
        closeBrowse()
    }

    // MARK: - Private

    private func loadLive(url: URL) -> Bool {
        guard liveEngine.loadPDF(url: url) else { return false }
        liveCache.build(from: url, pageCount: liveEngine.pageCount, targetSize: renderTargetSize)
        mode = .live
        return true
    }

    private func loadBrowse(url: URL) -> Bool {
        let engine = browseEngine ?? SlideEngine()
        let cache = browseCache ?? PageCache()
        guard engine.loadPDF(url: url) else { return false }
        cache.build(from: url, pageCount: engine.pageCount, targetSize: renderTargetSize)
        self.browseEngine = engine
        self.browseCache = cache
        self.mode = .browse
        return true
    }
}
