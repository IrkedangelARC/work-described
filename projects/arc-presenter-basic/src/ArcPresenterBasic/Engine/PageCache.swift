//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AppKit
import PDFKit
import os

@MainActor
@Observable
final class PageCache {
    /// Cap on resident page thumbnails. Scaled to physical RAM so an 8 GB Air
    /// doesn't try to hold a 4 GB cache. Smart eviction (farthest-from-current)
    /// keeps the active slide and its neighbors resident even when a deck
    /// exceeds this cap.
    static let maxCachedPages: Int = {
        let gb = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        switch gb {
        case ..<10:  return 200   // 8 GB Macs
        case ..<18:  return 400   // 16 GB Macs
        case ..<34:  return 800   // 32 GB Macs
        default:     return 1500  // 64 GB+ workstations
        }
    }()
    static let maxRenderSize = CGSize(width: 1920, height: 1080)
    private static let priorityPageCount = 10
    private static let workerCount = 4

    private(set) var images: [Int: NSImage] = [:]
    private(set) var isLoading: Bool = false
    private(set) var progress: Double = 0
    private(set) var loadError: String?
    private(set) var renderTargetSize: CGSize?

    /// Page the operator is currently viewing. Used by the eviction policy to
    /// keep nearby pages cached and evict the farthest-away ones first. Set by
    /// OperatorView via `.onChange(of: engine.currentIndex)`.
    var currentPageIndex: Int = 0

    private var renderTask: Task<Void, Never>?

    func imageFor(page index: Int) -> NSImage? {
        images[index]
    }

    func clear() {
        renderTask?.cancel()
        renderTask = nil
        images.removeAll()
        isLoading = false
        progress = 0
        loadError = nil
        renderTargetSize = nil
        currentPageIndex = 0
    }

    /// Pre-render all pages of a PDF. First `priorityPageCount` pages render
    /// sequentially for instant operator availability; the rest stream in
    /// parallel across `workerCount` worker tasks. Each worker opens its own
    /// PDFDocument copy from the URL since PDFKit isn't thread-safe.
    func build(from url: URL, pageCount: Int, targetSize: CGSize) {
        renderTask?.cancel()
        images.removeAll()
        loadError = nil
        renderTargetSize = targetSize
        isLoading = true
        progress = 0

        guard pageCount > 0 else {
            isLoading = false
            return
        }

        // Cap render at min(output target, 2× PDF native, hard ceiling). PDFs
        // are vector but rendering above 2× native gives diminishing returns in
        // sharpness while quadratically blowing up memory. On a 4K projector
        // showing an HD PDF, this saves 4× memory with no visible quality loss.
        let maxRender = Self.maxRenderSize
        var renderWidth = min(targetSize.width, maxRender.width)
        var renderHeight = min(targetSize.height, maxRender.height)
        if let probe = PDFDocument(url: url)?.page(at: 0) {
            let native = probe.bounds(for: .cropBox)
            renderWidth = min(renderWidth, native.width * 2)
            renderHeight = min(renderHeight, native.height * 2)
        }
        let size = CGSize(width: renderWidth, height: renderHeight)
        let maxPages = Self.maxCachedPages
        let priorityCount = min(Self.priorityPageCount, pageCount)
        let workers = Self.workerCount
        let count = pageCount

        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let primaryDoc = PDFDocument(url: url) else {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.loadError = "Failed to open PDF: \(url.lastPathComponent)"
                    self.isLoading = false
                }
                return
            }

            for i in 0..<priorityCount {
                guard !Task.isCancelled else { return }
                guard let page = primaryDoc.page(at: i) else { continue }
                let thumb = page.thumbnail(of: size, for: .cropBox)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.images[i] = thumb
                    self.progress = Double(i + 1) / Double(count)
                }
            }

            guard !Task.isCancelled else { return }
            guard priorityCount < count else {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isLoading = false
                    self.progress = 1.0
                }
                return
            }

            var workerDocs: [PDFDocument] = [primaryDoc]
            for _ in 1..<workers {
                if let copy = PDFDocument(url: url) {
                    workerDocs.append(copy)
                }
            }
            let actualWorkers = workerDocs.count
            let rendered = OSAllocatedUnfairLock(initialState: priorityCount)

            await withTaskGroup(of: Void.self) { group in
                for workerIndex in 0..<actualWorkers {
                    let doc = workerDocs[workerIndex]
                    group.addTask {
                        var i = priorityCount + workerIndex
                        while i < count {
                            guard !Task.isCancelled else { return }
                            guard let page = doc.page(at: i) else {
                                i += actualWorkers
                                continue
                            }
                            let thumb = page.thumbnail(of: size, for: .cropBox)
                            let pageIndex = i
                            let total = rendered.withLock { state -> Int in
                                state += 1
                                return state
                            }
                            await MainActor.run { [weak self] in
                                guard let self else { return }
                                self.images[pageIndex] = thumb
                                // Evict pages farthest from the operator's current
                                // view. This keeps the active slide and its
                                // neighbors resident even on decks larger than the
                                // cache cap.
                                while self.images.count > maxPages {
                                    let current = self.currentPageIndex
                                    if let farthest = self.images.keys.max(by: {
                                        abs($0 - current) < abs($1 - current)
                                    }), farthest != current {
                                        self.images.removeValue(forKey: farthest)
                                    } else {
                                        break
                                    }
                                }
                                self.progress = Double(total) / Double(count)
                            }
                            i += actualWorkers
                        }
                    }
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.progress = 1.0
                self.isLoading = false
            }
        }
    }
}
