//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit
import ARCShowFormat

/// The rules in plain words: what the row is about, and what deciding it means.
enum ReviewWords {
    static func title(_ rule: String) -> String {
        switch rule {
        case "R1": "The capture failed"
        case "R2": "Slides were passed without a page"
        case "R3": "The recording was ended by the watchdog, not by stillness"
        case "R4": "Cut or animation: a coin toss"
        case "R5": "A build the deck has, the capture does not"
        case "R6": "A click changed nothing on screen"
        case "R7": "The movie stopped early"
        case "R8": "The slide advances by itself"
        case "R9": "A kind this version cannot capture"
        case "R10": "A still picture with sound"
        case "R11": "An agenda row the rules could not read"
        case "R12": "A black page nobody asked for"
        case "R13": "An online video the slide links to was not fetched"
        default: "Something to look at"
        }
    }

    /// What ACCEPT and RECAPTURE mean for this rule.
    static func acceptMeans(_ rule: String) -> String {
        switch rule {
        case "R2", "R1": "The deck stays as it is, with the gap. The show will play without those slides."
        case "R5", "R6": "The page stays a still without that build. Right when the click really draws nothing."
        case "R7": "The clip stays as recorded. Right when the movie really ends there."
        case "R3": "The clip stays as long as it was recorded."
        case "R4", "R10": "The clip stays as the splitter cut it."
        case "R8": "The page keeps its timed clip."
        case "R11": "The rundown keeps this row as it was read (a 15 min cue when no length was found)."
        case "R12": "The show carries a PROBLEM slide there that says the page was not captured. Never a black page."
        case "R13": "The page stays as captured: the video is not in the deck, the room will not see it play."
        default: "The capture stays as it is."
        }
    }
    static func recaptureMeans(_ rule: String) -> String {
        switch rule {
        case "R2": "Only the passed slides are captured again and put back into the deck; the other pages stay."
        case "R5", "R6": "This slide is captured again (with the one before it, for the way in) and put back into the deck."
        case "R7", "R3": "This slide is captured again with a longer hold and put back into the deck."
        default: "This slide is captured again and put back into the deck."
        }
    }
    static func canRecapture(_ e: ReviewEntry) -> Bool { ["R2", "R3", "R5", "R6", "R7", "R12"].contains(e.rule) && (e.slide != nil || e.rule == "R2") }
}

/// The REVIEW tab (2026-09-19: "the review and decide need to be clearer and more straightforward. I
/// cannot see the problem or figure out how to decide what to do"): the queue on the left, the EVIDENCE in
/// the middle (the stills before and after the click, the recording in the player, the agenda line), the
/// rule in plain words, and the decisions as labelled buttons that offer only what applies.
struct ReviewTabView: View {
    @State private var store: ShowFolderStore? = ShowFolderStore.current
    @State private var selected: String?
    @State private var showDecided = false
    @Environment(\.captureLayout) private var layout

    var body: some View {
        VStack(spacing: 0) {
            CaptureHeader(screen: "REVIEW", subject: store?.spec.name, state: open.isEmpty ? .ready : .working,
                          stateDetail: open.isEmpty ? "NOTHING TO DECIDE" : "\(open.count) TO DECIDE")
            ARCTheme.divider.frame(height: 1)
            if let store {
                HStack(alignment: .top, spacing: ARCTheme.paddingSmall) {
                    queue(store).frame(width: layout.reviewQueueW)
                    // A short window scrolls the desk (problem, evidence, decisions) rather than pushing the tab strip under the title bar.
                    desk(store).scrollsWhenShort().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .padding(ARCTheme.paddingMedium)
            } else {
                Text("OPEN A SHOW ON THE SHOW TAB: ITS REVIEW QUEUE APPEARS HERE").font(ARCTheme.mono(14, .heavy)).foregroundStyle(ARCTheme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ARCTheme.background)
        .onAppear {
            store = ShowFolderStore.current
            if selected == nil { selected = open.first?.id }
        }
        .onReceive(NotificationCenter.default.publisher(for: ShowFolderStore.currentChanged)) { _ in store = ShowFolderStore.current; selected = open.first?.id }
    }

    private var rows: [ReviewEntry] { store?.review.entries ?? [] }
    private var open: [ReviewEntry] { rows.filter { $0.status == "open" } }
    private var entry: ReviewEntry? { rows.first { $0.id == selected } }

    // MARK: The queue

    private func queue(_ store: ShowFolderStore) -> some View {
        let shown = showDecided ? rows : open
        let byItem = Dictionary(grouping: shown, by: \.item)
        let items = byItem.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 6) {
            // The filter and the queue verbs on one line when they fit whole, else the verbs on a line of their own.
            ViewThatFits(in: .horizontal) {
                HStack { queueFilter; Spacer(); queueVerbs(store) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack { queueFilter; Spacer(minLength: 0) }
                    HStack { queueVerbs(store); Spacer(minLength: 0) }
                }
            }
            if shown.isEmpty {
                Text(showDecided ? "Nothing in the queue." : "Nothing to decide: every capture settled on its own.").font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.textSecondary).padding(.top, 8)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items, id: \.self) { item in
                            HStack(spacing: 6) {
                                Text(item).font(ARCTheme.mono(12, .heavy)).foregroundStyle(ARCTheme.arcRed)
                                Text(byItem[item]?.first?.title ?? "").font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1)
                            }
                            .padding(.top, 6)
                            ForEach((byItem[item] ?? []).sorted { ($0.slide ?? 0, $0.rule) < ($1.slide ?? 0, $1.rule) }) { e in
                                queueRow(e)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .arcModule(title: "QUEUE", tint: ARCTheme.secOrange, badge: ARCBandBadge(text: "\(open.count) OPEN", fill: open.isEmpty ? ARCTheme.readyGreen : ARCTheme.warn))
    }

    @ViewBuilder private var queueFilter: some View {
        ARCChip("OPEN", tint: ARCTheme.warn, on: !showDecided) { showDecided = false }.fixedSize()
        ARCChip("ALL", tint: ARCTheme.warn, on: showDecided) { showDecided = true }.fixedSize()
    }

    @ViewBuilder private func queueVerbs(_ store: ShowFolderStore) -> some View {
        if !store.review.entries.isEmpty {
            ARCChip("REOPEN ALL", tint: ARCTheme.secOrange) { store.reopenReview(); selected = open.first?.id }.disabled(store.busy).fixedSize()
                .help("Every decision undone: the rows open again and the marks made in the player are dropped")
        }
        if store.review.entries.contains(where: { $0.status == "recapture" || ($0.rule == "R2" && $0.status == "open") }) {
            ARCChip("RUN THE RECAPTURES", tint: ARCTheme.arcRed, on: true) { Task { await store.recaptureQueued() } }.disabled(store.busy).fixedSize()
                .help("Every slide marked RECAPTURE is captured again now, one range at a time, and put back into its deck")
        }
    }

    private func queueRow(_ e: ReviewEntry) -> some View {
        let on = e.id == selected
        return Button(action: { selected = e.id }) {
            HStack(spacing: 8) {
                Circle().fill(e.status == "open" ? ARCTheme.warn : (e.status == "recapture" ? ARCTheme.arcRed : (e.status == "black" ? ARCTheme.text2 : ARCTheme.readyGreen))).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text((e.slide.map { "PAGE \($0)  " } ?? "") + ReviewWords.title(e.rule)).font(ARCTheme.mono(11, .heavy)).foregroundStyle(on ? ARCTheme.ink : ARCTheme.textPrimary).lineLimit(1)
                    Text(e.status == "open" ? e.reason : e.status.uppercased()).font(ARCTheme.mono(10, .regular)).foregroundStyle(on ? ARCTheme.ink.opacity(0.8) : ARCTheme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if e.recording != nil { Image(systemName: "film").font(.system(size: 10)).foregroundStyle(on ? ARCTheme.ink : ARCTheme.textSecondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(on ? ARCTheme.secOrange : ARCTheme.panel).cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: The desk: the problem, the evidence, the decision

    private func desk(_ store: ShowFolderStore) -> some View {
        VStack(spacing: ARCTheme.paddingSmall) {
            if let e = entry {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(e.item).font(ARCTheme.mono(16, .heavy)).foregroundStyle(ARCTheme.arcRed)
                        Text(e.title).font(ARCTheme.mono(13, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1)
                        if let n = e.slide { Text("PAGE \(n)").font(ARCTheme.mono(13, .heavy)).foregroundStyle(ARCTheme.textPrimary) }
                        Spacer()
                        Text(e.rule).font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.textSecondary)
                    }
                    Text(ReviewWords.title(e.rule)).font(ARCTheme.mono(18, .heavy)).foregroundStyle(ARCTheme.textPrimary)
                    Text(e.reason).font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if !e.evidence.isEmpty {
                        Text(e.evidence.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "   ")).font(ARCTheme.mono(10, .regular)).foregroundStyle(ARCTheme.textTertiary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .arcModule(title: "THE PROBLEM", tint: ARCTheme.warn)

                evidence(e, store).frame(maxWidth: .infinity, maxHeight: .infinity)

                decisions(e, store)
            } else {
                Text("PICK A ROW ON THE LEFT").font(ARCTheme.mono(14, .heavy)).foregroundStyle(ARCTheme.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .arcModule(title: "THE PROBLEM", tint: ARCTheme.line)
            }
        }
    }

    /// The stills before and after the click, the recording in the player, or the words of an agenda row.
    @ViewBuilder
    private func evidence(_ e: ReviewEntry, _ store: ShowFolderStore) -> some View {
        if e.recording != nil {
            ReviewPlayerView(store: store, start: e, embedded: true)
                .arcModule(title: "THE RECORDING", tint: ARCTheme.secGreen)
        } else if let (before, after, label) = stills(for: e, store) {
            HStack(spacing: ARCTheme.paddingSmall) {
                stillPane(before, "BEFORE THE CLICK")
                stillPane(after, label)
            }
            .arcModule(title: "THE PICTURE", tint: ARCTheme.secGreen)
        } else if e.item == "AGENDA" {
            VStack(alignment: .leading, spacing: 8) {
                Text("THE LINE AS THE DECK HAS IT").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.textSecondary)
                Text((e.evidence["raw"] ?? "").replacingOccurrences(of: "\t", with: "   ⇥   ")).font(ARCTheme.mono(13, .regular)).foregroundStyle(ARCTheme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    .padding(10).background(ARCTheme.panel).cornerRadius(4)
                Text("Every row of the agenda is already in the rundown Presenter runs. Rows here are the ones read with a doubt: a wrapped title or names, or a slot with no length (15 min was assumed). Fix them in Presenter's RUNDOWN window if the cue matters; ACCEPT here says the reading is fine.")
                    .font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .arcModule(title: "THE AGENDA ROW", tint: ARCTheme.secGreen)
        } else {
            Text(e.rule == "R2" ? "No page exists for those slides: there is nothing to show until they are captured." : "No recording was kept for this row.")
                .font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                .arcModule(title: "THE PICTURE", tint: ARCTheme.line)
        }
    }

    private func stillPane(_ url: URL?, _ label: String) -> some View {
        ZStack {
            Color.black
            if let url, let img = NSImage(contentsOf: url) { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit) }
            else { Text("no still").font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textTertiary) }
        }
        .overlay(alignment: .top) {
            Text(label).font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.text0)
                .padding(.horizontal, 8).padding(.vertical, 3).background(ARCTheme.ink.opacity(0.75)).cornerRadius(3).padding(6)
        }
        .cornerRadius(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The page's stills around the click in question: `stills/slide_NNN_s(k-1).png` and `_s(k).png`; a page
    /// with no builds shows its page picture twice (the click drew nothing, so before and after are the same).
    private func stills(for e: ReviewEntry, _ store: ShowFolderStore) -> (URL?, URL?, String)? {
        guard let page = e.slide, let item = store.spec.items.first(where: { $0.id == e.item }),
              let v = item.currentVersion ?? item.latestVersion, !v.arcdeck.isEmpty else { return nil }
        let deck = store.folder.appendingPathComponent(v.arcdeck)
        let tag = String(format: "slide_%03d", page)
        let click = Int(e.evidence["click"] ?? "") ?? 1
        let fm = FileManager.default
        let before = deck.appendingPathComponent(String(format: "stills/%@_s%02d.png", tag, click - 1))
        let after = deck.appendingPathComponent(String(format: "stills/%@_s%02d.png", tag, click))
        if fm.fileExists(atPath: before.path) || fm.fileExists(atPath: after.path) {
            return (fm.fileExists(atPath: before.path) ? before : nil, fm.fileExists(atPath: after.path) ? after : nil, "AFTER CLICK \(click)")
        }
        // No build stills: the page as captured, from the deck's PDF is heavy; the checkpoint jpeg is not kept. Show the manifest page still if any.
        let pagePng = deck.appendingPathComponent(String(format: "stills/%@.png", tag))
        if fm.fileExists(atPath: pagePng.path) { return (pagePng, pagePng, "AS CAPTURED (THE SAME)") }
        return nil
    }

    // MARK: Decisions

    /// The decisions side by side when their buttons fit whole; on a narrow desk the OR MARK IT hint goes first
    /// (the player's own verbs say the same), then the decisions wrap two to a row. A button is never cut.
    private func decisions(_ e: ReviewEntry, _ store: ShowFolderStore) -> some View {
        let s = ARCTheme.paddingSmall
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: s) { decisionCells(e, store); markHint(e) }
            HStack(alignment: .top, spacing: s) { decisionCells(e, store) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: s, alignment: .top), GridItem(.flexible(), spacing: s, alignment: .top)], spacing: s) {
                decisionCells(e, store)
            }
        }
    }

    @ViewBuilder
    private func markHint(_ e: ReviewEntry) -> some View {
        if e.recording != nil {
            // The whole sentence when the box holds it, the short form when it does not (never cut mid-line).
            ViewThatFits(in: .vertical) {
                Text("The player above marks it by hand: I and O set a clip's start and stop for the click under the playhead, C makes the click a cut, 1 makes the page one clip. REBUILD applies the marks.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("In the player: I and O a clip, C a cut, 1 one clip. REBUILD applies them.")
                    .fixedSize(horizontal: false, vertical: true)
            }
                .font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: .infinity, alignment: .topLeading).padding(.horizontal, 10).padding(.vertical, 8)
                .arcModule(title: "OR MARK IT", tint: ARCTheme.line)
                .frame(height: Self.decisionH, alignment: .top)
        }
    }

    private static let decisionH: CGFloat = 104

    @ViewBuilder
    private func decisionCells(_ e: ReviewEntry, _ store: ShowFolderStore) -> some View {
            decision("ACCEPT AS CAPTURED", fill: ARCTheme.secGreen, words: ReviewWords.acceptMeans(e.rule), enabled: e.status == "open") {
                decide(e, store, kind: .accept)
            }
            if ReviewWords.canRecapture(e) {
                decision("RECAPTURE THIS SLIDE", fill: ARCTheme.arcRed, words: ReviewWords.recaptureMeans(e.rule) + " Press RUN THE RECAPTURES above when the list is done.", enabled: e.status == "open") {
                    decide(e, store, kind: .recapture)
                }
            }
            if ["R7", "R12", "R3"].contains(e.rule), hasSourceMovie(e, store) {
                decision("USE THE SOURCE MOVIE", fill: ARCTheme.secBlue, words: "The movie inside the deck becomes the page's clip, original quality, in place of the recording. Done in seconds.", enabled: e.status == "open") {
                    decide(e, store, kind: .sourceMovie)
                }
            }
            if e.rule == "R13" {
                decision("FETCH IT AGAIN", fill: ARCTheme.secBlue, words: "The video (\(e.evidence["url"] ?? "")) is downloaded and the page plays it locally, started by its click: ARC Grab 1.5.0 for YouTube and Vimeo, Capture itself for Drive, Dropbox, Box, OneDrive and file links. Needs a connection.", enabled: e.status == "open" && !store.busy) {
                    let id = e.item
                    Task { await store.reprocess(itemID: id) }
                }
            }
            if e.rule == "R12" {
                decision("LEAVE IT BLACK", fill: ARCTheme.ink, words: "Only if black is what the deck means here. The show will carry a black page, and this row says you chose it.", enabled: e.status == "open") {
                    store.setReviewStatus("black", of: e.id); selected = open.first { $0.id != e.id }?.id ?? e.id
                }
            }
    }

    private func decision(_ title: String, fill: Color, words: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // The label at its full width is the cell's minimum; the words wrap to whatever is left.
            ARCActionButton(title, enabled: enabled, fill: fill, size: 13, action: action).fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity)
            Text(words).font(ARCTheme.mono(10, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(2)
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .arcModule(title: "DECIDE", tint: ARCTheme.secOrange)
        .frame(height: Self.decisionH)
    }

    /// The page holds one movie the deck carries (the analyzer named it): the source movie can stand in.
    private func hasSourceMovie(_ e: ReviewEntry, _ store: ShowFolderStore) -> Bool {
        guard let page = e.slide, let item = store.spec.items.first(where: { $0.id == e.item }), item.kind == .powerpoint,
              let v = item.currentVersion ?? item.latestVersion, !v.arcdeck.isEmpty,
              let m = DeckManifest.load(from: store.folder.appendingPathComponent(v.arcdeck).appendingPathComponent("manifest.json")).manifest,
              let p = m.slides.first(where: { $0.slide == page }) else { return false }
        return p.type == .video && (p.media ?? []).contains { $0.kind == .video }
    }

    private func decide(_ e: ReviewEntry, _ store: ShowFolderStore, kind: ReviewOverride.Kind) {
        let hash = store.spec.items.first { $0.id == e.item }?.currentVersion?.sourceHash
        if let slide = e.slide {
            store.decide(ReviewOverride(item: e.item, slide: slide, click: 0, kind: kind, sourceHash: hash))
        } else {
            store.setReviewStatus(kind == .recapture ? "recapture" : "accepted", of: e.id)
        }
        // On to the next open row.
        selected = open.first { $0.id != e.id }?.id ?? e.id
    }
}
