//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Which decks sit in the header's tab strip (2026-09-23): the LIVE deck, pinned, plus TWO the
/// operator picks in the deck picker. Pure value type over deck KEYS (the standardized file path, the
/// same identity `DeckManager.addDeck` dedups on), so it survives a reload-in-place, which gives the
/// deck a new UUID, and round-trips through the session file.
///
/// The rules, all here so they are tested in one place:
/// - At most two picks, in pick order. The live deck is never a pick (it is pinned).
/// - Checking a third is REFUSED (`.full`) with a hint in the picker; nothing is unchecked behind the
///   operator's back.
/// - A newly opened deck becomes a pick when a slot is free.
/// - The PREVIEWED deck is always in the strip: if it is neither live nor a pick it shows as one extra
///   tab after the picks, until the preview moves on. Derived, so no state to go stale.
/// - A TAKE of a pick: the new live deck leaves the picks and the old live deck takes its slot, so the
///   strip keeps the same decks, one of them now pinned.
/// - A closed deck leaves the picks.
struct DeckStripPicks: Codable, Equatable {
    static let slots = 2

    private(set) var picks: [String] = []

    enum ToggleResult: Equatable { case picked, unpicked, full, isLive }

    init(picks: [String] = []) { self.picks = Array(picks.prefix(Self.slots)) }

    func isPicked(_ key: String) -> Bool { picks.contains(key) }

    @discardableResult
    mutating func toggle(_ key: String, live: String?) -> ToggleResult {
        if key == live { return .isLive }
        if let i = picks.firstIndex(of: key) { picks.remove(at: i); return .unpicked }
        guard picks.count < Self.slots else { return .full }
        picks.append(key)
        return .picked
    }

    mutating func opened(_ key: String, live: String?) {
        guard key != live, !picks.contains(key), picks.count < Self.slots else { return }
        picks.append(key)
    }

    mutating func closed(_ key: String) { picks.removeAll { $0 == key } }

    mutating func liveChanged(from old: String?, to new: String?) {
        guard old != new, let new, let i = picks.firstIndex(of: new) else { return }
        if let old, !picks.contains(old) { picks[i] = old } else { picks.remove(at: i) }
    }

    /// Replace the picks (session restore, the control API), keeping only open, non-live decks.
    mutating func set(_ keys: [String], open: [String], live: String?) {
        var out: [String] = []
        for k in keys where k != live && open.contains(k) && !out.contains(k) && out.count < Self.slots { out.append(k) }
        picks = out
    }

    /// The strip after the pinned live tab: the picks still open, then the previewed deck if it is
    /// neither live nor picked.
    func strip(open: [String], live: String?, preview: String?) -> [String] {
        var out = picks.filter { open.contains($0) && $0 != live }
        if let preview, preview != live, open.contains(preview), !out.contains(preview) { out.append(preview) }
        return out
    }
}
