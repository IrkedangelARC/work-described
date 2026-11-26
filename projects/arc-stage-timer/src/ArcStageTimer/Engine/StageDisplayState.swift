//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

// MARK: - Cue Snapshot (value type for network transport — no SwiftData dependency)

struct CueSnapshot: Codable, Sendable {
    let title: String
    let subtitle: String?
    let speakers: String?
    let durationSeconds: Int
    let warningThreshold: Int
    let dangerThreshold: Int

    init(from cue: Cue) {
        title = cue.title
        subtitle = cue.subtitle
        speakers = cue.speakers
        durationSeconds = cue.durationSeconds
        warningThreshold = cue.warningThreshold
        dangerThreshold = cue.dangerThreshold
    }

    init(title: String, subtitle: String? = nil, speakers: String? = nil,
         durationSeconds: Int = 0, warningThreshold: Int = 120, dangerThreshold: Int = 30) {
        self.title = title
        self.subtitle = subtitle
        self.speakers = speakers
        self.durationSeconds = durationSeconds
        self.warningThreshold = warningThreshold
        self.dangerThreshold = dangerThreshold
    }
}

// MARK: - Stage Display State (unified model for local and remote display)

/// Single @Observable consumed by StageDisplayView.
/// In controller mode, a LocalStageDisplayBridge syncs from TimerEngine + StageDirector.
/// In client mode, RemoteTimerState populates from SSE stream.
@Observable
final class StageDisplayState {

    // Timer state
    var colorState: TimerColorState = .idle
    var displayTime: String = "00:00"
    var isOvertime: Bool = false
    var progress: Double = 0
    var remainingSeconds: Int = 0
    var elapsedSeconds: Int = 0
    var state: String = "idle"

    // Schedule offset
    var isScheduledShow: Bool = false
    var showStartedAt: Date?
    var showOffsetDisplay: String = "ON TIME"
    var offsetStatus: OffsetStatus = .onTime

    // The show, for the stage footer
    var showName: String = ""
    var showArcNumber: String?

    // Cue info
    var currentCueSnapshot: CueSnapshot?
    var nextCueSnapshot: CueSnapshot?
    var cueIndex: Int = 0
    var cueCount: Int = 0
    var hasNext: Bool = false
    var hasPrevious: Bool = false

    // Stage director state
    var stageMode: StageMode = .timer
    var holdEventName: String = ""
    var message: String?
    var messageOpacity: Double = 0
    /// The TEXT ALERT banner (StageDirector.alert): stays until cleared.
    var alert: String?
    var flashColor: Color?
    var flashOpacity: Double = 0

    // Display color scheme, and the CONFIDENCE MONITOR layout. Both remembered on this Mac (they were
    // lost at every launch). didSet only writes the default; it never assigns the property back, so it
    // cannot recurse through the @Observable setter.
    var colorScheme: DisplayColorScheme = UserDefaults.standard.string(forKey: "stageColorScheme")
        .flatMap(DisplayColorScheme.init(rawValue:)) ?? .arcDefault {
        didSet { UserDefaults.standard.set(colorScheme.rawValue, forKey: "stageColorScheme") }
    }
    var stageLayout: StageLayout = StageLayout.saved {
        didSet { UserDefaults.standard.set(stageLayout.rawValue, forKey: StageLayout.defaultsKey) }
    }

    // Sequence counters for reliable remote detection
    var flashSequence: Int = 0
    var messageSequence: Int = 0

    // Local animation tasks (iPad runs its own animations)
    var messageAutoFadeTask: Task<Void, Never>?
    var flashAutoFadeTask: Task<Void, Never>?
    private var lastSeenFlashSequence: Int = 0
    private var lastSeenMessageSequence: Int = 0

    // MARK: - Sync from local engine + director (controller mode)

    func syncFromLocal(engine: TimerEngine, director: StageDirector) {
        colorState = engine.colorState
        displayTime = engine.displayTime
        isOvertime = engine.isOvertime
        progress = engine.progress
        remainingSeconds = engine.remainingSeconds
        elapsedSeconds = engine.elapsedSeconds
        state = engine.state.rawValue

        isScheduledShow = engine.isScheduledShow
        showStartedAt = engine.showStartedAt
        showOffsetDisplay = engine.showOffsetDisplay
        offsetStatus = engine.offsetStatus

        if let cue = engine.currentCue {
            currentCueSnapshot = CueSnapshot(from: cue)
        } else {
            currentCueSnapshot = nil
        }
        if let cue = engine.nextCue {
            nextCueSnapshot = CueSnapshot(from: cue)
        } else {
            nextCueSnapshot = nil
        }
        showName = engine.showName
        showArcNumber = engine.showArcNumber
        cueIndex = engine.currentCueIndex
        cueCount = engine.cues.count
        hasNext = engine.hasNext
        hasPrevious = engine.hasPrevious

        stageMode = director.stageMode
        holdEventName = director.holdEventName
        message = director.message
        messageOpacity = director.messageOpacity
        if alert != director.alert { alert = director.alert }
        flashColor = director.flashColor
        flashOpacity = director.flashOpacity
        flashSequence = director.flashSequence
        messageSequence = director.messageSequence
    }

    // MARK: - Update from SSE JSON (client mode)

    func update(from json: [String: Any]) {
        if let a = json["alert"] as? String { alert = a.isEmpty ? nil : a }
        if let s = json["colorScheme"] as? String,
           let scheme = DisplayColorScheme(rawValue: s) {
            colorScheme = scheme
        }
        if let s = json["stageLayout"] as? String, let layout = StageLayout(rawValue: s), layout != stageLayout {
            stageLayout = layout
        }
        if let s = json["colorState"] as? String {
            colorState = TimerColorState.from(string: s)
        }
        if let s = json["displayTime"] as? String { displayTime = s }
        if let b = json["isOvertime"] as? Bool { isOvertime = b }
        if let d = json["progress"] as? Double { progress = d }
        if let i = json["remainingSeconds"] as? Int { remainingSeconds = i }
        if let i = json["elapsedSeconds"] as? Int { elapsedSeconds = i }
        if let s = json["state"] as? String { state = s }

        if let b = json["isScheduledShow"] as? Bool { isScheduledShow = b }
        if let s = json["showOffsetDisplay"] as? String { showOffsetDisplay = s }
        if let s = json["offsetStatus"] as? String {
            offsetStatus = OffsetStatus.from(string: s)
        }

        if let s = json["cueTitle"] as? String, !s.isEmpty {
            currentCueSnapshot = CueSnapshot(
                title: s,
                subtitle: json["cueSubtitle"] as? String,
                speakers: json["cueSpeakers"] as? String,
                durationSeconds: json["cueDurationSeconds"] as? Int ?? 0,
                warningThreshold: json["cueWarningThreshold"] as? Int ?? 120,
                dangerThreshold: json["cueDangerThreshold"] as? Int ?? 30
            )
        } else {
            currentCueSnapshot = nil
        }

        if let s = json["nextCueTitle"] as? String, !s.isEmpty {
            nextCueSnapshot = CueSnapshot(
                title: s,
                subtitle: json["nextCueSubtitle"] as? String,
                speakers: json["nextCueSpeakers"] as? String
            )
        } else {
            nextCueSnapshot = nil
        }

        if let i = json["cueIndex"] as? Int { cueIndex = i }
        if let i = json["cueCount"] as? Int { cueCount = i }
        if let b = json["hasNext"] as? Bool { hasNext = b }
        if let b = json["hasPrevious"] as? Bool { hasPrevious = b }

        if let s = json["stageMode"] as? String {
            stageMode = StageMode(rawValue: s) ?? .timer
        }
        if let s = json["holdEventName"] as? String { holdEventName = s }

        // Message — sequence-based detection for reliable iPad animation
        if let seq = json["messageSequence"] as? Int, seq != lastSeenMessageSequence {
            lastSeenMessageSequence = seq
            if let s = json["message"] as? String, !s.isEmpty {
                messageAutoFadeTask?.cancel()
                message = s
                withAnimation(.easeIn(duration: 0.2)) { messageOpacity = 1 }
                messageAutoFadeTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.5)) { messageOpacity = 0 }
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    message = nil
                }
            } else {
                messageAutoFadeTask?.cancel()
                withAnimation(.easeOut(duration: 0.5)) { messageOpacity = 0 }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    message = nil
                }
            }
        }

        // Flash — sequence-based detection for reliable iPad animation
        if let seq = json["flashSequence"] as? Int, seq != lastSeenFlashSequence {
            lastSeenFlashSequence = seq
            if let s = json["flashColor"] as? String, !s.isEmpty {
                let newColor = Color.from(name: s)
                flashAutoFadeTask?.cancel()
                flashColor = newColor
                flashOpacity = 0.8
                flashAutoFadeTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.8)) { flashOpacity = 0 }
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled else { return }
                    flashColor = nil
                }
            }
        }
    }

    // MARK: - Serialize to JSON (for SSE broadcast)

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "ok": true,
            "state": state,
            "colorState": colorState.stringValue,
            "displayTime": displayTime,
            "isOvertime": isOvertime,
            "progress": progress,
            "remainingSeconds": remainingSeconds,
            "elapsedSeconds": elapsedSeconds,
            "cueIndex": cueIndex,
            "cueCount": cueCount,
            "hasNext": hasNext,
            "hasPrevious": hasPrevious,
            "isScheduledShow": isScheduledShow,
            "showOffsetDisplay": showOffsetDisplay,
            "offsetStatus": offsetStatus.stringValue,
            "stageMode": stageMode.rawValue,
            "holdEventName": holdEventName,
            "messageOpacity": messageOpacity,
            "flashOpacity": flashOpacity,
            "flashSequence": flashSequence,
            "messageSequence": messageSequence,
            "colorScheme": colorScheme.rawValue,
            "stageLayout": stageLayout.rawValue,
        ]

        if let snap = currentCueSnapshot {
            json["cueTitle"] = snap.title
            json["cueSubtitle"] = snap.subtitle
            json["cueSpeakers"] = snap.speakers
            json["cueDurationSeconds"] = snap.durationSeconds
            json["cueWarningThreshold"] = snap.warningThreshold
            json["cueDangerThreshold"] = snap.dangerThreshold
        } else {
            json["cueTitle"] = ""
        }

        if let snap = nextCueSnapshot {
            json["nextCueTitle"] = snap.title
            json["nextCueSubtitle"] = snap.subtitle
            json["nextCueSpeakers"] = snap.speakers
        } else {
            json["nextCueTitle"] = ""
        }

        if let msg = message {
            json["message"] = msg
        } else {
            json["message"] = ""
        }

        if let color = flashColor {
            json["flashColor"] = color.nameString
        } else {
            json["flashColor"] = ""
        }

        // TEXT ALERT (2026-09-24): the web stage display and the iPad client show it as the native output does.
        json["alert"] = alert ?? ""

        return json
    }
}

// MARK: - String ↔ Enum Extensions

extension TimerColorState {
    var stringValue: String {
        switch self {
        case .idle: "idle"
        case .nominal: "nominal"
        case .warning: "warning"
        case .danger: "danger"
        case .overtime: "overtime"
        }
    }

    static func from(string: String) -> TimerColorState {
        switch string {
        case "nominal": .nominal
        case "warning": .warning
        case "danger": .danger
        case "overtime": .overtime
        default: .idle
        }
    }
}

extension OffsetStatus {
    var stringValue: String {
        switch self {
        case .onTime: "onTime"
        case .ahead: "ahead"
        case .behind: "behind"
        case .wayBehind: "wayBehind"
        }
    }

    static func from(string: String) -> OffsetStatus {
        switch string {
        case "ahead": .ahead
        case "behind": .behind
        case "wayBehind": .wayBehind
        default: .onTime
        }
    }
}

extension Color {
    static func from(name: String) -> Color {
        switch name.lowercased() {
        case "red": .red
        case "yellow": .yellow
        case "green": .green
        case "white": .white
        case "blue": .blue
        default: .clear
        }
    }

    var nameString: String {
        switch self {
        case .red: "red"
        case .yellow: "yellow"
        case .green: "green"
        case .white: "white"
        case .blue: "blue"
        default: ""
        }
    }
}
