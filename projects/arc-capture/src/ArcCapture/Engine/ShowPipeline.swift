//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// The SHOW tab as ONE road (2026-09-17: "it should go open target folder, assess files in folder,
/// identify holding slide, confirm sort, capture presentations, build 1 show deck (not individual presos),
/// then open in presenter"). Pure: facts in, the state of every step and the next thing to press out.
/// Nothing is remembered here; a step is done because of what is on disk, so a relaunch reads the same.
enum ShowPipeline {
    enum Step: Int, CaseIterable, Identifiable {
        case open, assess, agenda, holding, sort, capture, build, present
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .open: return "OPEN TARGET FOLDER"
            case .assess: return "ASSESS FILES"
            case .agenda: return "AGENDA"
            case .holding: return "HOLDING SLIDE"
            case .sort: return "CONFIRM RUN ORDER"
            case .capture: return "CAPTURE PRESENTATIONS"
            case .build: return "BUILD SHOW DECK"
            case .present: return "OPEN IN PRESENTER"
            }
        }
    }

    enum State: Equatable { case todo, ready, running, done, attention }

    struct Facts: Equatable {
        var hasShow = false
        /// Presentations the show will hold (planned from the source, or already in decks/), excluded ones not counted.
        var planned = 0
        var assessed = false
        /// The agenda deck read into the rundown: its run number and title; nil = none in the folder.
        var agendaDeck: String?
        var agendaCues = 0
        var agendaTalks = 0
        var agendaDays = 0
        /// Rows the rules (and the workstation) could not read: they are in REVIEW.
        var agendaRefused = 0
        var holdingSlide: String?
        var orderConfirmed = false
        /// The run order is not the one that was confirmed (a late file, a rename).
        var orderChanged = false
        /// Files in the source not yet copied into decks/.
        var toBringIn = 0
        var pending = 0
        var failed = 0
        var failedIDs: [String] = []
        /// Why the first failed item failed, from its report (plain words for the NEXT module).
        var failedDetail: String?
        var ready = 0
        /// Black pages nobody asked for, not yet decided in REVIEW: the build waits on them.
        var blackUndecided = 0
        var showDeckBuilt = false
        /// The show deck was built from the versions that are current now.
        var showDeckCurrent = false
        var presented = false
        var running: Step?
    }

    static func states(_ f: Facts) -> [Step: State] {
        var s: [Step: State] = [:]
        s[.open] = f.hasShow ? .done : .ready
        s[.assess] = !f.hasShow ? .todo : (f.assessed ? (f.planned > 0 ? .done : .attention) : .ready)
        // The agenda is read on its own after the assessment; none in the folder is allowed and said. Rows to check ask for attention.
        s[.agenda] = !f.assessed || f.planned == 0 ? .todo : (f.agendaDeck == nil ? .done : (f.agendaRefused > 0 ? .attention : .done))
        // No holding slide is allowed (the ARC mark stands in), but it is said, not hidden.
        s[.holding] = !f.assessed || f.planned == 0 ? .todo : (f.holdingSlide != nil ? .done : .attention)
        s[.sort] = !f.assessed || f.planned == 0 ? .todo : (f.orderConfirmed ? (f.orderChanged ? .attention : .done) : .ready)
        let captured = f.orderConfirmed && f.planned > 0 && f.toBringIn == 0 && f.pending == 0 && f.failed == 0 && f.ready > 0
        s[.capture] = !f.orderConfirmed ? .todo : (f.failed > 0 ? .attention : (captured ? .done : .ready))
        s[.build] = !captured ? .todo : (f.blackUndecided > 0 ? .attention : (f.showDeckCurrent ? .done : .ready))
        s[.present] = !(captured && f.showDeckCurrent) ? .todo : (f.presented ? .done : .ready)
        if let r = f.running { s[r] = .running }
        return s
    }

    /// The one thing to press next: the first step that is ready (or asks for attention and blocks the road).
    static func next(_ f: Facts) -> Step? {
        guard f.running == nil else { return nil }
        let s = states(f)
        for step in Step.allCases {
            switch s[step]! {
            case .ready: return step
            case .attention where step == .assess || step == .capture: return step     // nothing found / a capture failed: the road stops here
            case .attention where step == .sort: return step                           // the order changed: confirm it again
            case .attention where step == .build: return step                          // black pages undecided: the road stops here
            default: continue
            }
        }
        return nil
    }

    /// The NEXT module: what happened, why, the one thing to press, and the way round it when there is one
    /// (2026-09-19: "the next step should be obvious to the user"). Pure.
    struct Advice: Equatable {
        enum Alternative: Equatable { case leaveOutFailedAndBuild, confirmOrder, assess, openReview }
        var headline: String
        var why: String
        var primary: Step?
        var primaryTitle: String
        var alternative: Alternative?
        var alternativeTitle: String?
    }

    static func advice(_ f: Facts) -> Advice {
        if let r = f.running {
            return Advice(headline: "\(r.title.capitalized) is running", why: r == .capture ? "Hands off the keyboard and mouse until it finishes." : "It finishes on its own.", primary: nil, primaryTitle: "")
        }
        if !f.hasShow {
            return Advice(headline: "Open the folder the presentations are in", why: "A Google Drive folder, a share or a stick. It is only ever read.", primary: .open, primaryTitle: buttonTitle(.open, f))
        }
        if !f.assessed {
            return Advice(headline: "Assess the files", why: "Reads the listing only. Nothing is downloaded yet.", primary: .assess, primaryTitle: buttonTitle(.assess, f))
        }
        if f.planned == 0 {
            return Advice(headline: "No presentations found in the folder", why: "Decks, PDFs and Google Slides links count; folders named archive or old are passed over. Check the folder, then assess again.", primary: .assess, primaryTitle: "ASSESS AGAIN")
        }
        if f.orderChanged {
            return Advice(headline: "The folder changed since you confirmed the run order", why: "Check the list on the right, LEAVE OUT what does not belong, then confirm it again.", primary: .sort, primaryTitle: buttonTitle(.sort, f))
        }
        if !f.orderConfirmed {
            return Advice(headline: "Confirm the run order", why: "Check the list on the right, LEAVE OUT what does not belong, then confirm. Nothing is copied before this.", primary: .sort, primaryTitle: buttonTitle(.sort, f))
        }
        if f.failed > 0 {
            let ids = f.failedIDs.joined(separator: ", ")
            let others = f.ready
            return Advice(headline: "\(ids) failed to capture", why: (f.failedDetail ?? "the report says why") + ". RETRY captures \(f.failed == 1 ? "it" : "them") again whole.",
                          primary: .capture, primaryTitle: "RETRY \(ids)", alternative: .leaveOutFailedAndBuild,
                          alternativeTitle: others > 0 ? "LEAVE \(f.failed == 1 ? "IT" : "THEM") OUT, BUILD THE OTHER \(others)" : nil)
        }
        let toCapture = max(f.toBringIn, f.pending)
        if toCapture > 0 {
            return Advice(headline: "Capture \(toCapture) presentation\(toCapture == 1 ? "" : "s")", why: "Each one is played and recorded, one click at a time, then the show deck is built and opened in Presenter. Hands off the keyboard and mouse while it runs.",
                          primary: .capture, primaryTitle: buttonTitle(.capture, f))
        }
        if f.blackUndecided > 0 {
            return Advice(headline: "\(f.blackUndecided) black page\(f.blackUndecided == 1 ? "" : "s") nobody asked for", why: "The show will not be built over a black page. On the REVIEW tab decide each one: RECAPTURE it, or ACCEPT and the show carries a PROBLEM slide there that says the page was not captured. LEAVE IT BLACK only if black is what the deck means.",
                          primary: nil, primaryTitle: "", alternative: .openReview, alternativeTitle: "OPEN REVIEW")
        }
        if !f.showDeckCurrent {
            return Advice(headline: f.showDeckBuilt ? "Rebuild the show deck" : "Build the show deck", why: f.showDeckBuilt ? "The deck was built from versions that are not current now." : "ONE deck for the show, the holding slide between the talks, then open in Presenter.",
                          primary: .build, primaryTitle: buttonTitle(.build, f))
        }
        if !f.presented {
            return Advice(headline: "Open the show deck in Presenter", why: "One tab, in preview. TAKE puts it live.", primary: .present, primaryTitle: buttonTitle(.present, f))
        }
        return Advice(headline: "All done: the show deck is in Presenter", why: "A changed talk in the folder is brought in by SYNC (or by AUTO CAPTURE when armed), captured and staged again.", primary: nil, primaryTitle: "")
    }

    /// After the order is confirmed nothing needs a decision: capture, build and open run as one chain.
    static func chain(from step: Step) -> [Step] {
        switch step {
        case .capture: return [.capture, .build, .present]
        case .build: return [.build, .present]
        case .present: return [.present]
        default: return []
        }
    }

    static func buttonTitle(_ step: Step, _ f: Facts) -> String {
        switch step {
        case .open: return "OPEN TARGET FOLDER…"
        case .assess: return f.assessed ? "ASSESS AGAIN" : "ASSESS FILES"
        case .agenda: return "READ THE AGENDA"
        case .holding: return "HOLDING SLIDE"
        case .sort: return f.orderChanged ? "CONFIRM THE NEW RUN ORDER" : "CONFIRM RUN ORDER"
        case .capture:
            let n = max(f.toBringIn, f.pending + f.failed)
            return f.failed > 0 && f.pending == 0 && f.toBringIn == 0 ? "RETRY \(f.failed) FAILED, BUILD AND OPEN" : "CAPTURE \(n) PRESENTATION\(n == 1 ? "" : "S"), BUILD AND OPEN"
        case .build: return "BUILD SHOW DECK AND OPEN"
        case .present: return "OPEN IN PRESENTER"
        }
    }
}


/// AUTO CAPTURE: when the target folder changes, capture, rebuild the show deck and let Presenter stage it,
/// with nobody pressing anything. It takes over the Mac (PowerPoint plays full screen on the second display,
/// keys are sent), so it is ARMED by the TD, per show, and even armed it waits until nobody has touched the
/// keyboard or mouse for a minute. Pure, so the rules are tested.
enum AutoCapture {
    enum Decision: Equatable { case nothing, needsTD(String), waitForIdle(Int), run }
    /// Seconds of no keyboard and no mouse before it may start.
    static let idleNeeded = 60

    static func decide(armed: Bool, facts f: ShowPipeline.Facts, busy: Bool, idleSeconds: Int) -> Decision {
        guard armed, !busy, f.running == nil, f.orderConfirmed else { return .nothing }
        let work = f.toBringIn > 0 || f.pending > 0 || (f.ready > 0 && !f.showDeckCurrent)
        guard work else { return .nothing }
        // A NEW talk changes the run order: that is the TD's call, never the machine's. A changed talk is not.
        if f.orderChanged { return .needsTD("the run order changed: confirm it, then it runs") }
        if f.failed > 0 && f.pending == 0 && f.toBringIn == 0 { return .needsTD("a capture failed: it is not retried on its own") }
        return idleSeconds >= idleNeeded ? .run : .waitForIdle(idleNeeded - idleSeconds)
    }
}

/// Whether a presentation is the shape of the show (a 4:3 deck in a 16:9 show is pillarboxed in the room).
enum AspectCheck {
    /// The show's shape = the most common one among its talks; nil when nothing is known yet.
    static func showAspect(_ aspects: [Double]) -> Double? {
        let buckets = Dictionary(grouping: aspects.filter { $0 > 0.2 }, by: { ($0 * 20).rounded() / 20 })
        return buckets.max { a, b in a.value.count != b.value.count ? a.value.count < b.value.count : a.key < b.key }?.key
    }
    static func differs(_ a: Double, from show: Double) -> Bool { abs(a - show) / show > 0.04 }
    static func name(_ a: Double) -> String {
        for (r, n) in [(16.0 / 9.0, "16:9"), (4.0 / 3.0, "4:3"), (16.0 / 10.0, "16:10"), (1.0, "1:1"), (11.0 / 8.5, "LETTER"), (9.0 / 16.0, "9:16"), (21.0 / 9.0, "21:9")] where abs(a - r) / r < 0.025 { return n }
        return String(format: "%.2f:1", a)
    }
}
