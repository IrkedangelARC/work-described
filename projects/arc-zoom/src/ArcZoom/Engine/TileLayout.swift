//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import CoreGraphics

/// Where the tiles go. Pure, so it is tested rather than eyeballed: the one thing in this app that can
/// be wrong in a way nobody notices until a show. Top-left origin, the space CALayer sublayers use
/// once the host view is flipped.
enum TileLayout {
    /// One tile filling `bounds` at `aspect`, letterboxed and centred. The PROGRAM layout.
    static func fill(_ bounds: CGRect, aspect: CGFloat) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, aspect > 0 else { return .zero }
        let w = min(bounds.width, bounds.height * aspect)
        let h = w / aspect
        return CGRect(x: (bounds.minX + (bounds.width - w) / 2).rounded(),
                      y: (bounds.minY + (bounds.height - h) / 2).rounded(),
                      width: w.rounded(), height: h.rounded())
    }

    /// The grid that makes `count` tiles of `aspect` as LARGE as possible inside `bounds`. Rows are
    /// centred, so a last row with fewer tiles sits under the middle of the one above (Zoom's own
    /// gallery does the same and the room expects it).
    static func grid(count: Int, in bounds: CGRect, aspect: CGFloat, gap: CGFloat = 8) -> [CGRect] {
        guard count > 0, bounds.width > 0, bounds.height > 0, aspect > 0 else { return [] }
        var best: (cols: Int, rows: Int, w: CGFloat, h: CGFloat) = (1, count, 0, 0)
        for cols in 1...count {
            let rows = Int((Double(count) / Double(cols)).rounded(.up))
            let cellW = (bounds.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
            let cellH = (bounds.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
            guard cellW > 1, cellH > 1 else { continue }
            let w = min(cellW, cellH * aspect)
            let h = w / aspect
            if w * h > best.w * best.h { best = (cols, rows, w, h) }
        }
        guard best.w > 0 else { return [] }
        return place(count: count, cols: best.cols, rows: best.rows,
                     tile: CGSize(width: best.w, height: best.h), in: bounds, gap: gap)
    }

    /// One centred row: the STRIP layout, the band ARC Presenter puts across the top of its program.
    static func strip(count: Int, in bounds: CGRect, aspect: CGFloat, gap: CGFloat = 8) -> [CGRect] {
        guard count > 0, bounds.width > 0, bounds.height > 0, aspect > 0 else { return [] }
        let cellW = (bounds.width - gap * CGFloat(count + 1)) / CGFloat(count)
        let cellH = bounds.height - gap * 2
        guard cellW > 1, cellH > 1 else { return [] }
        let w = min(cellW, cellH * aspect)
        return place(count: count, cols: count, rows: 1,
                     tile: CGSize(width: w, height: w / aspect), in: bounds, gap: gap)
    }

    /// Rows of `cols`, each row centred horizontally, the block centred vertically.
    private static func place(count: Int, cols: Int, rows: Int, tile: CGSize, in bounds: CGRect, gap: CGFloat) -> [CGRect] {
        let blockH = CGFloat(rows) * tile.height + CGFloat(rows - 1) * gap
        let top = bounds.minY + (bounds.height - blockH) / 2
        var out: [CGRect] = []
        out.reserveCapacity(count)
        for row in 0..<rows {
            let first = row * cols
            let n = min(cols, count - first)
            guard n > 0 else { break }
            let rowW = CGFloat(n) * tile.width + CGFloat(n - 1) * gap
            let left = bounds.minX + (bounds.width - rowW) / 2
            for i in 0..<n {
                out.append(CGRect(x: (left + CGFloat(i) * (tile.width + gap)).rounded(),
                                  y: (top + CGFloat(row) * (tile.height + gap)).rounded(),
                                  width: tile.width.rounded(), height: tile.height.rounded()))
            }
        }
        return out
    }
}
