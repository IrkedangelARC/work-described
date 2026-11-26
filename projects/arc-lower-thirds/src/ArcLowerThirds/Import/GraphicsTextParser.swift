//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Parses tab-separated, CSV, or line-by-line text into graphic entries.
enum GraphicsTextParser {

    struct ParsedGraphic {
        let line1: String
        let line2: String?
        let line3: String?
    }

    /// Parse text input into an array of graphic entries.
    /// Supports:
    /// - Tab-separated: "Name\tTitle\tOrganization"
    /// - Comma-separated (CSV): "Name, Title, Organization"
    /// - One per line (line1 only): "Name"
    static func parse(_ text: String) -> [ParsedGraphic] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return lines.compactMap { line in
            // Try tab-separated first
            let tabParts = line.components(separatedBy: "\t")
            if tabParts.count >= 2 {
                return ParsedGraphic(
                    line1: tabParts[0].trimmingCharacters(in: .whitespaces),
                    line2: tabParts.count > 1 ? nonEmpty(tabParts[1]) : nil,
                    line3: tabParts.count > 2 ? nonEmpty(tabParts[2]) : nil
                )
            }

            // Try comma-separated with quote awareness ("Smith, Jr.", Title, Org)
            let csvParts = splitCSV(line)
            if csvParts.count >= 2 {
                return ParsedGraphic(
                    line1: csvParts[0].trimmingCharacters(in: .whitespaces),
                    line2: csvParts.count > 1 ? nonEmpty(csvParts[1]) : nil,
                    line3: csvParts.count > 2 ? nonEmpty(csvParts[2]) : nil
                )
            }

            // Single line — line1 only
            return ParsedGraphic(line1: line, line2: nil, line3: nil)
        }
    }

    /// Quote-aware CSV split: "Smith, Jr.", Title → ["Smith, Jr.", "Title"]
    private static func splitCSV(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields
    }

    private static func nonEmpty(_ str: String) -> String? {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
