//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

enum ROSImportError: LocalizedError {
    case invalidJSON
    case noSessions
    case dateParseFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON: "Invalid JSON format"
        case .noSessions: "No sessions found in ROS data"
        case .dateParseFailure(let s): "Could not parse date: \(s)"
        }
    }
}

enum ROSImporter {

    /// Import a Show from ARC ROS JSON data
    static func importShow(from data: Data) throws -> Show {
        let decoder = JSONDecoder()
        let doc = try decoder.decode(ROSDocument.self, from: data)

        guard let sessions = doc.sessions, !sessions.isEmpty else {
            throw ROSImportError.noSessions
        }

        let showDate = parseDate(doc.resolvedDate) ?? .now

        let show = Show(
            name: doc.resolvedName,
            arcNumber: doc.resolvedArcNumber,
            date: showDate,
            venue: doc.venue
        )

        var cues: [Cue] = []
        for (index, session) in sessions.enumerated() {
            let cue = mapSessionToCue(session, sortOrder: index, showDate: showDate)
            cues.append(cue)
        }

        show.cues = cues
        return show
    }

    // MARK: - Private

    private static func mapSessionToCue(_ session: ROSSession, sortOrder: Int, showDate: Date) -> Cue {
        let format = resolveFormat(session)
        let duration = resolveDuration(session)
        let startTime = parseStartTime(session.resolvedTimeRange, baseDate: showDate)

        var noteParts: [String] = []
        if let mic = session.resolvedMicCount, mic > 0 {
            noteParts.append("Mics: \(mic)")
        }
        if let n = session.notes, !n.isEmpty {
            noteParts.append(n)
        }

        return Cue(
            title: session.resolvedTitle,
            sortOrder: sortOrder,
            subtitle: session.subtitle,
            format: format,
            speakers: session.speakers,
            startTime: startTime,
            durationSeconds: duration,
            notes: noteParts.isEmpty ? nil : noteParts.joined(separator: " | ")
        )
    }

    private static func resolveFormat(_ session: ROSSession) -> CueFormat {
        if session.resolvedIsBreak { return .breakTime }
        if session.resolvedIsTransition { return .transition }

        guard let fmt = session.format?.lowercased() else { return .other }
        switch fmt {
        case "fireside", "fireside chat": return .fireside
        case "panel", "panel discussion": return .panel
        case "keynote", "keynote address": return .keynote
        case "lightning", "lightning talk": return .lightning
        case "remarks", "opening remarks", "closing remarks": return .remarks
        case "social", "networking", "reception": return .social
        case "transition": return .transition
        case "break", "coffee break", "lunch": return .breakTime
        case "green room", "greenroom": return .greenRoom
        case "q&a", "qa", "q & a", "q and a", "questions": return .qa
        case "workshop": return .workshop
        case "lab": return .lab
        case "exercise", "activity": return .exercise
        case "custom": return .custom
        default: return .other
        }
    }

    private static func resolveDuration(_ session: ROSSession) -> Int {
        // Explicit duration takes priority
        if let mins = session.resolvedDurationMinutes, mins > 0 {
            return mins * 60
        }
        // Try to compute from time range
        if let range = session.resolvedTimeRange {
            if let duration = parseDurationFromTimeRange(range) {
                return duration
            }
        }
        // Fallback to format default
        return resolveFormat(session).defaultDurationSeconds
    }

    /// Parse "9:00 AM - 9:45 AM" → duration in seconds
    private static func parseDurationFromTimeRange(_ range: String) -> Int? {
        let parts = range.components(separatedBy: " - ")
        guard parts.count == 2 else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // Try multiple formats
        for fmt in ["h:mm a", "HH:mm", "h:mma", "H:mm"] {
            formatter.dateFormat = fmt
            if let start = formatter.date(from: parts[0].trimmingCharacters(in: .whitespaces)),
               let end = formatter.date(from: parts[1].trimmingCharacters(in: .whitespaces)) {
                let interval = end.timeIntervalSince(start)
                if interval > 0 {
                    return Int(interval)
                }
            }
        }
        return nil
    }

    /// Parse start time from "9:00 AM - 9:45 AM" given a base date
    private static func parseStartTime(_ range: String?, baseDate: Date) -> Date? {
        guard let range else { return nil }
        let parts = range.components(separatedBy: " - ")
        guard let startStr = parts.first?.trimmingCharacters(in: .whitespaces) else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for fmt in ["h:mm a", "HH:mm", "h:mma", "H:mm"] {
            formatter.dateFormat = fmt
            if let time = formatter.date(from: startStr) {
                let calendar = Calendar.current
                let timeComponents = calendar.dateComponents([.hour, .minute], from: time)
                return calendar.date(bySettingHour: timeComponents.hour ?? 0,
                                     minute: timeComponents.minute ?? 0,
                                     second: 0,
                                     of: baseDate)
            }
        }
        return nil
    }

    /// Parse date string in common formats
    private static func parseDate(_ dateStr: String?) -> Date? {
        guard let dateStr else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for fmt in ["yyyy-MM-dd", "MM/dd/yyyy", "MMMM d, yyyy", "MMM d, yyyy", "MM-dd-yyyy"] {
            formatter.dateFormat = fmt
            if let date = formatter.date(from: dateStr) {
                return date
            }
        }
        return nil
    }

    // MARK: - Export

    /// Export a Show to ARC ROS JSON data for backup/sharing
    static func exportShow(_ show: Show) -> Data? {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "h:mm a"

        let sessions: [[String: Any]] = show.sortedCues.map { cue in
            var session: [String: Any] = [
                "title": cue.title,
                "duration_seconds": cue.durationSeconds,
                "format": cue.format.rawValue,
                "sort_order": cue.sortOrder,
                "overtime_allowed": cue.overtimeAllowed,
                "warning_threshold": cue.warningThreshold,
                "danger_threshold": cue.dangerThreshold
            ]
            if let subtitle = cue.subtitle { session["subtitle"] = subtitle }
            if let speakers = cue.speakers { session["speakers"] = speakers }
            if let notes = cue.notes { session["notes"] = notes }
            if let startTime = cue.startTime {
                session["start_time"] = timeFormatter.string(from: startTime)
                let endTime = startTime.addingTimeInterval(Double(cue.durationSeconds))
                session["time_range"] = "\(timeFormatter.string(from: startTime)) - \(timeFormatter.string(from: endTime))"
            }
            return session
        }

        var doc: [String: Any] = [
            "event_name": show.name,
            "event_date": dateFormatter.string(from: show.date),
            "sessions": sessions
        ]
        if let arc = show.arcNumber { doc["arc_number"] = arc }
        if let venue = show.venue { doc["venue"] = venue }
        if let notes = show.notes { doc["notes"] = notes }

        return try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    }
}
