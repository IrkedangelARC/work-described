//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Where a page of one version of a deck sits in the next (V5 step 5, design
/// 4.3). The ledger in show.json keeps one hash per SOURCE slide per version
/// (ARC Capture's SlideHasher, show order); an arcdeck page names its source
/// slide in the manifest (`pptxSlide`), because hidden slides have a hash and
/// no page. So a page goes page -> source slide -> the same slide in the new
/// version -> its page. Pure, so the rules are tested without a deck.
enum VersionMatch {
    enum Basis: String, Equatable {
        /// The slide's hash is in both versions: the same slide, wherever it moved.
        case exact
        /// The slide itself changed or went; placed from its nearest unchanged neighbour.
        case neighbour
        /// No usable ledger: the same page number.
        case index
    }

    struct Result: Equatable {
        /// 0-based page in the new version.
        let page: Int
        let basis: Basis
        var label: String {
            switch basis {
            case .exact: return "slide \(page + 1), same slide by hash"
            case .neighbour: return "slide \(page + 1), placed from its neighbours: CHECK before TAKE"
            case .index: return "slide \(page + 1), same number (no slide hashes): CHECK before TAKE"
            }
        }
    }

    /// - Parameters:
    ///   - page: 0-based page in the old version.
    ///   - oldSlides / newSlides: 1-based source slide per page; empty means page n is slide n.
    ///   - newPageCount: pages in the new version (the clamp).
    static func match(page: Int, oldHashes: [String]?, newHashes: [String]?,
                      oldSlides: [Int] = [], newSlides: [Int] = [], newPageCount: Int) -> Result {
        let last = max(0, newPageCount - 1)
        let sameIndex = Result(page: min(max(0, page), last), basis: .index)
        guard let old = oldHashes, let new = newHashes, !old.isEmpty, !new.isEmpty else { return sameIndex }
        let oi = (page < oldSlides.count ? oldSlides[page] : page + 1) - 1
        guard old.indices.contains(oi) else { return sameIndex }

        // Align the two ledgers. What the diff neither removes nor inserts is
        // unchanged and pairs up in order, so slides inserted ahead of the
        // current one shift it correctly.
        let diff = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        let keptOld = old.indices.filter { !removed.contains($0) }
        let keptNew = new.indices.filter { !inserted.contains($0) }
        guard keptOld.count == keptNew.count else { return sameIndex }
        let pair = Dictionary(uniqueKeysWithValues: zip(keptOld, keptNew))

        var target: Int
        var basis = Basis.exact
        if let ni = pair[oi] {
            target = ni
        } else if let moved = inserted.filter({ new[$0] == old[oi] }).min(by: { abs($0 - oi) < abs($1 - oi) }) {
            // The same slide, moved: the diff reads a move as remove + insert.
            target = moved
        } else if let before = keptOld.last(where: { $0 < oi }), let nb = pair[before] {
            // Edited in place: it is what follows its unchanged predecessor.
            target = min(nb + 1, new.count - 1); basis = .neighbour
        } else if let after = keptOld.first(where: { $0 > oi }), let na = pair[after] {
            target = max(na - 1, 0); basis = .neighbour
        } else {
            return sameIndex
        }

        // Source slide -> page. A hidden slide has no page: the next one that does.
        let wanted = target + 1
        if newSlides.isEmpty { return Result(page: min(target, last), basis: basis) }
        if let p = newSlides.firstIndex(of: wanted) { return Result(page: min(p, last), basis: basis) }
        let p = newSlides.firstIndex(where: { $0 > wanted }) ?? last
        return Result(page: min(p, last), basis: .neighbour)
    }
}
