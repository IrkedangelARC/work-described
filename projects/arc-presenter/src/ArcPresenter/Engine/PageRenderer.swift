//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import SwiftUI
import PDFKit
import Observation

/// Pre-rendered program pages (stability plan 2.5). PDFKit's `PDFView.go(to:)`
/// drew every page synchronously on the main thread at navigation time, a
/// per-slide hitch on dense vector pages (audit R8). This renders the current
/// page and its neighbours at the output's pixel size on a serial background
/// queue, from a private copy of the document (PDFKit is not thread-safe
/// across a shared document), and hands the output view a CGImage: a slide
/// change becomes a layer swap. A page not rendered yet is drawn once on the
/// main thread so nothing ever shows black.
@MainActor
@Observable
final class PageRenderCache {
    struct Key: Hashable {
        let document: ObjectIdentifier
        let page: Int
        let width: Int
        let height: Int
    }

    static let maxImages = 4
    static let prefetchOffsets = [0, 1, -1, 2]

    /// Bumps when a background render lands, so views re-read.
    private(set) var version = 0
    @ObservationIgnored private var images: [Key: CGImage] = [:]
    @ObservationIgnored private var order: [Key] = []
    @ObservationIgnored private var inFlight: Set<Key> = []
    @ObservationIgnored private var renderedCount = 0
    var stats: (cached: Int, rendered: Int) { (images.count, renderedCount) }

    // Background side: one document copy per URL, used only on `queue`.
    @ObservationIgnored private let queue = DispatchQueue(label: "arc.presenter.pagerender", qos: .userInteractive)
    @ObservationIgnored private var backgroundDocuments: [URL: PDFDocument] = [:]   // queue-only

    static func key(_ document: PDFDocument, _ page: Int, _ size: CGSize) -> Key {
        Key(document: ObjectIdentifier(document), page: page, width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    /// The cached image, or nil (a prefetch is started either way).
    func image(for document: PDFDocument, page: Int, pixelSize: CGSize) -> CGImage? {
        _ = version
        prefetch(document: document, around: page, pixelSize: pixelSize)
        return images[Self.key(document, page, pixelSize)]
    }

    /// Cache lookup only; starts nothing (tests, telemetry).
    func cached(_ document: PDFDocument, page: Int, pixelSize: CGSize) -> CGImage? {
        _ = version
        return images[Self.key(document, page, pixelSize)]
    }

    /// Render on the main thread now, from the live document (first show of a
    /// page, or a document with no URL). Cached like a background render.
    func renderNow(document: PDFDocument, page: Int, pixelSize: CGSize) -> CGImage? {
        let key = Self.key(document, page, pixelSize)
        if let img = images[key] { return img }
        guard let pdfPage = document.page(at: page), let img = Self.render(pdfPage, pixelSize: pixelSize) else { return nil }
        store(img, for: key)
        return img
    }

    func prefetch(document: PDFDocument, around page: Int, pixelSize: CGSize) {
        guard pixelSize.width >= 1, pixelSize.height >= 1, let url = document.documentURL else { return }
        for offset in Self.prefetchOffsets {
            let p = page + offset
            guard p >= 0, p < document.pageCount else { continue }
            let key = Self.key(document, p, pixelSize)
            guard images[key] == nil, !inFlight.contains(key) else { continue }
            inFlight.insert(key)
            queue.async { [weak self] in
                guard let self else { return }
                let doc: PDFDocument?
                if let cached = self.backgroundDocuments[url] { doc = cached }
                else { doc = PDFDocument(url: url); if let doc { self.backgroundDocuments[url] = doc } }
                let img = doc?.page(at: p).flatMap { Self.render($0, pixelSize: pixelSize) }
                Task { @MainActor in
                    self.inFlight.remove(key)
                    if let img { self.store(img, for: key); self.version += 1 }
                }
            }
        }
    }

    private func store(_ image: CGImage, for key: Key) {
        if images[key] == nil { order.append(key) }
        images[key] = image
        renderedCount += 1
        while images.count > Self.maxImages, let oldest = order.first {
            order.removeFirst()
            images.removeValue(forKey: oldest)
        }
    }

    /// Aspect-fit the page's crop box into a black bitmap of `pixelSize`.
    nonisolated static func render(_ page: PDFPage, pixelSize: CGSize) -> CGImage? {
        let w = Int(pixelSize.width.rounded()), h = Int(pixelSize.height.rounded())
        guard w > 0, h > 0 else { return nil }
        let box = page.bounds(for: .cropBox)
        let rotation = page.rotation % 360
        let rotated = rotation == 90 || rotation == 270
        let pageW = rotated ? box.height : box.width
        let pageH = rotated ? box.width : box.height
        guard pageW > 0, pageH > 0 else { return nil }
        let scale = min(CGFloat(w) / pageW, CGFloat(h) / pageH)
        let drawW = pageW * scale, drawH = pageH * scale
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.saveGState()
        ctx.translateBy(x: (CGFloat(w) - drawW) / 2, y: (CGFloat(h) - drawH) / 2)
        ctx.scaleBy(x: scale, y: scale)
        // Rotate into the page's displayed orientation, then draw the crop box at the origin.
        switch rotation {
        case 90:  ctx.translateBy(x: box.height, y: 0); ctx.rotate(by: .pi / 2)
        case 180: ctx.translateBy(x: box.width, y: box.height); ctx.rotate(by: .pi)
        case 270: ctx.translateBy(x: 0, y: box.width); ctx.rotate(by: -.pi / 2)
        default: break
        }
        ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .cropBox, to: ctx)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

/// Shows one page from a PageRenderCache in a layer; asks for the current
/// page at its own pixel size and re-reads when a render lands.
struct RenderedPageView: NSViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    let cache: PageRenderCache

    func makeNSView(context: Context) -> PageLayerView {
        let v = PageLayerView()
        v.apply(document: document, page: pageIndex, cache: cache)
        return v
    }

    func updateNSView(_ view: PageLayerView, context: Context) {
        view.apply(document: document, page: pageIndex, cache: cache)
    }
}

final class PageLayerView: NSView {
    private var document: PDFDocument?
    private var pageIndex = 0
    private var cache: PageRenderCache?
    private var shownKey: PageRenderCache.Key?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(document: PDFDocument, page: Int, cache: PageRenderCache) {
        self.document = document
        self.pageIndex = page
        self.cache = cache
        refresh()
    }

    override func layout() {
        super.layout()
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    private var pixelSize: CGSize {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    /// The render for a size the view was just given, held until the size stops changing.
    private var pendingRender: DispatchWorkItem?

    func refresh() {
        guard let document, let cache, pixelSize.width >= 1, pixelSize.height >= 1 else { return }
        let size = pixelSize
        let key = PageRenderCache.key(document, pageIndex, size)
        // Re-read when a background render for this document lands.
        withObservationTracking {
            _ = cache.version
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        if let img = cache.cached(document, page: pageIndex, pixelSize: size) {
            pendingRender?.cancel(); pendingRender = nil
            if shownKey != key { layer?.contents = img; shownKey = key }
            cache.prefetch(document: document, around: pageIndex, pixelSize: size)
            return
        }
        // Not rendered at this size. If this page is already on the layer, keep it (the layer scales it)
        // and render the new size in the background once the size settles: rendering here, on the main
        // thread, at every tick of a grip drag on the confidence monitor stalled the app for up to 3 s
        // (sampled 2026-09-19: PDFPage.draw under NSHostingView.layout). Only a page not shown at all
        // is drawn now, so nothing ever shows black.
        let samePageShown = shownKey.map { $0.document == key.document && $0.page == key.page } ?? false
        if samePageShown {
            pendingRender?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pixelSize == size else { return }   // the size moved on; the newer item has it
                cache.prefetch(document: document, around: self.pageIndex, pixelSize: size)
            }
            pendingRender = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else if let img = cache.image(for: document, page: pageIndex, pixelSize: size) ?? cache.renderNow(document: document, page: pageIndex, pixelSize: size) {
            layer?.contents = img; shownKey = key
        }
    }
}
