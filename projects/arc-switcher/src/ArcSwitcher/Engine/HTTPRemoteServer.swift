//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Network

/// HTTP server for remote control via Bitfocus Companion / StreamDeck.
/// All routes are GET with query parameters for Companion compatibility.
@Observable
final class HTTPRemoteServer {

    private(set) var isRunning = false
    private(set) var port: UInt16 = 9090

    weak var engine: SwitcherEngine?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.example.arc.arcswitcher.http", qos: .userInitiated)

    // MARK: - Lifecycle

    func start(port: UInt16 = 9090) {
        guard !isRunning else { return }
        self.port = port
        do {
            let params = NWParameters.tcp
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            listener = try NWListener(using: params, on: nwPort)
            listener?.service = NWListener.Service(name: "ARC Switcher", type: "_arcswitcher._tcp")

            listener?.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                    case .failed, .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener?.start(queue: queue)
        } catch {
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            let request = String(data: data, encoding: .utf8) ?? ""
            let (path, query) = self.parseRequest(request)

            DispatchQueue.main.async {
                let response = self.route(path: path, query: query)
                self.sendResponse(connection: connection, json: response)
            }
        }
    }

    private func parseRequest(_ raw: String) -> (path: String, query: [String: String]) {
        let firstLine = raw.components(separatedBy: "\r\n").first ?? raw
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return ("/", [:]) }

        let fullPath = String(parts[1])
        let components = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(components[0])
        var query: [String: String] = [:]
        if components.count > 1 {
            for pair in components[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        }
        return (path, query)
    }

    // MARK: - Route Dispatch

    private func route(path: String, query: [String: String]) -> [String: Any] {
        guard let engine else {
            return ["error": "engine not connected", "ok": false]
        }

        switch path {

        // Status
        case "/api/status":
            return statusJSON()

        // List running apps available for registration
        case "/api/apps":
            let apps = engine.availableApps().compactMap { app -> [String: String]? in
                guard let bundleId = app.bundleIdentifier,
                      let name = app.localizedName else { return nil }
                return ["bundleId": bundleId, "name": name, "pid": "\(app.processIdentifier)"]
            }
            return ["ok": true, "apps": apps]

        // List registered sources
        case "/api/sources":
            return statusJSON()

        // Switch by source ID or index
        case "/api/switch":
            if let sourceId = query["source"] {
                engine.switchTo(sourceId: sourceId)
            } else if let indexStr = query["index"], let index = Int(indexStr) {
                engine.switchToIndex(index)
            }
            return statusJSON()

        // Cut to black
        case "/api/black":
            engine.cutToBlack()
            return statusJSON()

        // Cut from black
        case "/api/unblack":
            engine.cutFromBlack()
            return statusJSON()

        // Send command to active source
        case "/api/command":
            if let actionStr = query["action"],
               let command = AppCommand(rawValue: actionStr) {
                let sourceId = query["source"]
                engine.sendCommand(command, toSourceId: sourceId)
            }
            return statusJSON()

        // Convenience: slide navigation
        case "/api/next":
            engine.sendCommand(.nextSlide)
            return statusJSON()

        case "/api/previous":
            engine.sendCommand(.previousSlide)
            return statusJSON()

        // Convenience: transport
        case "/api/play":
            engine.sendCommand(.play)
            return statusJSON()

        case "/api/pause":
            engine.sendCommand(.pause)
            return statusJSON()

        case "/api/stop":
            engine.sendCommand(.stop)
            return statusJSON()

        // Volume
        case "/api/volumeup":
            engine.sendCommand(.volumeUp)
            return statusJSON()

        case "/api/volumedown":
            engine.sendCommand(.volumeDown)
            return statusJSON()

        case "/api/mute":
            engine.sendCommand(.mute)
            return statusJSON()

        // Presentation mode
        case "/api/startpresentation":
            engine.sendCommand(.startPresentation)
            return statusJSON()

        case "/api/stoppresentation":
            engine.sendCommand(.stopPresentation)
            return statusJSON()

        // Show mode
        case "/api/showmode":
            if engine.isInShowMode { engine.exitShowMode() } else { engine.enterShowMode() }
            return statusJSON()

        case "/api/showmode/enter":
            engine.enterShowMode()
            return statusJSON()

        case "/api/showmode/exit":
            engine.exitShowMode()
            return statusJSON()

        // OBS connection
        case "/api/obs/status":
            return [
                "ok": true,
                "connected": engine.obs.isConnected,
                "state": "\(engine.obs.state)",
                "obsVersion": engine.obs.obsVersion ?? NSNull()
            ]

        case "/api/obs/connect":
            engine.connectOBS()
            Task {
                try? await Task.sleep(for: .seconds(1))
                await engine.initializeOBS()
            }
            return ["ok": true, "action": "connecting"]

        case "/api/obs/disconnect":
            engine.disconnectOBS()
            return ["ok": true, "action": "disconnected"]

        // Transition control
        case "/api/transition":
            if let name = query["name"] {
                let duration = query["duration"].flatMap { Int($0) }
                engine.setTransition(name, duration: duration)
            }
            return statusJSON()

        default:
            return ["error": "unknown route", "path": path, "ok": false]
        }
    }

    // MARK: - Status

    private func statusJSON() -> [String: Any] {
        guard let engine else { return ["ok": false] }
        var json = engine.statusJSON()
        json["ok"] = true
        json["serverPort"] = Int(port)
        return json
    }

    // MARK: - Response

    private func sendResponse(connection: NWConnection, json: [String: Any]) {
        let body: Data
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
            body = data
        } else {
            body = Data("{\"error\":\"serialization failed\"}".utf8)
        }

        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Access-Control-Allow-Origin: *",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var response = Data(header.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Local network IP address for display.
    static func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            guard addrFamily == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name == "en1" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let address = String(cString: hostname)
            if !address.isEmpty { return address }
        }
        return nil
    }
}
