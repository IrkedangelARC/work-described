//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// The repair pass for agenda rows the rules refused: a local model on the office workstation (its Ollama server,
/// over the LAN or the VPN), thinking OFF, JSON out, a short timeout. Never
/// a cloud model. When the workstation is out of reach the rows stay refused and land in REVIEW; the rundown is
/// written either way (2026-09-19: "if this is run on the laptops or mini … could it be sent to
/// the workstation for processing?").
enum AgendaRepair {
    static let urlKey = "agendaAssistURL", modelKey = "agendaAssistModel"
    /// Default is THIS Mac's Ollama. It was a fixed LAN address, which on anyone else's network is some
    /// other machine that would be sent agenda text (2026-11-25, public build). Another host is a setting:
    /// `defaults write com.example.arc.ArcCapture agendaAssistURL http://HOST:11434`.
    static var baseURL: String { UserDefaults.standard.string(forKey: urlKey) ?? "http://localhost:11434" }
    static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? "qwen3.6:35b" }
    static let timeout: TimeInterval = 25

    struct Fix: Decodable {
        /// The row's number in the list sent (1-based): the answers are matched by it, never by echoed text.
        var n: Int?
        var raw: String?
        var time: String?
        var title: String?
        var speakers: String?
        var kind: String?
    }
    private struct Answer: Decodable { var rows: [Fix] }

    /// The rows fixed, keyed by their raw line; nil when the workstation could not be reached or did not answer in JSON.
    static func repair(_ rows: [Agenda.Row], log: (String) -> Void) async -> [Int: Fix]? {
        guard !rows.isEmpty, let url = URL(string: baseURL + "/api/chat") else { return nil }
        let system = """
        You read rows of an event agenda that a rule-based parser could not read. Each row is one line of a \
        schedule table with cells separated by tabs, numbered. Answer ONLY JSON: {"rows":[{"n":<the row's number>, \
        "time":"<start - end with am/pm, or empty>", "title":"<session title>", "speakers":"<names, comma separated, or empty>", \
        "kind":"talk|keynote|panel|remarks|break|social"}]}. Keep every row, with its number. A title wrapped \
        across cells is one title; names wrapped across cells are one list of names. Never invent a time.
        """
        let lines = rows.enumerated().map { "\($0.offset + 1)\t\($0.element.timeRange)\t\($0.element.raw)" }.joined(separator: "\n")
        let body: [String: Any] = [
            "model": model, "stream": false, "think": false, "format": "json",
            "options": ["num_predict": 1200, "temperature": 0],
            "messages": [["role": "system", "content": system], ["role": "user", "content": lines]],
        ]
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = top["message"] as? [String: Any], let content = message["content"] as? String,
                  let answer = try? JSONDecoder().decode(Answer.self, from: Data(content.utf8)) else {
                log("agenda repair: \(model) at \(baseURL) answered, but not in the shape asked for")
                return nil
            }
            log("agenda repair: \(answer.rows.count) row(s) read by \(model) at \(baseURL)")
            return Dictionary(answer.rows.compactMap { f in f.n.map { ($0, f) } }, uniquingKeysWith: { a, _ in a })
        } catch {
            log("agenda repair: \(baseURL) not reachable (\(error.localizedDescription)); the rows stay in REVIEW")
            return nil
        }
    }

    /// The fixes applied: a row the model read loses its `refused`, and says it was read by the model.
    static func apply(_ fixes: [Int: Fix], to agenda: inout Agenda) -> Int {
        var n = 0
        var sent = 0   // the refused rows were sent in agenda order, numbered from 1
        for k in agenda.rows.indices {
            guard agenda.rows[k].refused != nil else { continue }
            sent += 1
            guard let f = fixes[sent] else { continue }
            if let t = f.title, !t.isEmpty { agenda.rows[k].title = t }
            if let s = f.speakers { agenda.rows[k].speakers = s }
            if let time = f.time, !time.isEmpty, let row = AgendaParser.timedRow(time + "\t" + (f.title ?? ""), day: agenda.rows[k].day, slide: agenda.rows[k].slide) {
                agenda.rows[k].timeRange = row.timeRange; agenda.rows[k].start = row.start; agenda.rows[k].end = row.end
            }
            if let kind = f.kind.flatMap(Agenda.Kind.init(rawValue:)) { agenda.rows[k].kind = kind }
            agenda.rows[k].refused = agenda.rows[k].minutes == nil ? "read by \(model), but still no length" : nil
            n += 1
        }
        return n
    }
}
