//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

enum CueFormat: String, Codable, CaseIterable, Identifiable {
    case fireside
    case panel
    case keynote
    case lightning
    case remarks
    // 2026-09-24: "add Q&A, Workshop, Lab, Exercise and a custom that allows text".
    case qa
    case workshop
    case lab
    case exercise
    case social
    case transition
    case breakTime = "break"
    case greenRoom
    /// The operator's own text (Cue.customFormatLabel); "Custom" when left empty.
    case custom
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fireside: "Fireside"
        case .panel: "Panel"
        case .keynote: "Keynote"
        case .lightning: "Lightning"
        case .remarks: "Remarks"
        case .qa: "Q&A"
        case .workshop: "Workshop"
        case .lab: "Lab"
        case .exercise: "Exercise"
        case .custom: "Custom"
        case .social: "Social"
        case .transition: "Transition"
        case .breakTime: "Break"
        case .greenRoom: "Green Room"
        case .other: "Other"
        }
    }

    var icon: String {
        switch self {
        case .fireside: "flame"
        case .panel: "person.3"
        case .keynote: "star"
        case .lightning: "bolt"
        case .remarks: "mic"
        case .qa: "questionmark.bubble"
        case .workshop: "hammer"
        case .lab: "flask"
        case .exercise: "pencil.and.list.clipboard"
        case .custom: "tag"
        case .social: "wineglass"
        case .transition: "arrow.right"
        case .breakTime: "cup.and.saucer"
        case .greenRoom: "door.left.hand.open"
        case .other: "square"
        }
    }

    var defaultDurationSeconds: Int {
        switch self {
        case .fireside: 1800    // 30 min
        case .panel: 2700       // 45 min
        case .keynote: 1800     // 30 min
        case .lightning: 600    // 10 min
        case .remarks: 900     // 15 min
        case .qa: 900          // 15 min
        case .workshop: 3600   // 60 min
        case .lab: 3600        // 60 min
        case .exercise: 1200   // 20 min
        case .custom: 1800     // 30 min
        case .social: 3600     // 60 min
        case .transition: 300  // 5 min
        case .breakTime: 900   // 15 min
        case .greenRoom: 600   // 10 min
        case .other: 1800      // 30 min
        }
    }

    // MARK: - Compression (Phase 3)

    /// Compressible formats: breaks, transitions, social, green room — not content.
    var isCompressible: Bool {
        switch self {
        case .breakTime, .social, .transition, .greenRoom: return true
        default: return false
        }
    }

    /// Absolute floor — never compress below this.
    var minimumDurationSeconds: Int {
        isCompressible ? 300 : 600  // 5 min for breaks, 10 min for content
    }

    /// Maximum fraction of duration that can be cut.
    var maxCompressionRatio: Double {
        isCompressible ? 0.50 : 0.25  // 50% for breaks, 25% for content
    }
}
