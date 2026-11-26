//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Observation
import SwiftData

/// Driving the app with nobody at the keyboard: make a show, open it on the run screen, and leave it there to
/// be looked at. 2026-09-17: "give yourself the ability to make a test show, open it on the extended
/// monitors and review your work all by yourself."
///
/// The HTTP server and the launch flags cannot touch SwiftData or navigation; those belong to the views. So
/// they leave a REQUEST here and the show list, which has the model context and the navigation state, carries
/// it out and writes back what happened. One shared instance, main actor, no other state.
/// NOT @Observable, and the view reads none of it in its body. It was, and the read-then-mutate inside
/// `.task(id:)` kept SwiftUI re-running its first layout so the operator window never appeared at all
/// (2026-09-17). A request is a CALL: the view hands over closures once it exists, and anything asked for
/// before that waits in a queue.
@MainActor
final class Automation {
    static let shared = Automation()

    /// A show to build. The name is the key: building the same name twice replaces the first.
    struct TestShowRequest: Equatable, Sendable {
        var name: String
        var arcNumber: String?
        var cues: Int
        /// Seconds per cue, shortest first, so a review sees a warning and an overtime without waiting.
        var durations: [Int]
        var open: Bool
        /// Open the control-panel layout (the one with the output sections), not the standalone one.
        var extended: Bool = false
    }

    enum Request: Sendable {
        case testShow(TestShowRequest)
        case open(String)
        case close
        /// Open an OUTPUT window ("stage-display" or "confidence-output"). A headless run has no one to click
        /// the SEND chip, and the app only opens outputs for routes that are already configured.
        case openOutput(String)
    }

    /// Set once by the show list, which owns the model context and the navigation.
    private var handler: ((Request) -> Void)?
    private var queued: [Request] = []

    private(set) var lastAction: String = "nothing yet"
    private(set) var openShowName: String?
    private(set) var showNames: [String] = []

    /// The show list calls this when it appears. Anything asked for before then runs AFTER the first layout
    /// has settled: navigating straight out of `onAppear` left the app with no window at all (2026-09-17).
    func connect(_ handler: @escaping (Request) -> Void) {
        guard self.handler == nil else { return }
        self.handler = handler
        drainSoon()
    }

    func ask(_ request: Request) {
        queued.append(request)
        if handler != nil { drainSoon() }
    }

    private func drainSoon() {
        guard !draining, !queued.isEmpty else { return }
        draining = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let handler = self.handler else { return }
                self.draining = false
                let waiting = self.queued
                self.queued = []
                for request in waiting { handler(request) }
            }
        }
    }
    private var draining = false

    func note(_ action: String) { lastAction = action; StageLog.log("automation: \(action)"); publish() }
    func setOpenShow(_ name: String?) { openShowName = name; publish() }
    func setShowNames(_ names: [String]) { showNames = names; publish() }

    private func publish() {
        AutomationSnapshot.shared.set(.init(lastAction: lastAction, openShow: openShowName, shows: showNames))
    }

    /// A test show with a short cue, a medium one and a long one, so the colour states can all be seen.
    /// Pure and nonisolated: the HTTP server builds the request on its own queue and hands it over.
    nonisolated static func defaultTestShow(name: String = "ARC Style Review", cues: Int = 3) -> TestShowRequest {
        let pattern = [65, 20, 600, 300, 900, 120]      // seconds
        let durations = (0..<max(1, cues)).map { pattern[$0 % pattern.count] }
        return TestShowRequest(name: name, arcNumber: "ARC-TEST", cues: max(1, cues), durations: durations, open: true, extended: StageTimerLaunch.wantsExtended)
    }
}

/// Building and finding shows: the part that needs a model context but not the views.
enum AutomationShows {
    /// Build (or rebuild) a test show and return it. Any existing show of the same name is deleted first, so
    /// running the same command twice does not leave two.
    @MainActor
    @discardableResult
    static func makeTestShow(_ request: Automation.TestShowRequest, in context: ModelContext) -> Show? {
        let name = request.name
        if let existing = try? context.fetch(FetchDescriptor<Show>(predicate: #Predicate { $0.name == name })) {
            for show in existing { context.delete(show) }
        }
        let show = Show(name: request.name, arcNumber: request.arcNumber, date: .now, venue: "Mac Studio",
                        notes: "Built by the automation bridge for a style review.")
        context.insert(show)
        let titles = ["Opening Remarks", "Main Presentation", "Panel Discussion", "Break", "Closing and Q&A", "Awards"]
        let speakers = ["Speaker One", "Speaker Two", "The Panel", nil, "All Speakers", "The Committee"]
        for i in 0..<request.cues {
            let seconds = i < request.durations.count ? request.durations[i] : 300
            let cue = Cue(title: titles[i % titles.count], sortOrder: i,
                          subtitle: i == 0 ? "the first cue is short on purpose: it reaches warning and overtime while you watch" : nil,
                          speakers: speakers[i % speakers.count],
                          durationSeconds: seconds,
                          warningThreshold: min(120, max(10, seconds / 3)),
                          dangerThreshold: min(30, max(5, seconds / 6)))
            cue.show = show
            context.insert(cue)
        }
        try? context.save()
        return show
    }

    @MainActor
    static func show(named name: String, in context: ModelContext) -> Show? {
        (try? context.fetch(FetchDescriptor<Show>(predicate: #Predicate { $0.name == name })))?.first
    }
}

/// What the automation bridge last did, readable from the HTTP server's own queue (the bridge itself is main
/// actor state). Same shape as DisplaySnapshot, same reason.
final class AutomationSnapshot: @unchecked Sendable {
    struct State: Sendable { var lastAction: String = "nothing yet"; var openShow: String?; var shows: [String] = [] }
    static let shared = AutomationSnapshot()
    private let lock = NSLock()
    private var state = State()
    var current: State { lock.lock(); defer { lock.unlock() }; return state }
    func set(_ new: State) { lock.lock(); state = new; lock.unlock() }
}
