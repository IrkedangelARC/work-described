//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Network

/// Minimal localhost HTTP control server so a Claude Code session (or any
/// local tool) on this machine can drive the app with curl:
///   curl -s   localhost:PORT/state
///   curl -XPOST localhost:PORT/next
/// Binds to 127.0.0.1 only — never reachable off the machine. The handler is
/// invoked on the main actor and returns a JSON string.
///
/// Reusable across ARC apps: instantiate with a port and a command handler.
/// Port map (keep consistent across the fleet):
///   ARC Presenter        8760
///   ARC Assimilator      8761
///   ARC Stage Timer      8762
///   ARC Lower Thirds     8763
///   ARC Keyer            8764
///   ARC Switcher         8765
final class ControlServer {
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let handler: @MainActor (_ method: String, _ path: String, _ query: [String: String]) -> (Int, String)
    private let queue = DispatchQueue(label: "arc.control.server")

    init(port: UInt16,
         handler: @MainActor @escaping (_ method: String, _ path: String, _ query: [String: String]) -> (Int, String)) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.handler = handler
    }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    NSLog("ARC ControlServer failed: \(err)")
                }
            }
            l.start(queue: queue)
            listener = l
            NSLog("ARC ControlServer listening on 127.0.0.1:\(port.rawValue)")
        } catch {
            NSLog("ARC ControlServer could not start: \(error)")
        }
    }

    func stop() { listener?.cancel(); listener = nil }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8),
                  let line = req.split(separator: "\r\n").first else {
                conn.cancel(); return
            }
            // "METHOD /path?query HTTP/1.1"
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { conn.cancel(); return }
            let method = String(parts[0]).uppercased()
            let target = String(parts[1])
            let (path, query) = Self.parse(target)

            Task { @MainActor in
                let (status, body) = self.handler(method, path, query)
                self.respond(conn, status: status, json: body)
            }
        }
    }

    private func respond(_ conn: NWConnection, status: Int, json: String) {
        let reason = [200: "OK", 404: "Not Found", 409: "Conflict"][status] ?? "Bad Request"
        let payload = Data(json.utf8)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n\r\n"
        var out = Data(head.utf8); out.append(payload)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func parse(_ target: String) -> (String, [String: String]) {
        guard let q = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<q])
        var query: [String: String] = [:]
        for pair in target[target.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            // Form encoding too: a "+" is a space (Python's urlencode and most
            // form posters send it), so a deck path with spaces opens either way.
            let decode: (Substring) -> String = { raw in
                let plusFixed = raw.replacingOccurrences(of: "+", with: " ")
                return plusFixed.removingPercentEncoding ?? plusFixed
            }
            let k = decode(kv[0])
            let v = kv.count > 1 ? decode(kv[1]) : ""
            query[k] = v
        }
        return (path, query)
    }
}
