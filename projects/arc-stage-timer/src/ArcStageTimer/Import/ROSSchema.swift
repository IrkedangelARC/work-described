//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

// MARK: - ARC ROS JSON Schema (matches arc-events export format)

struct ROSDocument: Codable {
    let event_name: String?
    let arc_number: String?
    let event_date: String?
    let venue: String?
    let sessions: [ROSSession]?
    let notes: String?

    // Alternative key names for flexibility
    let eventName: String?
    let arcNumber: String?
    let eventDate: String?

    private enum CodingKeys: String, CodingKey {
        case event_name, arc_number, event_date, venue, sessions, notes
        case eventName, arcNumber, eventDate
    }

    // MARK: - Decode (supports both snake_case and camelCase)

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event_name = try c.decodeIfPresent(String.self, forKey: .event_name)
        arc_number = try c.decodeIfPresent(String.self, forKey: .arc_number)
        event_date = try c.decodeIfPresent(String.self, forKey: .event_date)
        venue = try c.decodeIfPresent(String.self, forKey: .venue)
        sessions = try c.decodeIfPresent([ROSSession].self, forKey: .sessions)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        eventName = try c.decodeIfPresent(String.self, forKey: .eventName)
        arcNumber = try c.decodeIfPresent(String.self, forKey: .arcNumber)
        eventDate = try c.decodeIfPresent(String.self, forKey: .eventDate)
    }

    // MARK: - Memberwise init (for programmatic construction)

    init(
        event_name: String? = nil,
        arc_number: String? = nil,
        event_date: String? = nil,
        venue: String? = nil,
        sessions: [ROSSession]? = nil,
        notes: String? = nil
    ) {
        self.event_name = event_name
        self.arc_number = arc_number
        self.event_date = event_date
        self.venue = venue
        self.sessions = sessions
        self.notes = notes
        self.eventName = nil
        self.arcNumber = nil
        self.eventDate = nil
    }

    // MARK: - Encode (snake_case canonical output)

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(event_name ?? eventName, forKey: .event_name)
        try c.encodeIfPresent(arc_number ?? arcNumber, forKey: .arc_number)
        try c.encodeIfPresent(event_date ?? eventDate, forKey: .event_date)
        try c.encodeIfPresent(venue, forKey: .venue)
        try c.encodeIfPresent(sessions, forKey: .sessions)
        try c.encodeIfPresent(notes, forKey: .notes)
    }

    var resolvedName: String { event_name ?? eventName ?? "Untitled Show" }
    var resolvedArcNumber: String? { arc_number ?? arcNumber }
    var resolvedDate: String? { event_date ?? eventDate }
}

struct ROSSession: Codable {
    let time_range: String?
    let session_title: String?
    let subtitle: String?
    let speakers: String?
    let format: String?
    let duration_minutes: Int?
    let mic_count: Int?
    let notes: String?
    let is_break: Bool?
    let is_transition: Bool?

    // Alternative keys
    let timeRange: String?
    let sessionTitle: String?
    let durationMinutes: Int?
    let micCount: Int?
    let isBreak: Bool?
    let isTransition: Bool?

    private enum CodingKeys: String, CodingKey {
        case time_range, session_title, subtitle, speakers, format
        case duration_minutes, mic_count, notes, is_break, is_transition
        case timeRange, sessionTitle, durationMinutes, micCount, isBreak, isTransition
    }

    // MARK: - Decode

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time_range = try c.decodeIfPresent(String.self, forKey: .time_range)
        session_title = try c.decodeIfPresent(String.self, forKey: .session_title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        speakers = try c.decodeIfPresent(String.self, forKey: .speakers)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        duration_minutes = try c.decodeIfPresent(Int.self, forKey: .duration_minutes)
        mic_count = try c.decodeIfPresent(Int.self, forKey: .mic_count)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        is_break = try c.decodeIfPresent(Bool.self, forKey: .is_break)
        is_transition = try c.decodeIfPresent(Bool.self, forKey: .is_transition)
        timeRange = try c.decodeIfPresent(String.self, forKey: .timeRange)
        sessionTitle = try c.decodeIfPresent(String.self, forKey: .sessionTitle)
        durationMinutes = try c.decodeIfPresent(Int.self, forKey: .durationMinutes)
        micCount = try c.decodeIfPresent(Int.self, forKey: .micCount)
        isBreak = try c.decodeIfPresent(Bool.self, forKey: .isBreak)
        isTransition = try c.decodeIfPresent(Bool.self, forKey: .isTransition)
    }

    // MARK: - Memberwise init

    init(
        time_range: String? = nil,
        session_title: String? = nil,
        subtitle: String? = nil,
        speakers: String? = nil,
        format: String? = nil,
        duration_minutes: Int? = nil,
        mic_count: Int? = nil,
        notes: String? = nil,
        is_break: Bool? = nil,
        is_transition: Bool? = nil
    ) {
        self.time_range = time_range
        self.session_title = session_title
        self.subtitle = subtitle
        self.speakers = speakers
        self.format = format
        self.duration_minutes = duration_minutes
        self.mic_count = mic_count
        self.notes = notes
        self.is_break = is_break
        self.is_transition = is_transition
        self.timeRange = nil
        self.sessionTitle = nil
        self.durationMinutes = nil
        self.micCount = nil
        self.isBreak = nil
        self.isTransition = nil
    }

    // MARK: - Encode (snake_case canonical output)

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(time_range ?? timeRange, forKey: .time_range)
        try c.encodeIfPresent(session_title ?? sessionTitle, forKey: .session_title)
        try c.encodeIfPresent(subtitle, forKey: .subtitle)
        try c.encodeIfPresent(speakers, forKey: .speakers)
        try c.encodeIfPresent(format, forKey: .format)
        try c.encodeIfPresent(duration_minutes ?? durationMinutes, forKey: .duration_minutes)
        try c.encodeIfPresent(mic_count ?? micCount, forKey: .mic_count)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(is_break ?? isBreak, forKey: .is_break)
        try c.encodeIfPresent(is_transition ?? isTransition, forKey: .is_transition)
    }

    var resolvedTitle: String { session_title ?? sessionTitle ?? "Untitled" }
    var resolvedTimeRange: String? { time_range ?? timeRange }
    var resolvedDurationMinutes: Int? { duration_minutes ?? durationMinutes }
    var resolvedMicCount: Int? { mic_count ?? micCount }
    var resolvedIsBreak: Bool { is_break ?? isBreak ?? false }
    var resolvedIsTransition: Bool { is_transition ?? isTransition ?? false }
}
