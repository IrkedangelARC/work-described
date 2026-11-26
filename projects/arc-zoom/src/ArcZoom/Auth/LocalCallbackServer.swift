//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Network

/// Catches the OAuth redirect on localhost. Browsers open speculative connections and fetch
/// /favicon.ico before and after the real redirect, so the server keeps accepting until a request with
/// the code arrives (the first build finished on the first connection and lost the code to a preconnect,
/// audit P1). `state` must match the one sent, or the callback is refused.
actor LocalCallbackServer {
    enum CallbackError: Error, CustomStringConvertible {
        case missingCode(String)
        case badState
        case timeout
        case cancelled
        case listenerFailed(Error)
        var description: String {
            switch self {
            case .missingCode(let s): return "callback without a code: \(s)"
            case .badState: return "callback state did not match: refused"
            case .timeout: return "no callback arrived in time"
            case .cancelled: return "the operator cancelled the browser sign-in"
            case .listenerFailed(let e): return "callback listener failed: \(e)"
            }
        }
    }

    private let port: NWEndpoint.Port
    private let path: String
    private let expectedState: String?
    private var listener: NWListener?

    /// Ends the wait in progress (the operator's CANCEL): the app stays usable while a browser tab is
    /// left open on the wrong account (2026-09-24: "now the app is stuck").
    nonisolated(unsafe) private static var cancelPendingHook: (() -> Void)?
    static func cancelPending() { cancelPendingHook?() }

    init(port: UInt16 = 8767, path: String = "/oauth/callback", expectedState: String? = nil) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.path = path
        self.expectedState = expectedState
    }

    func waitForCode(timeout: TimeInterval = 300) async throws -> String {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)
        self.listener = listener
        let path = self.path, expectedState = self.expectedState

        let codeStream = AsyncThrowingStream<String, Error> { continuation in
            listener.newConnectionHandler = { conn in
                conn.start(queue: .global())
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, error in
                    guard error == nil, let data, let request = String(data: data, encoding: .utf8) else { conn.cancel(); return }
                    switch Self.parseCallback(request: request, expectedPath: path, expectedState: expectedState) {
                    case .success(let code):
                        Self.respond(on: conn, status: "200 OK", body: "<html><body style=\"font-family:-apple-system;background:#111;color:#eee\"><h2>ARC Zoom: signed in</h2><p>You can close this window.</p></body></html>")
                        continuation.yield(code); continuation.finish()
                    case .failure(let err as CallbackError):
                        switch err {
                        case .badState, .missingCode where request.contains("error="):
                            Self.respond(on: conn, status: "400 Bad Request", body: "<html><body><h2>Authorization failed</h2><pre>\(err)</pre></body></html>")
                            continuation.finish(throwing: err)
                        default:
                            Self.respond(on: conn, status: "404 Not Found", body: "")   // favicon, preconnect: keep listening
                        }
                    case .failure(let err):
                        Self.respond(on: conn, status: "404 Not Found", body: "")
                        _ = err
                    }
                }
            }
            Self.cancelPendingHook = { continuation.finish(throwing: CallbackError.cancelled) }
            listener.stateUpdateHandler = { state in
                if case .failed(let err) = state { continuation.finish(throwing: CallbackError.listenerFailed(err)) }
            }
            listener.start(queue: .global())
        }
        defer { listener.cancel(); Self.cancelPendingHook = nil }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for try await code in codeStream { return code }
                throw CallbackError.missingCode("stream ended without a code")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CallbackError.timeout
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private static func parseCallback(request: String, expectedPath: String, expectedState: String?) -> Result<String, Error> {
        let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            return .failure(CallbackError.missingCode("unexpected request: \(firstLine)"))
        }
        let target = String(parts[1])
        guard let questionMark = target.firstIndex(of: "?") else {
            return .failure(CallbackError.missingCode("no query string"))
        }
        let pathOnly = String(target[..<questionMark])
        guard pathOnly == expectedPath else {
            return .failure(CallbackError.missingCode("wrong path: \(pathOnly)"))
        }
        let query = String(target[target.index(after: questionMark)...])
        var fields: [String: String] = [:]
        for param in query.split(separator: "&") {
            let kv = param.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1]) }
        }
        if let expectedState, fields["state"] != expectedState { return .failure(CallbackError.badState) }
        if let code = fields["code"] { return .success(code) }
        return .failure(CallbackError.missingCode(fields["error"].map { "zoom said \($0)" } ?? "no code param"))
    }

    private static func respond(on conn: NWConnection, status: String, body: String) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
