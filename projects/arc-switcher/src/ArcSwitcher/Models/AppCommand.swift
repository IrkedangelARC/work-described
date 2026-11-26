//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Commands that can be sent to application sources.
enum AppCommand: String, CaseIterable, Codable, Identifiable {
    case nextSlide
    case previousSlide
    case startPresentation
    case stopPresentation
    case play
    case pause
    case stop
    case volumeUp
    case volumeDown
    case mute

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nextSlide: "Next Slide"
        case .previousSlide: "Previous Slide"
        case .startPresentation: "Start Presentation"
        case .stopPresentation: "Stop Presentation"
        case .play: "Play"
        case .pause: "Pause"
        case .stop: "Stop"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .mute: "Mute"
        }
    }

    var sfSymbol: String {
        switch self {
        case .nextSlide: "forward.fill"
        case .previousSlide: "backward.fill"
        case .startPresentation: "play.rectangle.fill"
        case .stopPresentation: "stop.fill"
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .stop: "stop.fill"
        case .volumeUp: "speaker.wave.3.fill"
        case .volumeDown: "speaker.wave.1.fill"
        case .mute: "speaker.slash.fill"
        }
    }

    /// Grouped for UI display
    static let slideCommands: [AppCommand] = [.previousSlide, .nextSlide, .startPresentation, .stopPresentation]
    static let transportCommands: [AppCommand] = [.play, .pause, .stop]
    static let volumeCommands: [AppCommand] = [.volumeDown, .volumeUp, .mute]
}
