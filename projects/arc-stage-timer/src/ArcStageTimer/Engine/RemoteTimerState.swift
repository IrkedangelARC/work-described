//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Network
import SwiftUI

/// Connection state for the remote display client
enum RemoteConnectionState: Equatable {
    case disconnected
    case resolving
    case connecting
    case connected
    case reconnecting(attempt: Int)

    var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .resolving: "Resolving..."
        case .connecting: "Connecting..."
        case .connected: "Connected"
        case .reconnecting(let n): "Reconnecting (\(n))..."
        }
    }
}

/// iPad-side state manager that connects to a Mac's SSE stream
/// and populates a StageDisplayState for rendering.
@Observable
final class RemoteTimerState {

    let displayState = StageDisplayState()

    private(set) var connectionState: RemoteConnectionState = .disconnected
    private(set) var serverName: String = ""
    private(set) var serverHost: String = ""
    private(set) var serverPort: UInt16 = 8080

    private var sseTask: URLSessionDataTask?
    private var session: URLSession?
    private var sseDelegate: SSESessionDelegate?
    private var reconnectTask: Task<Void, Never>?
    private var nwConnection: NWConnection?

    // MARK: - Connect

    func connect(to server: DiscoveredServer) {
        disconnect()
        serverName = server.name
        connectionState = .resolving

        // Resolve Bonjour endpoint to IP:port via NWConnection
        let connection = NWConnection(to: server.endpoint, using: .tcp)
        nwConnection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Extract resolved host and port
                if let innerEndpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = innerEndpoint {
                    let hostStr: String
                    switch host {
                    case .ipv4(let addr):
                        hostStr = "\(addr)"
                    case .ipv6(let addr):
                        hostStr = "[\(addr)]"
                    case .name(let name, _):
                        hostStr = name
                    @unknown default:
                        hostStr = "\(host)"
                    }
                    DispatchQueue.main.async {
                        self.serverHost = hostStr
                        self.serverPort = port.rawValue
                        connection.cancel()
                        self.nwConnection = nil
                        self.openSSEStream()
                    }
                }
            case .failed, .cancelled:
                DispatchQueue.main.async {
                    self.connectionState = .disconnected
                    self.nwConnection = nil
                }
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
    }

    func connect(host: String, port: UInt16) {
        disconnect()
        serverHost = host
        serverPort = port
        serverName = host
        openSSEStream()
    }

    // MARK: - Disconnect

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        sseTask?.cancel()
        sseTask = nil
        session?.invalidateAndCancel()
        session = nil
        sseDelegate = nil
        nwConnection?.cancel()
        nwConnection = nil
        connectionState = .disconnected
    }

    // MARK: - Send Command (back to Mac)

    func sendCommand(_ path: String, query: [String: String] = [:]) {
        var urlString = "http://\(serverHost):\(serverPort)\(path)"
        if !query.isEmpty {
            let queryString = query.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            urlString += "?\(queryString)"
        }
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - SSE Stream

    private func openSSEStream() {
        connectionState = .connecting

        let baseURL = "http://\(serverHost):\(serverPort)"

        // First fetch initial state
        if let statusURL = URL(string: "\(baseURL)/api/status") {
            URLSession.shared.dataTask(with: statusURL) { [weak self] data, response, error in
                if let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    DispatchQueue.main.async {
                        self?.displayState.update(from: json)
                    }
                }
            }.resume()
        }

        // Open SSE stream
        guard let streamURL = URL(string: "\(baseURL)/api/stream") else {
            connectionState = .disconnected
            return
        }
        var request = URLRequest(url: streamURL)
        request.timeoutInterval = .infinity
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let delegate = SSESessionDelegate { [weak self] event, json in
            DispatchQueue.main.async {
                self?.handleSSEEvent(event: event, json: json)
            }
        } onDisconnect: { [weak self] in
            DispatchQueue.main.async {
                self?.handleDisconnect()
            }
        }

        sseDelegate = delegate
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        sseTask = session?.dataTask(with: request)
        sseTask?.resume()

        DispatchQueue.main.async {
            self.connectionState = .connected
        }
    }

    private func handleSSEEvent(event: String, json: [String: Any]) {
        switch event {
        case "state":
            displayState.update(from: json)
            if connectionState != .connected {
                connectionState = .connected
            }
        case "ping":
            break
        default:
            break
        }
    }

    private func handleDisconnect() {
        guard connectionState == .connected || connectionState == .connecting else { return }
        startReconnect()
    }

    // MARK: - Reconnection

    private static let maxReconnectAttempts = 10

    private func startReconnect() {
        reconnectTask?.cancel()
        var attempt = 0
        reconnectTask = Task { @MainActor in
            while !Task.isCancelled {
                attempt += 1
                if attempt > Self.maxReconnectAttempts {
                    connectionState = .disconnected
                    return
                }
                connectionState = .reconnecting(attempt: attempt)

                let delay = min(Double(attempt) * 0.5, 5.0)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }

                // Try to reconnect
                openSSEStream()

                // Wait a moment to see if it succeeds
                try? await Task.sleep(for: .seconds(2))
                if connectionState == .connected {
                    return
                }
            }
        }
    }
}

// MARK: - SSE URLSession Delegate

private final class SSESessionDelegate: NSObject, URLSessionDataDelegate {

    private let onEvent: (String, [String: Any]) -> Void
    private let onDisconnect: () -> Void
    private var buffer = ""

    init(onEvent: @escaping (String, [String: Any]) -> Void,
         onDisconnect: @escaping () -> Void) {
        self.onEvent = onEvent
        self.onDisconnect = onDisconnect
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        buffer += chunk
        processBuffer()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        onDisconnect()
    }

    private func processBuffer() {
        // SSE events are delimited by double newlines
        while let range = buffer.range(of: "\n\n") {
            let eventBlock = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])

            var eventType = "state"
            var dataLine = ""

            for line in eventBlock.components(separatedBy: "\n") {
                if line.hasPrefix("event: ") {
                    eventType = String(line.dropFirst(7))
                } else if line.hasPrefix("data: ") {
                    dataLine = String(line.dropFirst(6))
                }
            }

            guard !dataLine.isEmpty,
                  let jsonData = dataLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            onEvent(eventType, json)
        }
    }
}
