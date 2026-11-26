//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit
import QuickLookThumbnailing
import ARCShowFormat

/// The SHOW tab (V3) as ONE road, in ARC Style (2026-09-17: "lets re work the capture show process to be
/// a bit more intuitive and informative. it should go open target folder, assess files in folder, identify
/// holding slide, confirm sort, capture presentations, build 1 show deck (not individual presos). then open in
/// presenter. also make the running tasks on the bottom bigger and more useful. Apply the ARC style").
///
/// PIPELINE (left): the seven steps, each with what it found, and ONE red button that is always the next thing
/// to press. RUN ORDER (centre): what the folder holds, in the order it will run, with LEAVE OUT. HOLDING SLIDE
/// and PASSED OVER (right). ACTIVITY (bottom): what is running now, how far along, STOP, and the log.
struct ShowFolderView: View {
    @State private var store: ShowFolderStore?
    @State private var showNew = false
    @State private var newName = ""
    @State private var monitor = CaptureMonitor.shared
    @State private var openError: String?
    @State private var reviewing: ReviewEntry?
    @Environment(\.captureLayout) private var layout

    var body: some View {
        VStack(spacing: 0) {
            header
            ARCTheme.divider.frame(height: 1)
            HStack(alignment: .top, spacing: 10) {
                // The side columns narrow on a narrow window so the run order stays the flexible column; the
                // left column scrolls when the window is too short for NEXT and all eight STEPS (CaptureLayout).
                pipeline.fixedSize(horizontal: false, vertical: true).scrollsWhenShort().frame(width: layout.showLeftW)
                if let store {
                    runOrder(store).frame(maxWidth: .infinity)
                    VStack(spacing: 10) { holding(store); passedOver(store); reviewQueue(store) }.frame(width: layout.showRightW)
                } else {
                    welcome.frame(maxWidth: .infinity)
                }
            }
            .padding(10)
            .frame(maxHeight: .infinity)
            activity.frame(height: layout.activityH).padding([.horizontal, .bottom], 10)
        }
        .background(ARCTheme.background)
        .onAppear {
            if let asked = ShowRouting.pending { ShowRouting.pending = nil; adopt(try? ShowFolderStore(folder: asked)) }
            else if store == nil { adopt(ShowFolderStore.restoreLast()) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ShowRouting.openShow)) { _ in
            if let asked = ShowRouting.pending { ShowRouting.pending = nil; adopt(try? ShowFolderStore(folder: asked)) }
        }
        .sheet(isPresented: $showNew) { newShowSheet }
        .sheet(item: $reviewing) { e in
            if let store { ReviewPlayerView(store: store, start: e) }
        }
    }

    private func adopt(_ s: ShowFolderStore?) {
        guard let s else { return }
        store = s; ShowFolderStore.current = s
        Task { await s.assess(quiet: true) }
    }

    private var facts: ShowPipeline.Facts { store?.pipelineFacts ?? ShowPipeline.Facts() }

    // MARK: Header

    private var header: some View {
        let a = store?.activity
        let state: CaptureScreenState = a != nil ? (a?.step == .capture ? .capturing : .working) : (store == nil ? .idle : (facts.failed > 0 ? .error : .ready))
        return CaptureHeader(screen: "SHOW", subject: store?.spec.name, state: state, stateDetail: a?.title.uppercased()) {
            if let store {
                Text(store.folder.path).font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textTertiary).lineLimit(1).truncationMode(.head)
                    .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([store.folder]) }.help("Reveal the show folder in Finder")
            }
        }
    }

    // MARK: NEXT + STEPS (the left column)

    @State private var housekeeping = false

    private var pipeline: some View {
        VStack(spacing: ARCTheme.paddingSmall) {
            nextModule
            stepsRail
        }
    }

    /// What happened, why, and the one thing to press (ShowPipeline.advice).
    private var nextModule: some View {
        let f = facts, adv = ShowPipeline.advice(f)
        let running = store?.activity != nil || store?.busy == true
        return VStack(alignment: .leading, spacing: 8) {
            Text(adv.headline).font(ARCTheme.mono(15, .heavy)).foregroundStyle(f.failed > 0 && f.running == nil ? ARCTheme.warn : ARCTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(adv.why).font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let step = adv.primary {
                ARCActionButton(running ? "RUNNING…" : adv.primaryTitle, enabled: !running, size: 14) { press(step) }
                    .frame(maxWidth: .infinity)
            }
            if let alt = adv.alternative, let title = adv.alternativeTitle, !running {
                ARCChip(title, tint: ARCTheme.secOrange, wide: true) { alternative(alt) }
            }
            if let store, store.linkedSource != nil { autoChip(store) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcModule(title: "NEXT", tint: ARCTheme.secOrange,
                   badge: ARCBandBadge(text: running ? "RUNNING" : (f.failed > 0 ? "\(f.failed) FAILED" : (adv.primary.map { "STEP \($0.rawValue + 1) OF \(ShowPipeline.Step.allCases.count)" } ?? "DONE")),
                                       fill: running ? ARCTheme.liveRed : (f.failed > 0 ? ARCTheme.warn : ARCTheme.ink)))
    }

    private func alternative(_ alt: ShowPipeline.Advice.Alternative) {
        guard let store else { return }
        switch alt {
        case .leaveOutFailedAndBuild: Task { await store.leaveOutFailedAndBuild() }
        case .confirmOrder: store.confirmOrder()
        case .assess: Task { await store.assess() }
        case .openReview: NotificationCenter.default.post(name: ShowRouting.openReview, object: nil)
        }
    }

    /// The eight steps, one line each, all in view; the housekeeping verbs behind the glyph.
    private var stepsRail: some View {
        let f = facts, states = ShowPipeline.states(f), next = ShowPipeline.next(f)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(ShowPipeline.Step.allCases) { step in
                stepRow(step, state: states[step] ?? .todo, isNext: step == next)
                if step != .present { ARCTheme.line.frame(height: 1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .arcModule(title: "STEPS", tint: ARCTheme.secBlue)
        .arcExpandButton("Open another folder, open or make a show, sync, unlink, preflight, reveal, close", on: housekeeping) { housekeeping.toggle() }
        .popover(isPresented: $housekeeping, arrowEdge: .trailing) { housekeepingPanel }
    }

    private var housekeepingPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SHOW FOLDER").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.textSecondary)
            HStack(spacing: 6) {
                ARCChip("OPEN FOLDER…") { housekeeping = false; openTarget() }.disabled(store?.busy == true).help("Another target folder: its show opens, or a new one is made for it")
                ARCChip("OPEN SHOW…") { housekeeping = false; openShow() }.help("An existing show folder (it holds show.json)")
                ARCChip("NEW…") { housekeeping = false; showNew = true }.help("A show with no target folder: drop decks into its decks/ folder")
                if store != nil { ARCChip("CLOSE") { housekeeping = false; closeShow() }.disabled(store?.busy == true).help("Put this show away: the tab empties and the next launch starts empty. Nothing on disk changes.") }
            }
            if let store {
                Text("THIS SHOW").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.textSecondary).padding(.top, 4)
                HStack(spacing: 6) {
                    if store.linkedSource != nil {
                        ARCChip(store.syncing ? "SYNCING…" : "SYNC") { Task { await store.confirmedSync() } }.disabled(store.busy || store.syncing)
                            .help("Check the target folder now (it is checked every \(Int(ShowFolderStore.sourcePollSeconds)) s). New and changed files come in once the run order is confirmed.")
                        ARCChip("UNLINK") { store.unlinkSource() }.help("Stop following the target folder. What it brought stays.")
                    }
                    ARCChip("PREFLIGHT") { Task { await store.preflight() } }.disabled(store.busy).help("The pre-show check: every item captured and verified. Writes reports/preflight.json")
                    ARCChip("REVEAL") { NSWorkspace.shared.activateFileViewerSelecting([store.folder]) }.help("The show folder in Finder")
                }
            }
        }
        .padding(12)
        .background(ARCTheme.background)
    }

    private func stepRow(_ step: ShowPipeline.Step, state: ShowPipeline.State, isNext: Bool) -> some View {
        let color: Color = { switch state {
            case .done: return ARCTheme.readyGreen
            case .running: return ARCTheme.arcRed
            case .ready: return ARCTheme.warn
            case .attention: return ARCTheme.warn
            case .todo: return ARCTheme.textTertiary } }()
        return HStack(alignment: .center, spacing: 8) {
            ZStack {
                Circle().fill(state == .done ? color : Color.clear).overlay(Circle().strokeBorder(color, lineWidth: 2)).frame(width: 20, height: 20)
                if state == .done { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(ARCTheme.ink) }
                else if state == .running { ProgressView().controlSize(.small).scaleEffect(0.6) }
                else { Text("\(step.rawValue + 1)").font(ARCTheme.mono(10, .heavy)).foregroundStyle(color) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title).font(ARCTheme.mono(11, .heavy)).foregroundStyle(state == .todo ? ARCTheme.textTertiary : ARCTheme.textPrimary)
                Text(result(step, state).split(separator: "\n").first.map(String.init) ?? "").font(ARCTheme.mono(10, .regular))
                    .foregroundStyle(state == .attention ? ARCTheme.warn : ARCTheme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let store, state == .done || state == .attention, !store.busy {
                switch step {
                case .assess: ARCChip("AGAIN") { Task { await store.assess() } }
                case .agenda: ARCChip("AGAIN") { Task { await store.readAgenda(force: true) } }
                case .build: ARCChip("REBUILD") { Task { await store.run(from: .build) } }
                case .present: ARCChip("AGAIN") { Task { await store.run(from: .present) } }
                default: EmptyView()
                }
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(isNext ? ARCTheme.warn.opacity(0.08) : Color.clear)
        .help(result(step, state))
    }

    /// What each step FOUND, in one or two lines: the pipeline is a report, not only a to-do list.
    private func result(_ step: ShowPipeline.Step, _ state: ShowPipeline.State) -> String {
        guard let store else { return step == .open ? "The folder of presentations: a Google Drive folder, a share, a stick. It is only ever read." : "" }
        let f = facts, a = store.assessment
        switch step {
        case .open:
            return store.linkedSource.map { "\($0.lastPathComponent)\nread only, checked every \(Int(ShowFolderStore.sourcePollSeconds)) s" } ?? (f.hasShow ? "no target folder: decks dropped into decks/" : "Pick the folder the presentations are in.")
        case .assess:
            guard let a else { return "Reads the listing only. Nothing is downloaded yet." }
            if a.included.isEmpty { return "No presentations found in the folder." }
            let kinds = a.byKind.map { "\($0.count) \($0.kind)" }.joined(separator: ", ")
            var text = "\(f.planned) presentation\(f.planned == 1 ? "" : "s"): \(kinds)\n\(ByteCountFormatter.string(fromByteCount: a.bytes, countStyle: .file)), \(a.passedOver.count) passed over"
            if let r = store.aspectReport, !r.odd.isEmpty { text += "\n\(r.odd.count) NOT \(AspectCheck.name(r.show)): " + r.odd.map { "\($0.id) \(AspectCheck.name($0.aspect))" }.joined(separator: ", ") }
            return text
        case .agenda:
            if state == .todo { return "A schedule deck in the folder (a slide per day, a time column) becomes Presenter's cue timer rundown." }
            guard let deck = f.agendaDeck else { return "No schedule deck in the folder: the rundown is Presenter's to write, or import a ROS file there." }
            var text = "\(deck)\n\(f.agendaDays) day\(f.agendaDays == 1 ? "" : "s"), \(f.agendaCues) cue\(f.agendaCues == 1 ? "" : "s"), \(f.agendaTalks) talk\(f.agendaTalks == 1 ? "" : "s"): state/rundown.json"
            if f.agendaRefused > 0 { text += "\n\(f.agendaRefused) row\(f.agendaRefused == 1 ? "" : "s") to check in REVIEW" }
            return text
        case .holding:
            if state == .todo { return "Named \"S0.0 Holding Slide ...\": the logo page before, between and after." }
            return f.holdingSlide ?? "None in the folder: the ARC mark stands in.\nName one \"S0.0 Holding Slide ...\" to use it."
        case .sort:
            if state == .todo { return "Check the order on the right, leave out what does not belong." }
            if f.orderChanged { return "The folder changed since you confirmed: check the order again." }
            return f.orderConfirmed ? "Confirmed: \(store.plannedOrder.first ?? "") to \(store.plannedOrder.last ?? "")" : "Check the run order on the right, LEAVE OUT what does not belong, then confirm. Nothing is copied before this."
        case .capture:
            if state == .todo { return "Each presentation played and recorded, one click at a time." }
            if f.failed > 0 { return "\(f.failed) FAILED: " + store.spec.items.filter { $0.status == .failed }.map(\.id).joined(separator: ", ") }
            if state == .done { return "\(f.ready) of \(f.ready) captured and verified" }
            return "\(f.toBringIn) to bring in, \(f.pending + f.toBringIn) to capture, \(f.ready) ready.\nHands off the keyboard and mouse while it runs."
        case .build:
            if state == .todo { return "ONE deck for the show, the holding slide between the talks." }
            if let deck = store.showDeckURL {
                let when = ((try? deck.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil).map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
                return "\(deck.lastPathComponent)\n" + (f.showDeckCurrent ? "built \(when), current" : "built \(when): not from the versions that are current now. Rebuild it.")
            }
            return "\(store.showDeckItems.count) presentation(s) into one deck."
        case .present:
            if state == .todo { return "One tab in Presenter, in preview. TAKE puts it live." }
            return store.sourceLedger.presentedAt.map { "opened \($0.formatted(date: .omitted, time: .shortened)): one tab, in preview" } ?? "Starts ARC Presenter if it is not running."
        }
    }

    /// AUTO CAPTURE as one chip: armed, a changed talk is captured, built and staged once the Mac has been idle.
    private func autoChip(_ store: ShowFolderStore) -> some View {
        let on = store.isArmed
        return ARCChip(on ? "AUTO CAPTURE ON CHANGE: ARMED" : "AUTO CAPTURE ON CHANGE: OFF", tint: ARCTheme.warn, on: on, wide: true) { store.setArmed(!on) }
            .help(on ? "Armed: a changed talk is captured, built and staged in Presenter once this Mac has been idle \(AutoCapture.idleNeeded) s. A NEW talk still waits for you. PowerPoint plays on the second display and keys are sent with nobody pressing anything: arm it on a Mac that is only doing this."
                     : "Off: changes are brought in and marked. You press.")
    }

    private func press(_ step: ShowPipeline.Step) {
        switch step {
        case .open: openTarget()
        case .assess: if let store { Task { await store.assess() } } else { openTarget() }
        case .holding: break
        case .agenda: if let store { Task { await store.readAgenda(force: true) } }
        case .sort: store?.confirmOrder()
        case .capture, .build, .present: if let store { Task { await store.run(from: step) } }
        }
    }

    // MARK: RUN ORDER

    private func runOrder(_ store: ShowFolderStore) -> some View {
        let rows = store.assessment?.rows ?? []
        let items = Dictionary(store.spec.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let badge = ARCBandBadge(text: facts.orderConfirmed ? (facts.orderChanged ? "CHANGED" : "CONFIRMED") : "NOT CONFIRMED",
                                 fill: facts.orderConfirmed && !facts.orderChanged ? ARCTheme.readyGreen : ARCTheme.warn)
        return VStack(spacing: 0) {
            if rows.isEmpty {
                Text(store.linkedSource == nil && store.spec.items.isEmpty ? "OPEN A TARGET FOLDER TO SEE WHAT IT HOLDS" : "ASSESSING…")
                    .font(ARCTheme.mono(14)).foregroundStyle(ARCTheme.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(rows) { row in orderRow(row, item: items[row.id], store: store) }
                    }
                }
            }
        }
        .arcModule(title: "RUN ORDER", tint: ARCTheme.secOrange, badge: badge)
    }

    /// The review queue (docs/PLAN_review_queue.md, phase 1: read-only rows; the player and the verbs are phase 2).
    private func reviewQueue(_ store: ShowFolderStore) -> some View {
        let open = store.review.open
        let queued = store.review.entries.contains { $0.status == "recapture" || ($0.rule == "R2" && $0.status == "open") }
        return VStack(alignment: .leading, spacing: 6) {
            if queued {
                ARCChip("RECAPTURE THE QUEUED SLIDES", tint: ARCTheme.secOrange, wide: true) { Task { await store.recaptureQueued() } }.disabled(store.busy)
                    .help("The slides the review marked for recapture (R, and every R2 row) are captured again, one range at a time, and put back into the item's deck as a new version")
            }
            if open.isEmpty {
                Text("Nothing to decide: every capture settled on its own.").font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary)
                let decided = store.review.entries.count - open.count
                if decided > 0 { Text("\(decided) decided").font(ARCTheme.mono(10, .regular)).foregroundStyle(ARCTheme.textSecondary) }
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(open) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(e.item).font(ARCTheme.mono(12, .heavy)).foregroundStyle(ARCTheme.arcRed)
                                    if let n = e.slide { Text("PAGE \(n)").font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.textSecondary) }
                                    Text(e.rule).font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.ink).padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 3).fill(e.rule == "R1" || e.rule == "R2" ? ARCTheme.liveRed : ARCTheme.warn))
                                    Spacer(minLength: 0)
                                    if e.recording != nil { Image(systemName: "film").font(.system(size: 10)).foregroundStyle(ARCTheme.textSecondary).help("The page's recording was kept for the review player") }
                                }
                                Text(e.reason).font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textPrimary).lineLimit(3)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { reviewing = e }
                            .help(e.evidence.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n") + "\n\nClick: open in the review player")
                            ARCTheme.line.frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcModule(title: "REVIEW", tint: open.isEmpty ? ARCTheme.secGreen : ARCTheme.warn,
                   badge: ARCBandBadge(text: open.isEmpty ? "CLEAR" : "\(open.count) TO DECIDE", fill: open.isEmpty ? ARCTheme.text0 : ARCTheme.warn))
    }

    @State private var hoveredRow: String?

    private func orderRow(_ row: SourceAssessment.Row, item: ShowSpec.Item?, store: ShowFolderStore) -> some View {
        let out = row.state == .excluded
        return HStack(spacing: 10) {
            Text(row.id).font(ARCTheme.mono(16, .heavy)).foregroundStyle(out ? ARCTheme.textTertiary : (row.isHolding ? ARCTheme.secBlue : ARCTheme.arcRed)).frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(ARCTheme.mono(13)).foregroundStyle(out ? ARCTheme.textTertiary : ARCTheme.textPrimary).lineLimit(1).strikethrough(out)
                Text(rowDetail(row, item)).font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let a = store.aspects[row.id], let show = store.aspectReport?.show, AspectCheck.differs(a, from: show) {
                Text(AspectCheck.name(a)).font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.ink).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 3).fill(ARCTheme.warn)).fixedSize()
                    .help("This one is \(AspectCheck.name(a)) in a \(AspectCheck.name(show)) show: it plays with bars at the sides or top. Ask for a \(AspectCheck.name(show)) version if there is time.")
            }
            rowChip(row, item)
            if store.linkedSource != nil, !row.isHolding {
                // The verb shows on hover (fifteen LEAVE OUT buttons in a column read as fifteen decisions, 2026-09-19).
                ARCChip(out ? "PUT BACK" : "LEAVE OUT", tint: ARCTheme.secOrange) { Task { await store.setExcluded(row.rel, !out) } }.disabled(store.busy)
                    .help(out ? "Bring it back into the show" : "Not part of the show (a client's own combined deck, a duplicate): it is not copied, captured or put in the show deck")
                    .opacity(hoveredRow == row.id || out ? 1 : 0)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6).background(hoveredRow == row.id ? ARCTheme.panel : ARCTheme.moduleBg).cornerRadius(4)
        .contentShape(Rectangle())
        .onHover { hoveredRow = $0 ? row.id : (hoveredRow == row.id ? nil : hoveredRow) }
    }

    private func rowDetail(_ row: SourceAssessment.Row, _ item: ShowSpec.Item?) -> String {
        let facts = "\(row.kind.uppercased()) · \(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file))"
        if row.isHolding { return "\(facts) · the show's logo page: before, between and after the talks" }
        if item?.status == .failed, let v = item?.latestVersion { return "\(facts) · FAILED: \(v.verifyDetail ?? "")" }
        if let v = item?.currentVersion { return "\(facts) · v\(v.number): \(v.verifyDetail ?? "")" }
        return "\(facts) · \(row.rel)"
    }

    private func rowChip(_ row: SourceAssessment.Row, _ item: ShowSpec.Item?) -> some View {
        let (label, color): (String, Color) = {
            if row.state == .excluded { return ("LEFT OUT", ARCTheme.textTertiary) }
            if row.state == .gone { return ("GONE FROM FOLDER", ARCTheme.warn) }
            if row.state == .changed { return ("CHANGED", ARCTheme.warn) }
            switch item?.status {
            case .ready?: return ("READY v\(item?.current ?? 0)", ARCTheme.readyGreen)
            case .failed?: return ("FAILED", ARCTheme.liveRed)
            case .updated?: return ("UPDATED", ARCTheme.warn)
            case .pending?, .captured?: return ("TO CAPTURE", ARCTheme.warn)
            default: return (row.state == .new ? "IN THE FOLDER" : "TO CAPTURE", ARCTheme.textSecondary)
            }
        }()
        return Text(label).font(ARCTheme.mono(10, .heavy)).foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color, lineWidth: 1)).fixedSize().frame(width: 140, alignment: .trailing)
    }

    // MARK: HOLDING SLIDE / PASSED OVER

    private func holding(_ store: ShowFolderStore) -> some View {
        let row = store.assessment?.included.first(where: \.isHolding)
        return VStack(spacing: 6) {
            Color.black.aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(HoldingThumb(bumper: store.bumperURL, source: row.flatMap { r in store.linkedSource.map { $0.resolvingSymlinksInPath().appendingPathComponent(r.rel) } }))
                .clipped().cornerRadius(3)
            Text(row.map { "\($0.id) \($0.title)" } ?? "NONE IN THE FOLDER: THE ARC MARK STANDS IN").font(ARCTheme.mono(11)).foregroundStyle(row == nil ? ARCTheme.warn : ARCTheme.textPrimary)
                .lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .arcModule(title: "HOLDING SLIDE", tint: ARCTheme.secBlue)
        .fixedSize(horizontal: false, vertical: true)      // as wide as its column, as tall as its picture ("hugging" let the picture's own width push it over the run order)
    }

    private func passedOver(_ store: ShowFolderStore) -> some View {
        let passed = store.assessment?.passedOver ?? []
        return VStack(alignment: .leading, spacing: 5) {
            if passed.isEmpty {
                Text("nothing").font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textTertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(passed) { p in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.rel).font(ARCTheme.mono(11)).foregroundStyle(ARCTheme.textPrimary).lineLimit(2)
                                Text(p.reason).font(ARCTheme.mono(10, .regular)).foregroundStyle(ARCTheme.textSecondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .arcModule(title: "PASSED OVER", tint: ARCTheme.secGreen, badge: ARCBandBadge(text: "\(passed.count)", fill: ARCTheme.text0))
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus").font(.system(size: 44)).foregroundStyle(ARCTheme.textTertiary)
            Text("OPEN THE FOLDER THE PRESENTATIONS ARE IN").font(ARCTheme.mono(16, .heavy)).foregroundStyle(ARCTheme.textPrimary)
            Text("A Google Drive folder (through Drive for Desktop), a share or a stick. It is only ever read.\nFiles named S1.1, S1.2 ... run in that order; \"S0.0 Holding Slide ...\" is the logo page; folders named archive or old are passed over.")
                .font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.textSecondary).multilineTextAlignment(.center)
            if let openError { Text(openError).font(ARCTheme.mono(12)).foregroundStyle(ARCTheme.warn) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .arcModule(title: "RUN ORDER", tint: ARCTheme.secOrange)
    }

    // MARK: ACTIVITY (what is running now, how far, STOP, and the log)

    private var activity: some View {
        let a = store?.activity
        let capturing = store?.busy == true && a?.step == .capture
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(a?.title ?? (store?.busy == true ? "Working…" : (store?.log.last?.trimmingCharacters(in: .whitespaces) ?? "IDLE")))
                        .font(ARCTheme.mono(a == nil && store?.busy != true ? 14 : 20, .heavy)).foregroundStyle(a == nil ? (store?.log.last.map(logColor) ?? ARCTheme.textTertiary) : ARCTheme.textPrimary).lineLimit(1)
                    Text(activityDetail(a, capturing: capturing)).font(ARCTheme.mono(13, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 10)
                if let a {
                    if a.count > 0 { Text("\(a.index) OF \(a.count)").font(ARCTheme.mono(20, .heavy)).foregroundStyle(ARCTheme.warn) }
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(elapsed(ctx.date.timeIntervalSince(a.started))).font(ARCTheme.mono(20, .heavy)).foregroundStyle(ARCTheme.textPrimary).frame(width: 92, alignment: .trailing)
                    }
                    if let store {
                        Button { store.stopRequested = true; store.say("STOP asked: the chain ends after the item it is on") } label: {
                            Text(store.stopRequested ? "STOPPING AFTER THIS ITEM" : "STOP AFTER THIS ITEM").font(ARCTheme.mono(13, .heavy)).foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 10).background(store.stopRequested ? ARCTheme.surfaceLight : ARCTheme.arcRed).cornerRadius(ARCTheme.cornerRadius)
                        }
                        .buttonStyle(.plain).disabled(store.stopRequested)
                        .help("A capture is never cut in the middle of a deck: it finishes the one it is on, then stops")
                    }
                }
            }
            if let a, a.count > 0 {
                // Whole items done, plus how far through the one that is running.
                let within = capturing && monitor.totalSlides > 0 ? Double(monitor.pptxSlide) / Double(monitor.totalSlides) : 0
                ProgressBar(fraction: (Double(a.index - 1) + min(max(within, 0), 1)) / Double(a.count)).frame(height: 10)
            }
            logPane
        }
        .arcModule(title: "ACTIVITY", tint: a == nil ? ARCTheme.secGreen : ARCTheme.secCrimson,
                   badge: a != nil ? ARCBandBadge(text: "HANDS OFF THE KEYBOARD AND MOUSE", fill: ARCTheme.warn) : nil)
    }

    private func activityDetail(_ a: ShowFolderStore.Activity?, capturing: Bool) -> String {
        guard let a else { return (store?.autoNote.isEmpty == false ? store?.autoNote : store?.status) ?? "Open a target folder to begin." }
        if capturing, monitor.totalSlides > 0 { return "\(a.detail) · slide \(monitor.pptxSlide) of \(monitor.totalSlides) · \(monitor.phase)" }
        return a.detail
    }

    private func elapsed(_ t: TimeInterval) -> String { String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60) }

    private var logPane: some View {
        let lines = store?.log ?? [], times = store?.logTimes ?? []
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        HStack(alignment: .top, spacing: 10) {
                            Text(i < times.count ? times[i].formatted(date: .omitted, time: .standard) : "").font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.textTertiary).frame(width: 92, alignment: .leading)
                            Text(l.trimmingCharacters(in: .whitespaces)).font(ARCTheme.mono(13, l.hasPrefix(" ") ? .regular : .bold)).foregroundStyle(logColor(l)).lineLimit(2)
                        }
                        .id(i)
                    }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(ARCTheme.ink).cornerRadius(3)
            .onChange(of: lines.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
        }
    }

    private func logColor(_ l: String) -> Color {
        if l.contains("FAIL") || l.contains("could not") || l.contains("not reachable") { return ARCTheme.liveRed }
        if l.contains("WARN") || l.contains("stopped") || l.contains("STOP") || l.contains("no holding slide") { return ARCTheme.warn }
        if l.contains("ready in") || l.contains("PASS") || l.contains("show deck:") || l.contains("combined deck:") || l.contains("open in Presenter") || l.contains("confirmed") { return ARCTheme.readyGreen }
        return ARCTheme.textPrimary
    }

    // MARK: Opening

    private func openTarget() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.resolvesAliases = false      // a Drive shortcut is a symlink: keep the path the TD picked
        panel.message = "The folder the presentations are in (it is only ever read)"
        panel.prompt = "Open Target Folder"
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        if FileManager.default.fileExists(atPath: drive.path) { panel.directoryURL = drive }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if ShowRouting.isShowFolder(url) { adopt(try? ShowFolderStore(folder: url)); return }      // they picked a show folder: open it
        do {
            let s = try ShowFolderStore.openTarget(url)
            store = s; ShowFolderStore.current = s; openError = nil
            Task { if s.linkedSource?.path != url.path { await s.linkSource(url) } else { await s.assess() } }
        } catch { openError = "could not open: \(error.localizedDescription)" }
    }

    /// The show is put away (its folder stays as it is) and is not restored at the next launch.
    private func closeShow() {
        store?.sourcePoll?.cancel()
        store = nil; ShowFolderStore.current = nil
        UserDefaults.standard.removeObject(forKey: ShowFolderStore.lastFolderKey)
    }

    private func openShow() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = ShowFolderStore.defaultParent
        panel.message = "Choose a show folder (it holds show.json, decks/ and arcdecks/)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adopt(try? ShowFolderStore(folder: url))
    }

    private var newShowSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NEW EMPTY SHOW").font(ARCTheme.mono(14)).foregroundStyle(ARCTheme.textPrimary)
            TextField("show name, e.g. 2026-01-15 Fall Conference Day 1", text: $newName).textFieldStyle(.roundedBorder).font(ARCTheme.mono(12, .regular)).frame(width: 440)
            Text("Created under \(ShowFolderStore.defaultParent.path). Drop decks into its decks/ folder, named 1.01, 1.02 ...").font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary)
            HStack {
                Spacer()
                Button("Cancel") { showNew = false }
                Button("Create") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    adopt(try? ShowFolderStore.create(name: name, date: nil))
                    showNew = false
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

}

private struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(ARCTheme.surfaceLight)
                RoundedRectangle(cornerRadius: 3).fill(ARCTheme.arcRed).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
    }
}

/// The holding slide as it will look: the captured page once there is one, the file's Quick Look picture before.
private struct HoldingThumb: View {
    let bumper: URL?
    let source: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { Image("ARCLogo").resizable().aspectRatio(contentMode: .fit).padding(40).opacity(0.5) }
        }
        .task(id: "\(bumper?.path ?? "")|\(source?.path ?? "")") {
            if let bumper, let i = NSImage(contentsOf: bumper) { image = i; return }
            guard let source else { image = Bumper.logoURL.flatMap { NSImage(contentsOf: $0) }; return }
            let request = QLThumbnailGenerator.Request(fileAt: source, size: CGSize(width: 640, height: 360), scale: 2, representationTypes: .thumbnail)
            image = (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request))?.nsImage ?? Bumper.logoURL.flatMap { NSImage(contentsOf: $0) }
        }
    }
}


/// A folder with a show.json IS a show folder: picked or dropped on the CAPTURE tab it opens in the SHOW tab.
/// It used to land in the old one-deck builder, which listed the show's own six subfolders as "6 ITEM(S)" and
/// offered BUILD SHOW FOLDER over them (2026-09-17: "is this the old version?").
@MainActor
enum ShowRouting {
    static let openShow = Notification.Name("ARCCaptureOpenShowFolder")
    static let openReview = Notification.Name("ARCCaptureOpenReview")
    static var pending: URL?
    static func isShowFolder(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent("show.json").path) }
    static func open(_ url: URL) { pending = url; NotificationCenter.default.post(name: openShow, object: nil) }
}
