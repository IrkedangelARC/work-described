//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Network

/// Manages persistent SSE (Server-Sent Events) connections from iPad clients.
/// Receives state snapshots from the HTTP server and pushes them to all connected clients.
final class SSEBroadcaster: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.example.arc.sse", qos: .userInitiated)
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()

    /// Number of connected SSE clients
    var clientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.count
    }

    // MARK: - Client Management

    /// Accept a new SSE client connection. Sends HTTP headers and keeps connection alive.
    func addClient(_ connection: NWConnection) {
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "Connection: keep-alive",
            "Access-Control-Allow-Origin: *",
            "",
            ""
        ].joined(separator: "\r\n")

        connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] error in
            if let error {
                // Client disconnected or header send failed
                connection.cancel()
                return
            }
            self?.registerClient(connection)
        })
    }

    /// Remove a client connection
    func removeClient(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.lock()
        clients.removeValue(forKey: id)
        lock.unlock()
    }

    /// Remove all clients (called on server stop)
    func removeAll() {
        lock.lock()
        let all = clients.values
        clients.removeAll()
        lock.unlock()
        for client in all {
            client.cancel()
        }
    }

    // MARK: - Broadcasting

    /// Broadcast a state event to all connected clients
    func broadcast(event: String, json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return }
        guard let jsonString = String(data: data, encoding: .utf8) else { return }

        let ssePayload = "event: \(event)\ndata: \(jsonString)\n\n"
        let sseData = Data(ssePayload.utf8)

        lock.lock()
        let snapshot = Array(clients.values)
        lock.unlock()

        for client in snapshot {
            client.send(content: sseData, completion: .contentProcessed { [weak self] error in
                if error != nil {
                    self?.removeClient(client)
                    client.cancel()
                }
            })
        }
    }

    /// Send a ping keep-alive to all clients
    func broadcastPing() {
        let pingData = Data("event: ping\ndata: {}\n\n".utf8)

        lock.lock()
        let snapshot = Array(clients.values)
        lock.unlock()

        for client in snapshot {
            client.send(content: pingData, completion: .contentProcessed { [weak self] error in
                if error != nil {
                    self?.removeClient(client)
                    client.cancel()
                }
            })
        }
    }

    // MARK: - Private

    private func registerClient(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.lock()
        clients[id] = connection
        lock.unlock()

        // Monitor for client disconnect
        monitorConnection(connection)
    }

    private func monitorConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                self?.removeClient(connection)
                connection.cancel()
            } else {
                // Keep monitoring — client may send data we ignore
                self?.monitorConnection(connection)
            }
        }
    }
}
