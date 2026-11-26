//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import PDFKit
import AVFoundation

@MainActor
@Observable
final class SlideEngine {
    /// Called after any index change. DeckManager wires this to its playback
    /// reconciler — the engine must NOT pause players itself: preview and live
    /// engines share the same AVPlayer objects, so an engine-local pause can
    /// kill live program audio when the operator navigates preview.
    var onNavigate: (() -> Void)?

    private(set) var currentIndex: Int = 0 {
        didSet {
            if oldValue != currentIndex { onNavigate?() }
        }
    }
    private(set) var pageCount: Int = 0
    private(set) var isLoaded: Bool = false
    private(set) var isBlack: Bool = false
    private(set) var pdfDocument: PDFDocument?
    private(set) var fileName: String = ""
    private(set) var isVideo: Bool = false
    private(set) var activePlayer: AVPlayer?

    /// Per-slide video players for arcdeck (0-based page index -> AVPlayer)
    private(set) var slideVideoPlayers: [Int: AVPlayer] = [:]
    /// True when this engine is displaying an arcdeck
    private(set) var isArcDeck: Bool = false
    /// Live engine only: DeckManager decides which clip (if any) the output
    /// shows, so a build recorded in the NEXT page's clip can play while the
    /// slide number stays put, and a backward step shows the page still.
    var managesPresentation: Bool = false
    private(set) var presentedClip: AVPlayer?
    func present(clip: AVPlayer?) { presentedClip = clip }
    /// A build STATE of the current page, drawn over the page and under the
    /// clip (manifest version 3): what a back-step cuts to, and what stands
    /// under a build clip while it readies. nil = the page itself, which is
    /// the slide's final state.
    private(set) var stateStill: NSImage?
    func present(still: NSImage?) { if stateStill !== still { stateStill = still } }
    /// The clip most likely shown next (DeckManager's choice); the output
    /// pre-arms it so the swap paints no black.
    var prefetchClip: AVPlayer?
    /// Speaker notes for the loaded deck, 1-based page -> text.
    private(set) var notes: [Int: String] = [:]

    var hasNotes: Bool { !notes.isEmpty }
    var currentNote: String? { notes[currentPage] }

    /// Whether the current page has a video clip (arcdeck per-slide check)
    var currentPageIsVideo: Bool {
        if isArcDeck { return managesPresentation ? presentedClip != nil : slideVideoPlayers[currentIndex] != nil }
        return isVideo
    }

    /// The active player for the current page (per-slide for arcdeck, single for video decks)
    var currentPlayer: AVPlayer? {
        if isArcDeck { return managesPresentation ? presentedClip : slideVideoPlayers[currentIndex] }
        return activePlayer
    }

    /// The clip on the page after the current one (arcdeck only). The output
    /// pre-arms it so a forward click never paints black.
    var nextPlayer: AVPlayer? {
        guard isArcDeck else { return nil }
        return managesPresentation ? prefetchClip : slideVideoPlayers[currentIndex + 1]
    }

    var jumpText: String = ""

    // MARK: - Computed

    var currentPage: Int { currentIndex + 1 }
    var hasNext: Bool { (isArcDeck || !isVideo) && currentIndex < pageCount - 1 }
    var hasPrevious: Bool { (isArcDeck || !isVideo) && currentIndex > 0 }
    var displayLabel: String {
        isVideo && !isArcDeck ? fileName : "\(currentPage) / \(pageCount)"
    }

    // MARK: - Loading

    func loadPDF(url: URL) {
        guard let document = PDFDocument(url: url) else { return }
        pdfDocument = document
        pageCount = document.pageCount
        currentIndex = 0
        isBlack = false
        isLoaded = true
        isVideo = false
        activePlayer = nil
        fileName = url.lastPathComponent
        jumpText = ""
    }

    func loadFromDeck(
        document: PDFDocument?,
        index: Int,
        pageCount: Int,
        isBlack: Bool,
        fileName: String,
        jumpText: String,
        isVideo: Bool = false,
        player: AVPlayer? = nil,
        isArcDeck: Bool = false,
        slideVideoPlayers: [Int: AVPlayer] = [:],
        notes: [Int: String] = [:]
    ) {
        self.notes = notes
        self.pdfDocument = document
        self.pageCount = pageCount
        // Clamp: a session-restored or reloaded-in-place deck can carry an
        // index from a previous, longer version of the same file.
        self.currentIndex = Self.clampedIndex(index, pageCount: pageCount)
        self.isBlack = isBlack
        self.isLoaded = true
        self.fileName = fileName
        self.jumpText = jumpText
        self.isVideo = isVideo
        self.activePlayer = player
        self.isArcDeck = isArcDeck
        self.slideVideoPlayers = slideVideoPlayers
    }

    /// 0-based index kept inside [0, pageCount-1]; 0 for an empty deck.
    nonisolated static func clampedIndex(_ index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(0, index), pageCount - 1)
    }

    func unload() {
        // Stop playback before dropping references — a still-playing AVPlayer
        // retained by an output view keeps sounding after unload otherwise.
        activePlayer?.pause()
        slideVideoPlayers.values.forEach { $0.pause() }
        presentedClip = nil
        prefetchClip = nil
        stateStill = nil
        pdfDocument = nil
        pageCount = 0
        currentIndex = 0
        isBlack = false
        isLoaded = false
        isVideo = false
        activePlayer = nil
        isArcDeck = false
        slideVideoPlayers = [:]
        notes = [:]
        fileName = ""
        jumpText = ""
    }

    // MARK: - Navigation

    func next() {
        guard hasNext else { return }
        currentIndex += 1
        isBlack = false
    }

    func previous() {
        guard hasPrevious else { return }
        currentIndex -= 1
        isBlack = false
    }

    func jumpTo(page: Int) {
        guard pageCount > 0 else { return }
        let clamped = max(1, min(page, pageCount))
        currentIndex = clamped - 1
        isBlack = false
    }

    func goToFirst() {
        currentIndex = 0
        isBlack = false
    }

    func goToLast() {
        guard pageCount > 0 else { return }
        currentIndex = pageCount - 1
        isBlack = false
    }

    func toggleBlack() {
        isBlack.toggle()
        // Black = kill program output, including any playing clip's audio.
        if isBlack { slideVideoPlayers[currentIndex]?.pause(); presentedClip?.pause() }
    }

    func commitJump() {
        guard let page = Int(jumpText) else {
            jumpText = ""
            return
        }
        jumpTo(page: page)
        jumpText = ""
    }
}
