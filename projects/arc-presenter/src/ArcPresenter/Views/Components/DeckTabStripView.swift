//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import UniformTypeIdentifiers

struct DeckTabStripView: View {
    @Environment(DeckManager.self) private var deckManager
    @Environment(DisplayManager.self) private var displayManager
    @Environment(RecentFiles.self) private var recentFiles
    @Environment(ShowFolderSession.self) private var show

    private static let videoTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .avi]

    var body: some View {
        let liveID = deckManager.liveDeckID
        let pinned = deckManager.decks.first { $0.id == liveID }
        HStack(spacing: 4) {
            // The LIVE deck's tab is pinned at the leading edge, outside the scroll, so its LIVE badge is
            // always in view whatever the strip has scrolled to (2026-09-23). Live AND previewed:
            // shown once, here. No live deck: nothing pinned.
            if let pinned {
                // Capped too: a long live deck name ("Demo 1-7 and 1-8 Drive Test") took ~300 pt and set the
                // window's minimum; the LIVE badge and the x keep their size, the name truncates.
                CappedWidth(cap: ARCTheme.pinnedTabMaxW) { deckTab(deck: pinned) }
            }
            // The other tabs at their natural width in a strip that scrolls; ten decks
            // used to squeeze every tab to "1…" (2026-09-16).
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // The two decks the operator picked (deck picker, "⌄ N"), then the previewed deck if it
                    // is not one of them: never hidden (DeckStripPicks has the rules). FitTabs shares the
                    // strip's width among them, longest names giving first; each gives NAME, never its x.
                    FitTabs(width: stripW, spacing: 4) {
                        ForEach(deckManager.stripDecks) { deck in
                            deckTab(deck: deck).id(deck.id)
                        }
                    }
                }
                .onChange(of: deckManager.previewDeckID) { _, id in if let id, id != deckManager.liveDeckID { withAnimation { proxy.scrollTo(id, anchor: .leading) } } }
                .onAppear { if let id = deckManager.previewDeckID, id != liveID { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .leading) } } }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripW = $0 }
            }
            // The header's first give (2026-09-23): the other tabs scroll down to a sliver (60 pt), never to nothing: the LIVE tab beside them is whole.
            .frame(minWidth: 60)
            .padding(.trailing, 6)   // a gap before +: the strip's edge never meets the button
            if deckManager.decks.count >= 2 { pickerButton }
            addButton
            folderButton
            // The clock moved to the header bar itself with OUTPUTS and STATUS (2026-09-23).
        }
    }

    @State private var showPicker = false

    /// The scrolling strip's visible width, which caps each tab in it.
    @State private var stripW: CGFloat = 10_000

    private func deckTab(deck: Deck) -> some View {
        let isPreview = deck.id == deckManager.previewDeckID
        let isLive = deck.id == deckManager.liveDeckID

        return HStack(spacing: 4) {
            if isLive {
                Text("LIVE")
                    .font(ARCTheme.mono(11, .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.22)))
            }

            if deck.isVideo {
                Image(systemName: "film")
                    .font(.system(size: 11))
                    .foregroundStyle(isPreview ? ARCTheme.accent : ARCTheme.textSecondary)
            }

            if deck.loadError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if !deck.clipErrors.isEmpty {
                Image(systemName: "film.stack")
                    .font(.system(size: 11))
                    .foregroundStyle(ARCTheme.warn)
                    .help(deck.clipErrors.sorted { $0.key < $1.key }.map { "slide \($0.key + 1): \($0.value)" }.joined(separator: "\n"))
            } else if deck.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.8)
                Text("\(Int(deck.progress * Double(deck.pageCount)))/\(deck.pageCount)")
                    .font(ARCTheme.mono(11, .medium))
                    .foregroundStyle(ARCTheme.textSecondary)
            }

            Text(shortName(deck.shownName))
                .font(ARCTheme.mono(15, .bold))
                .foregroundStyle(isLive ? .white : ARCTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)   // tail: shortName already ends long names in "...", a middle cut doubled it
                .layoutPriority(-1)   // the name is what gives when the tab is capped; badges and the x keep their size

            // A deck Capture stopped early is sound but is NOT the whole show. It must never look
            // whole on the strip: an operator reading only the page count would have no other clue.
            // Amber, not red, because red on this console means LIVE.
            if deck.isShortDeck {
                Text("SHORT")
                    .font(ARCTheme.mono(10, .heavy))
                    .foregroundStyle(ARCTheme.ink)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(ARCTheme.warn))
                    .help("Short deck: capture was stopped early with STOP AND KEEP. These \(deck.pageCount) pages verified, but they are not the whole show.")
            }

            // Show-folder marker (V5): a newer verified version, a staged
            // twin, a version on its way out, a source that changed, or a
            // failed capture, from show.json.
            if let (st, role) = show.role(for: deck) { showMarker(st, role: role, deck: deck, isLive: isLive) }

            if deckManager.hasMultipleDecks && !isLive {
                Button {
                    deckManager.removeDeck(deckID: deck.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ARCTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        // PTZ tab language: the LIVE deck is a solid ARC-red chip, the
        // previewed deck a panel chip with a red border, the rest grey.
        .padding(.horizontal, 10)   // 14 until the three-tab strip (2026-09-23)
        .padding(.vertical, 8)
        .background(isLive ? ARCTheme.arcRed : (isPreview ? ARCTheme.panel : ARCTheme.appGrey))
        .overlay(
            RoundedRectangle(cornerRadius: ARCTheme.cornerRadius)
                .strokeBorder(isLive ? ARCTheme.arcRed : (isPreview ? ARCTheme.arcRed : ARCTheme.line), lineWidth: isPreview && !isLive ? 2 : 1)
        )
        .cornerRadius(ARCTheme.cornerRadius)
        .onTapGesture {
            deckManager.previewDeckSwitch(to: deck.id)
        }
        .help(isLive ? "\(deck.shownName) (LIVE)" : "Click to preview \(deck.shownName)")
    }

    private func chip(_ text: String, fill: Color) -> some View {
        Text(text)
            .font(ARCTheme.mono(10, .heavy))
            .foregroundStyle(ARCTheme.ink)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(fill))
    }

    @ViewBuilder
    private func showMarker(_ st: ShowFolderSession.ItemState, role: ShowFolderSession.TabRole, deck: Deck, isLive: Bool) -> some View {
        switch role {
        case .staged:
            let match = show.matches[deck.id]
            chip("v\(st.stagedVersion ?? 0) STAGED", fill: match?.basis == .exact ? ARCTheme.readyGreen : ARCTheme.warn)
                .help("The new version, in preview at \(match?.label ?? "its matched slide"). TAKE at a slide boundary: the room sees a cut.")
        case .retiring:
            chip("RETIRING", fill: ARCTheme.textSecondary)
                .help("The previous version. It closes by itself; TAKE it to go back.")
        case .primary:
            if st.newerVersionDownloading {
                chip("v\(st.currentVersion ?? 0) DOWNLOADING \(st.localFiles)/\(st.totalFiles)", fill: ARCTheme.textSecondary)
                    .help("A newer version is captured and verified, but its files are still arriving on this Mac (iCloud). It reads READY, and STAGE works, once every file is here.")
            } else if st.newerVersionReady {
                // Click = the safe one: STAGE when live, swap in place when
                // not. Option-click on the live deck = SWAP (stage and take).
                Button {
                    let take = isLive && NSEvent.modifierFlags.contains(.option)
                    Task { await show.update(itemID: st.id, take: take) }
                } label: { chip("v\(st.currentVersion ?? 0) READY", fill: ARCTheme.warn) }
                .buttonStyle(.plain)
                .help(isLive
                      ? "A newer version is captured and verified. Click = STAGE: it opens beside this deck, in preview, on the matching slide (⌘⇧U). Option-click = SWAP: stage and take at once (⌘⌥⇧U)."
                      : "A newer version is captured and verified. Click to swap it in on the matching slide.")
            } else if st.status == .updated {
                Circle().fill(ARCTheme.warn).frame(width: 8, height: 8).help("The source changed after this capture; ARC Capture has not recaptured it yet")
            } else if st.status == .failed {
                Circle().fill(ARCTheme.liveRed).frame(width: 8, height: 8).help(st.note ?? "the last capture failed")
            }
        }
    }

    /// "⌄ N": every open deck, and which two sit in the strip.
    private var pickerButton: some View {
        Button { showPicker.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .heavy))
                Text("\(deckManager.decks.count)").font(ARCTheme.mono(13, .heavy)).monospacedDigit()
            }
            .foregroundStyle(showPicker ? ARCTheme.ink : ARCTheme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(showPicker ? ARCTheme.secBlue : ARCTheme.appGrey)
            .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(ARCTheme.line, lineWidth: 1))
            .cornerRadius(ARCTheme.cornerRadius)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("All \(deckManager.decks.count) open decks: choose the two shown in the strip, preview or close any")
        .popover(isPresented: $showPicker, arrowEdge: .bottom) { DeckPickerView() }
        .onReceive(NotificationCenter.default.publisher(for: .deckPicker)) { note in
            showPicker = (note.object as? Bool) ?? !showPicker
        }
    }

    private var addButton: some View {
        Button {
            openFileDialog()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(ARCTheme.textSecondary)
                .frame(width: 36, height: 36)
                .background(ARCTheme.appGrey)
                .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(ARCTheme.line, lineWidth: 1))
                .cornerRadius(ARCTheme.cornerRadius)
        }
        .buttonStyle(.plain)
        .help("Add PDF deck or video file (Cmd+O)")
    }

    /// OPEN SHOW (V5): a show folder from ARC Capture. Replaces the button
    /// that launched the retired Assimilator.
    private var folderButton: some View {
        Button {
            NotificationCenter.default.post(name: .openShowFolder, object: nil)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: show.isOpen ? "folder.fill" : "folder")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(show.isOpen ? ARCTheme.readyGreen : ARCTheme.accent)
                if show.isOpen, !show.attention.isEmpty {
                    // Compact: "2 NEW" / "1 CAPTURE" / "1 FAILED"; the full line is the tooltip.
                    Text(show.shortAttention).font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.ink)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 3).fill(ARCTheme.warn))
                }
            }
            .padding(.horizontal, show.isOpen && !show.attention.isEmpty ? 8 : 0)
            .frame(minWidth: 36, minHeight: 36)
            .fixedSize()
            .background(ARCTheme.appGrey)
            .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(show.isOpen ? ARCTheme.readyGreen : ARCTheme.line, lineWidth: 1))
            .cornerRadius(ARCTheme.cornerRadius)
        }
        .buttonStyle(.plain)
        .help(show.isOpen ? "Show folder \(show.name): \(show.attention.isEmpty ? "up to date" : show.changesSummary). Click to open another." : "Open a show folder from ARC Capture (Cmd+Option+O)")
    }

    private func openFileDialog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, UTType("com.example.arc.arcdeck") ?? .folder, .zip] + Self.videoTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Add a PDF, video, .arcdeck, or a zipped .arcdeck"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let resolved = (DeckArchive.isZip(url) ? (try? DeckArchive.resolve(url)) : url)
                DispatchQueue.main.async {
                    guard let resolved else { NSSound.beep(); return }
                    recentFiles.add(resolved)
                    let targetSize = displayManager.externalScreenSize ?? CGSize(width: 1920, height: 1080)
                    let kind: DeckKind = DeckArchive.isArcdeck(resolved) ? .arcdeck : (isVideoFile(resolved) ? .video : .pdf)
                    deckManager.addDeck(url: resolved, targetSize: targetSize, kind: kind)
                }
            }
        }
    }

    private func isVideoFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return Self.videoTypes.contains(where: { type.conforms(to: $0) })
    }

    private func shortName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        if base.count > 20 {
            return String(base.prefix(18)) + "..."
        }
        return base
    }
}

/// Lays its one child out at its ideal width, but never wider than `cap`: inside a horizontal
/// ScrollView a tab is proposed unlimited width, so a plain `.frame(maxWidth:)` would still let it
/// overflow. Proposing the capped width makes the tab's name truncate instead.
private struct CappedWidth: Layout {
    var cap: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let v = subviews.first else { return .zero }
        let w = min(v.sizeThatFits(.unspecified).width, cap)
        return v.sizeThatFits(ProposedViewSize(width: w, height: proposal.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// A row of tabs that shares `width` among them: at their ideal widths when they fit, else every tab
/// is capped at the same width c (the longest give first, shorter ones stay whole), never under
/// `floor`. Below the floor the row is wider than `width` and the ScrollView around it scrolls.
/// `width` comes in from outside because a horizontal ScrollView proposes unlimited width.
private struct FitTabs: Layout {
    var width: CGFloat
    var spacing: CGFloat
    var floor: CGFloat = 96

    private func widths(_ subviews: Subviews) -> [CGFloat] {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let avail = width - spacing * CGFloat(max(0, ideals.count - 1))
        guard ideals.reduce(0, +) > avail, !ideals.isEmpty else { return ideals }
        // Water-fill: the cap c where sum(min(ideal, c)) == avail.
        var rest = avail, left = ideals.sorted()
        var cap = floor
        while let smallest = left.first {
            let even = rest / CGFloat(left.count)
            if smallest <= even { rest -= smallest; left.removeFirst() } else { cap = even; break }
        }
        cap = max(floor, cap)
        return ideals.map { min($0, cap) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ws = widths(subviews)
        let h = zip(subviews, ws).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: proposal.height)).height }.max() ?? 0
        return CGSize(width: ws.reduce(0, +) + spacing * CGFloat(max(0, ws.count - 1)), height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (v, w) in zip(subviews, widths(subviews)) {
            v.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }
}
