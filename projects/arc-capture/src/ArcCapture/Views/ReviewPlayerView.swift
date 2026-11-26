//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AVKit
import ARCShowFormat

/// The review player (docs/PLAN_review_queue.md, section 3): one row at a time, the kept recording
/// in a frame-stepping player with the click marks on the scrubber and the probe's opinion under it.
/// J K L transport, arrows step a frame, I sets a start, O sets a stop for the click under the
/// playhead, C makes it a cut, 1 makes the page one clip, A accepts, R queues a recapture, Return
/// moves on. Every decision is an override in `state/review.json`; REBUILD cuts the item again.
struct ReviewPlayerView: View {
    let store: ShowFolderStore
    @State private var index: Int
    @State private var player = AVPlayer()
    @State private var time: Double = 0
    @State private var duration: Double = 0
    @State private var sidecar: ReviewSidecar?
    @State private var inPoint: Double?
    @State private var note = ""
    @State private var observer: Any?
    @State private var rebuilding = false
    /// Seconds into the recording where the picture changes (ChangeScan): yellow ticks between the click marks,
    /// so "at the third mark I see the image change" is on the scrubber, not in the eye alone.
    @State private var changes: [Double] = []
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    /// `embedded`: inside the REVIEW tab's desk (no CLOSE, the surface fills what it is given).
    var embedded = false

    private let startID: String

    init(store: ShowFolderStore, start: ReviewEntry, embedded: Bool = false) {
        self.store = store
        self.embedded = embedded
        self.startID = start.id
        _index = State(initialValue: store.review.entries.firstIndex { $0.id == start.id } ?? 0)
    }

    private var rows: [ReviewEntry] { store.review.entries }
    private var entry: ReviewEntry? { rows.indices.contains(index) ? rows[index] : nil }
    private var marks: [Double] { entry?.marks ?? [] }
    /// The click under the playhead: build k runs from mark k-1 to mark k; 0 = the page itself.
    private var click: Int {
        guard marks.count >= 2, let k = marks.lastIndex(where: { $0 <= time }), k < marks.count - 1 else { return 0 }
        return k + 1
    }
    private var sourceHash: String? { entry.flatMap { e in store.spec.items.first { $0.id == e.item }?.currentVersion?.sourceHash } }

    var body: some View {
        VStack(spacing: 8) {
            header
            PlayerSurface(player: player)
                // As a sheet: 16:9 at 880 wide when the window has the room, down to 360 tall on a short one
                // (a 495 minimum made the sheet taller than a 1512 x 982 screen's window, 2026-09-23).
                .frame(minWidth: embedded ? nil : 640, idealWidth: embedded ? nil : 880,
                       minHeight: embedded ? 140 : 360, idealHeight: embedded ? nil : 495)
                .background(Color.black)
                .overlay(alignment: .center) {
                    if entry?.recording == nil {
                        Text("NO RECORDING KEPT FOR THIS ROW\nthe decision is accept or recapture").font(ARCTheme.mono(13, .heavy)).foregroundStyle(ARCTheme.textSecondary).multilineTextAlignment(.center)
                    }
                }
            timeline.frame(height: 30)
            opinion
            assignRow
            verbs
            HStack {
                Text(note).font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.warn).lineLimit(1)
                Spacer()
                Text("J K L   ← →   I O   C   1   A   R   ⏎ next   esc close").font(ARCTheme.mono(10, .regular)).foregroundStyle(ARCTheme.textSecondary)
            }
        }
        .padding(embedded ? 0 : 12)
        .background(embedded ? Color.clear : ARCTheme.background)
        .frame(minWidth: embedded ? nil : 664, idealWidth: embedded ? nil : 904)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handle(press) }
        .onAppear { load(); focused = true }
        .onChange(of: index) { _, _ in load() }
        .onChange(of: startID) { _, new in if let k = rows.firstIndex(where: { $0.id == new }) { index = k } }
        .onDisappear { unload() }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 8) {
            if let e = entry {
                Text(e.item).font(ARCTheme.mono(14, .heavy)).foregroundStyle(ARCTheme.arcRed)
                Text(e.title).font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1)
                if let n = e.slide { Text("PAGE \(n)").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.textPrimary) }
                Text(e.rule).font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.ink).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(e.rule == "R1" || e.rule == "R2" ? ARCTheme.liveRed : ARCTheme.warn))
                Text(e.status.uppercased()).font(ARCTheme.mono(10, .heavy)).foregroundStyle(e.status == "open" ? ARCTheme.warn : ARCTheme.secGreen)
            }
            Spacer()
            Text("\(index + 1) / \(rows.count)").font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary)
            if !embedded { ARCChip("CLOSE") { dismiss() } }
        }
    }

    private var timeline: some View {
        GeometryReader { g in
            let w = g.size.width
            let x: (Double) -> CGFloat = { duration > 0 ? CGFloat($0 / duration) * w : 0 }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(ARCTheme.panel)
                // The click under the playhead, shaded.
                if click > 0, marks.count > click {
                    Rectangle().fill(ARCTheme.warn.opacity(0.18)).frame(width: max(1, x(marks[click]) - x(marks[click - 1]))).offset(x: x(marks[click - 1]))
                }
                if let i = inPoint { Rectangle().fill(ARCTheme.secGreen.opacity(0.35)).frame(width: max(1, x(time) - x(i))).offset(x: x(min(i, time))) }
                ForEach(Array(changes.enumerated()), id: \.offset) { _, t in
                    Rectangle().fill(ARCTheme.warn).frame(width: 2, height: 10).offset(x: x(t), y: 9)
                }
                ForEach(Array(marks.enumerated()), id: \.offset) { k, m in
                    Rectangle().fill(ARCTheme.text0).frame(width: 2).offset(x: x(m))
                    Text("\(k)").font(ARCTheme.mono(8, .heavy)).foregroundStyle(ARCTheme.textSecondary).offset(x: x(m) + 3, y: -9)
                }
                Rectangle().fill(ARCTheme.arcRed).frame(width: 2).offset(x: x(time))
                Text(String(format: "%.2f / %.2f s", time, duration)).font(ARCTheme.mono(9, .regular)).foregroundStyle(ARCTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 4).offset(y: 9)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in seek(to: Double(v.location.x / max(1, w)) * duration) })
        }
    }

    private var opinion: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !embedded { Text(entry?.reason ?? "").font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textPrimary).lineLimit(2) }
            Text(probeLine).font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.secBlue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "click 2: 0.08 s of change, sound, 1.9 s: still with sound (R10)" from the sidecar, or the row's own numbers.
    private var probeLine: String {
        guard let e = entry else { return "" }
        if click > 0, let f = sidecar?.flags.first(where: { $0.evidence["click"] == "\(click)" }) {
            let ev = f.evidence
            return "click \(click): \(ev["inBetweenSeconds"] ?? "?") s of change, sound \(ev["sound"] ?? "?"), \(ev["clipSeconds"] ?? "?") s (\(f.rule))"
        }
        if click > 0 { return "click \(click): no doubt from the probe" }
        let ev = e.evidence.filter { $0.key != "warning" }.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return ev.isEmpty ? "the page" : "the page: \(ev)"
    }

    /// The segment of the recording under the playhead, between two marks (or a mark and the end).
    private var segment: (start: Double, end: Double)? {
        guard !marks.isEmpty else { return nil }
        let starts = marks.filter { $0 <= time }
        guard let start = starts.last else { return nil }
        let end = marks.first { $0 > time } ?? duration
        return end > start ? (start, end) : nil
    }

    /// "This is where we go after click n": the change I am looking at belongs to click n of the deck, whatever
    /// mark it came after (a dropped click, a late one). The segment under the playhead becomes click n's clip.
    private var assignRow: some View {
        let clicks = max(0, marks.count - 1)
        let assign = HStack(spacing: 6) {
            if clicks > 0 {
                Text("THIS IS THE PICTURE AFTER CLICK").font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.textSecondary).fixedSize()
                ForEach(1...clicks, id: \.self) { n in
                    ARCChip("\(n)", tint: ARCTheme.warn) { self.assign(click: n) }.fixedSize()
                }
            }
        }
        let stretch = Group {
            if clicks > 0, let seg = segment { Text(String(format: "(the stretch %.2f to %.2f s)", seg.start, seg.end)).font(ARCTheme.mono(10, .regular)).foregroundStyle(ARCTheme.textTertiary).fixedSize() }
        }
        let found = Text("\(changes.count) change\(changes.count == 1 ? "" : "s") in the picture, in yellow").font(ARCTheme.mono(10, .regular)).foregroundStyle(ARCTheme.warn).fixedSize()
        // A deck with many clicks makes a long row: the readouts drop to a line of their own rather than clip.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { assign; stretch; Spacer(); found }
            VStack(alignment: .leading, spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) { assign }
                HStack(spacing: 6) { stretch; Spacer(); found }
            }
        }
    }

    private func assign(click n: Int) {
        guard let e = entry, let slide = e.slide, let seg = segment else { note = "put the playhead in the stretch of the recording that shows the picture you mean"; return }
        store.decide(ReviewOverride(item: e.item, slide: slide, click: n, kind: .clip, in: seg.start, out: seg.end, sourceHash: sourceHash))
        note = String(format: "click %d of the deck = the stretch %.2f to %.2f s; REBUILD applies it", n, seg.start, seg.end)
    }

    /// One row when it fits; on a narrow desk the marking verbs and the deciding verbs take a row each, so no
    /// chip is ever cut to an ellipsis.
    private var verbs: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { markVerbs; decideVerbs; Spacer(); rowVerbs }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { markVerbs; Spacer(minLength: 0) }
                HStack(spacing: 6) { decideVerbs; Spacer(); rowVerbs }
            }
        }
    }

    @ViewBuilder private var markVerbs: some View {
        ARCChip(inPoint == nil ? "I  START" : String(format: "I  START %.2f", inPoint!)) { setIn() }.fixedSize()
        ARCChip("O  STOP HERE") { setOut() }.fixedSize()
        ARCChip("C  CUT") { cut() }.fixedSize()
        ARCChip("1  ONE CLIP") { whole() }.fixedSize()
    }

    @ViewBuilder private var decideVerbs: some View {
        ARCChip("A  ACCEPT") { accept() }.fixedSize()
        ARCChip("R  RECAPTURE") { recapture() }.fixedSize()
    }

    @ViewBuilder private var rowVerbs: some View {
        ARCChip(rebuilding ? "REBUILDING…" : "REBUILD \(entry?.item ?? "")") { rebuild() }.disabled(rebuilding || store.busy || entry == nil).fixedSize()
        ARCChip("NEXT ⏎") { next() }.fixedSize()
    }


    // MARK: Transport

    private func load() {
        unload()
        inPoint = nil; time = 0; duration = 0; sidecar = nil
        guard let e = entry, let rec = e.recording else { player.replaceCurrentItem(with: nil); return }
        let url = store.folder.appendingPathComponent(rec)
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { t in time = t.seconds }
        if rec.hasSuffix(".recording.mov") {
            let side = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: ".recording.mov", with: ".json"))
            sidecar = (try? Data(contentsOf: side)).flatMap { try? JSONDecoder().decode(ReviewSidecar.self, from: $0) }
        }
        changes = []
        Task { @MainActor in
            if let d = try? await item.asset.load(.duration) { duration = d.seconds }
            let found = await ChangeScan.times(of: url)
            if entry?.recording == rec { changes = found }
        }
        player.seek(to: .zero)
    }

    private func unload() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.pause()
    }

    private func seek(to s: Double) {
        let t = max(0, min(duration, s))
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = t
    }

    private func step(_ n: Int) {
        player.pause()
        player.currentItem?.step(byCount: n)
        time = player.currentTime().seconds
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow: step(-1); return .handled
        case .rightArrow: step(1); return .handled
        case .return: next(); return .handled
        case .space: player.rate == 0 ? player.play() : player.pause(); return .handled
        case .escape: dismiss(); return .handled
        default: break
        }
        switch press.characters.lowercased() {
        case "j": if player.currentItem?.canPlayReverse == true { player.rate = player.rate < 0 ? player.rate * 2 : -1 } else { seek(to: time - 1) }
        case "k": player.pause()
        case "l": player.rate = player.rate > 0 ? min(8, player.rate * 2) : 1
        case "i": setIn()
        case "o": setOut()
        case "c": cut()
        case "1": whole()
        case "a": accept()
        case "r": recapture()
        default: return .ignored
        }
        return .handled
    }

    // MARK: Decisions

    private func setIn() { inPoint = time; note = String(format: "start at %.2f s for click %d", time, click) }

    private func setOut() {
        guard let e = entry, let slide = e.slide else { note = "this row is not about one page"; return }
        let o = ReviewOverride(item: e.item, slide: slide, click: click, kind: .clip, in: click == 0 ? nil : inPoint, out: time, sourceHash: sourceHash)
        store.decide(o)
        note = click == 0 ? String(format: "page %d: the clip stops at %.2f s", slide, time)
                          : String(format: "click %d: a clip %.2f to %.2f s", click, inPoint ?? (marks.count > click ? marks[click - 1] : 0), time)
        inPoint = nil
    }

    private func cut() {
        guard let e = entry, let slide = e.slide else { return }
        guard click > 0 else { note = "put the playhead inside a click to make it a cut"; return }
        store.decide(ReviewOverride(item: e.item, slide: slide, click: click, kind: .cut, sourceHash: sourceHash))
        note = "click \(click): a cut to its still"
    }

    private func whole() {
        guard let e = entry, let slide = e.slide else { return }
        store.decide(ReviewOverride(item: e.item, slide: slide, click: 0, kind: .whole, sourceHash: sourceHash))
        note = "page \(slide): one clip, first mark to the leaving click"
    }

    private func accept() {
        guard let e = entry else { return }
        if let slide = e.slide { store.decide(ReviewOverride(item: e.item, slide: slide, click: 0, kind: .accept, sourceHash: sourceHash)) }
        else { store.setReviewStatus("accepted", of: e.id) }
        note = "accepted as captured"; next()
    }

    private func recapture() {
        guard let e = entry else { return }
        if let slide = e.slide { store.decide(ReviewOverride(item: e.item, slide: slide, click: 0, kind: .recapture, sourceHash: sourceHash)) }
        else { store.setReviewStatus("recapture", of: e.id) }
        note = "queued for recapture"; next()
    }

    private func next() {
        guard !rows.isEmpty else { return }
        if let k = rows.indices.first(where: { $0 > index && rows[$0].status == "open" }) { index = k }
        else if let k = rows.indices.first(where: { rows[$0].status == "open" }) { index = k }
        else { note = "nothing left open" }
    }

    private func rebuild() {
        guard let e = entry else { return }
        rebuilding = true
        Task { @MainActor in
            await store.reprocess(itemID: e.item, rebuild: true)
            rebuilding = false
            note = "\(e.item) rebuilt: \(store.review.open.filter { $0.item == e.item }.count) still open"
            if !rows.indices.contains(index) { index = max(0, rows.count - 1) }
            load()
        }
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.showsFullScreenToggleButton = false
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}


/// Where the picture of a recording changes: frames a quarter second apart, compared as small grey pictures.
enum ChangeScan {
    static func times(of url: URL, step: Double = 0.25, threshold: Float = 0.006) async -> [Double] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0.3 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 96, height: 54)
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = CMTime(seconds: step / 2, preferredTimescale: 600)
        var out: [Double] = []
        var previous: [UInt8]? = nil
        var t = 0.0
        while t < duration.seconds {
            if let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil), let fp = grey(cg) {
                if let p = previous, p.count == fp.count {
                    var sum = 0
                    for i in 0..<fp.count { sum += abs(Int(fp[i]) - Int(p[i])) }
                    if Float(sum) / Float(fp.count * 255) > threshold { out.append(t) }
                }
                previous = fp
            }
            t += step
        }
        return out
    }

    private static func grey(_ cg: CGImage) -> [UInt8]? {
        let w = 32, h = 18
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }
}