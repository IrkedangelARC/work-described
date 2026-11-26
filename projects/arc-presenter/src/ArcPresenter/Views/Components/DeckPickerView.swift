//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit

/// The picker's window while it is open, so the console's key monitor lets the picker's own keys
/// (up, down, Space, Return, Esc) reach it instead of turning them into slide changes.
@MainActor
enum DeckPickerFocus {
    static weak var window: NSWindow?
    /// Up, down, Space, Return, keypad Enter, Esc.
    static let keys: Set<UInt16> = [125, 126, 49, 36, 76, 53]
}

/// Every open deck, one row each, and which two sit in the header strip beside the pinned LIVE tab
/// (2026-09-23). Opened from the strip's "⌄ N" button.
struct DeckPickerView: View {
    @Environment(DeckManager.self) private var deckManager
    @Environment(\.dismiss) private var dismiss
    @State private var cursor: Int = 0
    @State private var hint: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("OPEN DECKS").font(ARCTheme.mono(11, .heavy)).tracking(1.4).foregroundStyle(ARCTheme.ink)
                Spacer()
                Text("SHOW IN STRIP: \(deckManager.stripPicks.picks.count) OF \(DeckStripPicks.slots)")
                    .font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.ink)
            }
            .padding(.horizontal, 10).frame(height: ARCTheme.moduleHeaderH)
            .background(ARCTheme.secBlue)

            VStack(spacing: 2) {
                ForEach(Array(deckManager.decks.enumerated()), id: \.element.id) { i, deck in
                    row(deck, index: i)
                }
            }
            .padding(6)

            Text(hint ?? "Arrows move, Space shows or hides in the strip, Return previews, Esc closes.")
                .font(ARCTheme.mono(10, .medium))
                .foregroundStyle(hint == nil ? ARCTheme.text2 : ARCTheme.warn)
                .lineLimit(2)
                .padding(.horizontal, 10).padding(.bottom, 8)
        }
        .frame(width: 600)
        .background(ARCTheme.moduleBg)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.space) { toggle(at: cursor); return .handled }
        .onKeyPress(.return) { preview(at: cursor); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .background(WindowGrabber { DeckPickerFocus.window = $0 })
        .onAppear {
            cursor = deckManager.decks.firstIndex { $0.id == deckManager.previewDeckID } ?? 0
            focused = true
        }
        .onDisappear { DeckPickerFocus.window = nil }
    }

    private func row(_ deck: Deck, index: Int) -> some View {
        let isLive = deck.id == deckManager.liveDeckID
        let isPreview = deck.id == deckManager.previewDeckID
        let picked = deckManager.isInStrip(deck)
        return HStack(spacing: 8) {
            if isLive {
                Text("LIVE PINNED").font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.arcRed)
                    .frame(width: 96, alignment: .leading)
            } else {
                Button { toggle(at: index) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: picked ? "checkmark.square.fill" : "square")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(picked ? ARCTheme.secBlue : ARCTheme.text1)
                        Text("STRIP").font(ARCTheme.mono(10, .heavy)).foregroundStyle(picked ? ARCTheme.text0 : ARCTheme.text2)
                    }
                    .frame(width: 96, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(picked ? "Take it out of the header strip" : "Show it in the header strip (two at most)")
            }

            Button { preview(at: index) } label: {
                Text(deck.shownName)
                    .font(ARCTheme.mono(13, .bold))
                    .foregroundStyle(ARCTheme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Preview \(deck.shownName)")

            Text(isLive ? "LIVE" : (isPreview ? "PREVIEW" : "\u{2014}"))
                .font(ARCTheme.mono(10, .heavy))
                .foregroundStyle(isLive ? .white : (isPreview ? ARCTheme.arcRed : ARCTheme.text2))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(isLive ? ARCTheme.arcRed : Color.clear))
                .frame(width: 70)

            Text("\(deckManager.effectiveIndex(of: deck) + 1) / \(deck.pageCount)")
                .font(ARCTheme.mono(11, .bold)).monospacedDigit()
                .foregroundStyle(ARCTheme.text1)
                .frame(width: 84, alignment: .trailing)

            // Same guard as the tab's x: never the live deck, never the last deck.
            if deckManager.hasMultipleDecks && !isLive {
                Button { deckManager.removeDeck(deckID: deck.id); cursor = min(cursor, max(0, deckManager.decks.count - 1)) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(ARCTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Close \(deck.shownName)")
            } else {
                Color.clear.frame(width: 15, height: 15)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(index == cursor ? ARCTheme.surfaceLight : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isPreview ? ARCTheme.arcRed : Color.clear, lineWidth: 1))
    }

    private func move(_ d: Int) {
        guard !deckManager.decks.isEmpty else { return }
        cursor = max(0, min(deckManager.decks.count - 1, cursor + d))
    }

    private func toggle(at i: Int) {
        guard deckManager.decks.indices.contains(i) else { return }
        let deck = deckManager.decks[i]
        switch deckManager.toggleStrip(deck.id) {
        case .full: hint = "Two decks are in the strip already. Uncheck one first."
        case .isLive: hint = "The LIVE deck is always in the strip, pinned."
        case .picked, .unpicked: hint = nil
        }
    }

    private func preview(at i: Int) {
        guard deckManager.decks.indices.contains(i) else { return }
        deckManager.previewDeckSwitch(to: deckManager.decks[i].id)
        dismiss()
    }
}

/// Hands the hosting NSWindow to a closure (the popover's window, here).
private struct WindowGrabber: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { found(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
