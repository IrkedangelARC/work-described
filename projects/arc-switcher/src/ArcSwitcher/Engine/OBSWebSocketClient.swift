//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import CryptoKit

/// Client for OBS WebSocket v5 protocol (obs-websocket 5.x).
/// Handles connection, authentication, request/response, and event streaming.
///
/// Protocol reference: https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md
/// Default port: 4455
@Observable
final class OBSWebSocketClient: @unchecked Sendable {

    // MARK: - State

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case authenticating
        case connected
        case error(String)
    }

    private(set) var state: ConnectionState = .disconnected
    private(set) var obsVersion: String?
    private(set) var wsVersion: String?

    var isConnected: Bool { state == .connected }

    // MARK: - Configuration

    var host: String = "127.0.0.1"
    var port: UInt16 = 4455
    var password: String?

    // MARK: - Internals

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pendingRequests: [String: CheckedContinuation<OBSResponse, Error>] = [:]
    private let queue = DispatchQueue(label: "com.example.arc.obs-ws", qos: .userInitiated)

    /// Event callback — fired on main thread.
    var onEvent: ((OBSEvent) -> Void)?

    // MARK: - Connect / Disconnect

    func connect() {
        // Allow reconnect from error state
        if case .connecting = state { return }
        if case .authenticating = state { return }
        if case .connected = state { return }
        disconnect()
        state = .connecting

        let urlString = "ws://\(host):\(port)"
        guard let url = URL(string: urlString) else {
            state = .error("Invalid URL: \(urlString)")
            return
        }

        session = URLSession(configuration: .default)
        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()
        receiveLoop()
    }

    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
        state = .disconnected
        pendingRequests.removeAll()
    }

    // MARK: - Requests

    /// Send a request to OBS and await the response.
    @discardableResult
    func sendRequest(_ type: String, data: [String: Any]? = nil) async throws -> OBSResponse {
        guard isConnected else { throw OBSError.notConnected }

        let requestId = UUID().uuidString
        let message: [String: Any] = {
            let msg: [String: Any] = [
                "op": 6,
                "d": {
                    var d: [String: Any] = [
                        "requestType": type,
                        "requestId": requestId
                    ]
                    if let data { d["requestData"] = data }
                    return d
                }()
            ]
            return msg
        }()

        let jsonData = try JSONSerialization.data(withJSONObject: message)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        return try await withCheckedThrowingContinuation { continuation in
            queue.sync { _ = pendingRequests.updateValue(continuation, forKey: requestId) }
            webSocket?.send(.string(jsonString)) { [weak self] error in
                if let error {
                    self?.queue.sync { self?.pendingRequests.removeValue(forKey: requestId) }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Convenience: Scene Management

    func getSceneList() async throws -> [[String: Any]] {
        let response = try await sendRequest("GetSceneList")
        return response.responseData?["scenes"] as? [[String: Any]] ?? []
    }

    func setCurrentProgramScene(_ sceneName: String) async throws {
        try await sendRequest("SetCurrentProgramScene", data: ["sceneName": sceneName])
    }

    func createScene(_ sceneName: String) async throws {
        try await sendRequest("CreateScene", data: ["sceneName": sceneName])
    }

    func removeScene(_ sceneName: String) async throws {
        try await sendRequest("RemoveScene", data: ["sceneName": sceneName])
    }

    // MARK: - Convenience: Input (Source) Management

    /// Create a ScreenCaptureKit application capture input in a scene.
    /// Uses type=2 (application mode) — captures all windows of the app.
    /// Requires display_uuid to scope capture to a specific display.
    /// This is the most reliable capture method on macOS 12.3+.
    func createAppCapture(sceneName: String, inputName: String, bundleID: String, displayUUID: String) async throws {
        try await sendRequest("CreateInput", data: [
            "sceneName": sceneName,
            "inputName": inputName,
            "inputKind": "screen_capture",
            "inputSettings": [
                "type": 2,              // 0=display, 1=window, 2=application
                "application": bundleID,
                "display_uuid": displayUUID,
                "show_cursor": false,
                "show_hidden_windows": false,
                "show_empty_names": false
            ] as [String: Any]
        ])
    }

    /// Update settings on an existing input (overlay merge).
    func setInputSettings(_ inputName: String, settings: [String: Any]) async throws {
        try await sendRequest("SetInputSettings", data: [
            "inputName": inputName,
            "inputSettings": settings
        ])
    }

    func removeInput(_ inputName: String) async throws {
        try await sendRequest("RemoveInput", data: ["inputName": inputName])
    }

    // MARK: - Convenience: Projector

    /// Open a fullscreen projector on a monitor.
    /// monitorIndex: 0-based OBS monitor index (may differ from macOS CGDisplay order).
    func openFullscreenProjector(monitorIndex: Int) async throws {
        try await sendRequest("OpenVideoMixProjector", data: [
            "videoMixType": "OBS_WEBSOCKET_VIDEO_MIX_TYPE_PROGRAM",
            "monitorIndex": monitorIndex
        ])
    }

    /// Get the list of monitors as OBS sees them.
    /// Returns array of dicts with monitorIndex, monitorName, monitorWidth, monitorHeight, etc.
    func getMonitorList() async throws -> [[String: Any]] {
        let response = try await sendRequest("GetMonitorList")
        return response.responseData?["monitors"] as? [[String: Any]] ?? []
    }

    // MARK: - Convenience: Transitions

    func setCurrentTransition(_ name: String, duration: Int? = nil) async throws {
        try await sendRequest("SetCurrentSceneTransition", data: ["transitionName": name])
        if let duration {
            try await sendRequest("SetCurrentSceneTransitionDuration", data: ["transitionDuration": duration])
        }
    }

    func getCurrentTransition() async throws -> String {
        let response = try await sendRequest("GetCurrentSceneTransition")
        return response.responseData?["transitionName"] as? String ?? "Cut"
    }

    // MARK: - Convenience: Streaming/Recording Status

    func getStreamStatus() async throws -> [String: Any] {
        let response = try await sendRequest("GetStreamStatus")
        return response.responseData ?? [:]
    }

    // MARK: - WebSocket Receive Loop

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure(let error):
                DispatchQueue.main.async {
                    let prevState = self.state
                    switch prevState {
                    case .connected:
                        self.state = .error("Connection lost: \(error.localizedDescription)")
                    case .authenticating:
                        self.state = .error("Authentication failed — check password")
                        print("[OBS] Auth failed: \(error.localizedDescription)")
                    case .connecting:
                        self.state = .error("Failed to connect: \(error.localizedDescription)")
                    default:
                        self.state = .error(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = json["op"] as? Int,
              let d = json["d"] as? [String: Any] else { return }

        switch op {
        case 0: // Hello
            handleHello(d)
        case 2: // Identified
            handleIdentified(d)
        case 5: // Event
            handleEvent(d)
        case 7: // RequestResponse
            handleRequestResponse(d)
        default:
            print("[OBS] Unhandled opcode: \(op)")
        }
    }

    // MARK: - Protocol Handlers

    /// OpCode 0: Hello — server sends version info and optional auth challenge.
    private func handleHello(_ d: [String: Any]) {
        obsVersion = d["obsWebSocketVersion"] as? String

        DispatchQueue.main.async { self.state = .authenticating }

        // Build Identify message (OpCode 1)
        var identifyData: [String: Any] = [
            "rpcVersion": 1,
            "eventSubscriptions": 33  // General + Scenes
        ]

        // Authenticate if server requires it
        if let auth = d["authentication"] as? [String: String],
           let challenge = auth["challenge"],
           let salt = auth["salt"] {
            if let password = self.password {
                let authString = generateAuthString(password: password, salt: salt, challenge: challenge)
                identifyData["authentication"] = authString
                print("[OBS] Authenticating with password (salt=\(salt.prefix(8))..., challenge=\(challenge.prefix(8))...)")
            } else {
                print("[OBS] Server requires password but none configured")
                DispatchQueue.main.async { self.state = .error("OBS requires a password") }
                return
            }
        }

        let message: [String: Any] = ["op": 1, "d": identifyData]
        if let jsonData = try? JSONSerialization.data(withJSONObject: message),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            webSocket?.send(.string(jsonString)) { _ in }
        }
    }

    /// OpCode 2: Identified — authentication successful, connection ready.
    private func handleIdentified(_ d: [String: Any]) {
        DispatchQueue.main.async {
            self.state = .connected
            print("[OBS] Connected (obs-websocket \(self.obsVersion ?? "?"))")
        }
    }

    /// OpCode 5: Event — broadcast from OBS.
    private func handleEvent(_ d: [String: Any]) {
        guard let eventType = d["eventType"] as? String else { return }
        let eventData = d["eventData"] as? [String: Any]
        let event = OBSEvent(type: eventType, data: eventData)
        DispatchQueue.main.async {
            self.onEvent?(event)
        }
    }

    /// OpCode 7: RequestResponse — response to a pending request.
    private func handleRequestResponse(_ d: [String: Any]) {
        guard let requestId = d["requestId"] as? String else { return }
        let requestStatus = d["requestStatus"] as? [String: Any]
        let result = requestStatus?["result"] as? Bool ?? false
        let code = requestStatus?["code"] as? Int ?? 0
        let comment = requestStatus?["comment"] as? String
        let responseData = d["responseData"] as? [String: Any]

        let response = OBSResponse(
            requestId: requestId,
            success: result,
            code: code,
            comment: comment,
            responseData: responseData
        )

        queue.sync {
            if let continuation = pendingRequests.removeValue(forKey: requestId) {
                if result {
                    continuation.resume(returning: response)
                } else {
                    continuation.resume(throwing: OBSError.requestFailed(
                        code: code,
                        comment: comment ?? "Unknown error"
                    ))
                }
            }
        }
    }

    // MARK: - Auth

    /// Generate obs-websocket v5 auth string:
    /// base64(SHA256(base64(SHA256(password + salt)) + challenge))
    private func generateAuthString(password: String, salt: String, challenge: String) -> String {
        // Step 1: secret = base64(SHA256(password + salt))
        let secretHash = SHA256.hash(data: Data((password + salt).utf8))
        let secretBase64 = Data(Array(secretHash)).base64EncodedString()

        // Step 2: auth = base64(SHA256(secret + challenge))
        let authHash = SHA256.hash(data: Data((secretBase64 + challenge).utf8))
        return Data(Array(authHash)).base64EncodedString()
    }
}

// MARK: - Data Types

struct OBSResponse {
    let requestId: String
    let success: Bool
    let code: Int
    let comment: String?
    let responseData: [String: Any]?
}

struct OBSEvent {
    let type: String
    let data: [String: Any]?
}

enum OBSError: LocalizedError {
    case notConnected
    case requestFailed(code: Int, comment: String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to OBS"
        case .requestFailed(let code, let comment): "OBS error \(code): \(comment)"
        case .timeout: "Request timed out"
        }
    }
}
