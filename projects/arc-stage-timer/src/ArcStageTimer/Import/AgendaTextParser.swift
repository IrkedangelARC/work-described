//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Pure Swift regex parser that converts pasted agenda text into a ROSDocument.
/// Pipeline: parse() → JSONEncoder → ROSImporter.importShow(from:)
enum AgendaTextParser {

    /// Parse raw agenda text into a ROSDocument. Returns nil if no sessions found.
    static func parse(_ text: String, eventName: String? = nil) -> ROSDocument? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var sessions: [ROSSession] = []
        for line in lines {
            if let session = parseLine(line) {
                sessions.append(session)
            }
        }

        guard !sessions.isEmpty else { return nil }

        return ROSDocument(
            event_name: eventName,
            sessions: sessions
        )
    }

    // MARK: - Line Parsing (cascade from most specific to least)

    private static func parseLine(_ line: String) -> ROSSession? {
        // Pattern 1: "9:00 AM - 9:45 AM  Session Title" (full range with AM/PM)
        if let session = parseFullRange(line) { return session }
        // Pattern 2: "9:00-9:45  Session Title" or "09:00-09:45  Session Title" (bare range)
        if let session = parseBareRange(line) { return session }
        // Pattern 3: "9:00 AM | Session Title" or "9:00 AM — Session Title" (single time + separator)
        if let session = parseSingleTime(line) { return session }
        // Pattern 4: "* 9:00 AM Session Title" or "- 9:00 AM Session Title" (bullet + time)
        if let session = parseBulletTime(line) { return session }
        // Pattern 5: "Session Title (45 min)" or "Session Title [30m]" (duration hint, no time)
        if let session = parseDurationHint(line) { return session }
        return nil
    }

    // MARK: - Pattern 1: Full time range with AM/PM

    private static func parseFullRange(_ line: String) -> ROSSession? {
        // Matches: 9:00 AM - 9:45 AM  Title   or   9:00AM-9:45AM Title
        let pattern = #"^(\d{1,2}:\d{2}\s*[AaPp][Mm])\s*[-–—]\s*(\d{1,2}:\d{2}\s*[AaPp][Mm])\s+(.+)$"#
        guard line.range(of: pattern, options: .regularExpression) != nil else { return nil }

        let parts = extractRangeParts(line, pattern: pattern)
        guard parts.count == 3 else { return nil }

        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        let endStr = parts[1].trimmingCharacters(in: .whitespaces)
        let title = parts[2].trimmingCharacters(in: .whitespaces)
        let timeRange = "\(normalizeTime(startStr)) - \(normalizeTime(endStr))"
        let duration = durationFromRange(start: startStr, end: endStr)

        return ROSSession(
            time_range: timeRange,
            session_title: cleanTitle(title),
            format: inferFormat(title),
            duration_minutes: duration.map { $0 / 60 }
        )
    }

    // MARK: - Pattern 2: Bare time range (24h or no AM/PM)

    private static func parseBareRange(_ line: String) -> ROSSession? {
        let pattern = #"^(\d{1,2}:\d{2})\s*[-–—]\s*(\d{1,2}:\d{2})\s+(.+)$"#
        let parts = extractRangeParts(line, pattern: pattern)
        guard parts.count == 3 else { return nil }

        let startStr = parts[0]
        let endStr = parts[1]
        let title = parts[2].trimmingCharacters(in: .whitespaces)
        let timeRange = "\(startStr) - \(endStr)"
        let duration = durationFromRange(start: startStr, end: endStr)

        return ROSSession(
            time_range: timeRange,
            session_title: cleanTitle(title),
            format: inferFormat(title),
            duration_minutes: duration.map { $0 / 60 }
        )
    }

    // MARK: - Pattern 3: Single time + separator + title

    private static func parseSingleTime(_ line: String) -> ROSSession? {
        let pattern = #"^(\d{1,2}:\d{2}\s*(?:[AaPp][Mm])?)\s*[|—–:]\s+(.+)$"#
        let parts = extractRangeParts(line, pattern: pattern)
        guard parts.count == 2 else { return nil }

        let timeStr = normalizeTime(parts[0].trimmingCharacters(in: .whitespaces))
        let title = parts[1].trimmingCharacters(in: .whitespaces)

        return ROSSession(
            time_range: timeStr,
            session_title: cleanTitle(title),
            format: inferFormat(title)
        )
    }

    // MARK: - Pattern 4: Bullet + time + title

    private static func parseBulletTime(_ line: String) -> ROSSession? {
        let pattern = #"^[*\-•]\s+(\d{1,2}:\d{2}\s*(?:[AaPp][Mm])?)\s+(.+)$"#
        let parts = extractRangeParts(line, pattern: pattern)
        guard parts.count == 2 else { return nil }

        let timeStr = normalizeTime(parts[0].trimmingCharacters(in: .whitespaces))
        let title = parts[1].trimmingCharacters(in: .whitespaces)

        return ROSSession(
            time_range: timeStr,
            session_title: cleanTitle(title),
            format: inferFormat(title)
        )
    }

    // MARK: - Pattern 5: Title with duration hint

    private static func parseDurationHint(_ line: String) -> ROSSession? {
        // Matches: "Session Title (45 min)" or "Session Title [30m]" or "Session Title - 1h30m"
        let pattern = #"^(.+?)\s*[\(\[]\s*(\d+)\s*(?:min(?:utes?)?|m)\s*[\)\]]"#
        let parts = extractRangeParts(line, pattern: pattern)
        guard parts.count == 2 else { return nil }

        let title = parts[0].trimmingCharacters(in: .whitespaces)
        guard let mins = Int(parts[1]) else { return nil }

        return ROSSession(
            session_title: cleanTitle(title),
            format: inferFormat(title),
            duration_minutes: mins
        )
    }

    // MARK: - Helpers

    private static func extractRangeParts(_ line: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsLine = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else { return [] }

        var parts: [String] = []
        for i in 1..<match.numberOfRanges {
            let range = match.range(at: i)
            if range.location != NSNotFound {
                parts.append(nsLine.substring(with: range))
            }
        }
        return parts
    }

    private static func normalizeTime(_ str: String) -> String {
        // Normalize "9:00am" → "9:00 AM"
        let cleaned = str.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(\d{1,2}:\d{2})\s*([AaPp][Mm])$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cleaned, range: NSRange(location: 0, length: (cleaned as NSString).length)),
              match.numberOfRanges == 3 else { return cleaned }
        let time = (cleaned as NSString).substring(with: match.range(at: 1))
        let ampm = (cleaned as NSString).substring(with: match.range(at: 2)).uppercased()
        return "\(time) \(ampm)"
    }

    private static func durationFromRange(start: String, end: String) -> Int? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["h:mm a", "HH:mm", "h:mma", "H:mm"] {
            formatter.dateFormat = fmt
            if let s = formatter.date(from: normalizeTime(start)),
               let e = formatter.date(from: normalizeTime(end)) {
                let interval = e.timeIntervalSince(s)
                if interval > 0 { return Int(interval) }
            }
        }
        return nil
    }

    /// Infer CueFormat string from title keywords (mirrors ROSImporter.resolveFormat)
    private static func inferFormat(_ title: String) -> String? {
        let lower = title.lowercased()
        // Q&A before "remarks": "Closing & Q&A" is a Q&A.
        if lower.contains("q&a") || lower.contains("q & a") || lower.contains("q and a") || lower.contains("questions") { return "qa" }
        if lower.contains("workshop") { return "workshop" }
        if lower.range(of: #"\blab\b"#, options: .regularExpression) != nil { return "lab" }
        if lower.contains("exercise") || lower.contains("activity") { return "exercise" }
        if lower.contains("keynote") { return "keynote" }
        if lower.contains("fireside") { return "fireside" }
        if lower.contains("panel") { return "panel" }
        if lower.contains("lightning") { return "lightning" }
        if lower.contains("remarks") || lower.contains("welcome") || lower.contains("opening") || lower.contains("closing") {
            return "remarks"
        }
        if lower.contains("break") || lower.contains("coffee") || lower.contains("lunch") || lower.contains("refreshment") {
            return "break"
        }
        if lower.contains("networking") || lower.contains("reception") || lower.contains("social") || lower.contains("happy hour") {
            return "social"
        }
        if lower.contains("transition") || lower.contains("setup") || lower.contains("changeover") {
            return "transition"
        }
        if lower.contains("green room") || lower.contains("greenroom") {
            return "greenRoom"
        }
        return nil
    }

    /// Strip leading numbering, bullets, and trailing whitespace from title
    private static func cleanTitle(_ title: String) -> String {
        var cleaned = title
        // Strip leading "1.", "1)", "a.", etc.
        if let range = cleaned.range(of: #"^\d+[\.\)]\s*"#, options: .regularExpression) {
            cleaned = String(cleaned[range.upperBound...])
        }
        // Strip leading bullet chars
        if let range = cleaned.range(of: #"^[*\-•]\s*"#, options: .regularExpression) {
            cleaned = String(cleaned[range.upperBound...])
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
