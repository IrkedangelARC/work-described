//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Network
import SwiftUI

/// Lightweight HTTP server using Network.framework for remote control
/// via StreamDeck / Bitfocus Companion. All routes are GET for simplicity.
@Observable
final class HTTPRemoteServer {

    // MARK: - Published State

    private(set) var isRunning = false
    private(set) var port: UInt16 = 8080

    // MARK: - Engine Reference (set by app on appear)

    weak var engine: GraphicsEngine?

    // MARK: - Private

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.example.arc.lt-httpserver", qos: .userInitiated)

    // MARK: - Lifecycle

    func start(port: UInt16 = 8080) {
        guard !isRunning else { return }
        self.port = port
        do {
            let params = NWParameters.tcp
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            listener = try NWListener(using: params, on: nwPort)
            listener?.service = NWListener.Service(name: "ARC Lower Thirds", type: "_arclowerthirds._tcp")

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

    // MARK: - Connection Handling

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
            let pairs = components[1].split(separator: "&")
            for pair in pairs {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let key = String(kv[0])
                    let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                    query[key] = value
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
        case "/api/status":
            return statusJSON()

        case "/api/fire":
            if let layerStr = query["layer"], let layer = GraphicLayer(rawValue: layerStr),
               let indexStr = query["index"], let index = Int(indexStr) {
                // Fire a specific graphic on a specific layer
                guard index >= 0, index < engine.graphicCount else {
                    return ["error": "invalid index", "ok": false]
                }
                engine.fire(layer: layer, graphic: engine.graphics[index])
            } else if let indexStr = query["index"], let index = Int(indexStr) {
                engine.fire(at: index)
            } else {
                engine.fire()
            }
            return statusJSON()

        case "/api/clear":
            if let layerStr = query["layer"], let layer = GraphicLayer(rawValue: layerStr) {
                engine.clear(layer: layer)
            } else {
                engine.clear()
            }
            return statusJSON()

        case "/api/clear-all":
            engine.cutAllToBlack()
            return statusJSON()

        case "/api/layers":
            return layersJSON()

        case "/api/next":
            engine.next()
            return statusJSON()

        case "/api/previous":
            engine.previous()
            return statusJSON()

        case "/api/goto":
            let index = Int(query["graphic"] ?? "0") ?? 0
            engine.goToGraphic(at: index)
            return statusJSON()

        case "/api/show":
            return showJSON()

        case "/api/cut":
            engine.cutToBlack()
            return statusJSON()

        case "/api/fire-next":
            // Fire current selection, then advance to next graphic
            engine.fire()
            if engine.hasNext { engine.next() }
            return statusJSON()

        case "/api/select":
            // Select without firing (for preview)
            let index = Int(query["graphic"] ?? "0") ?? 0
            engine.goToGraphic(at: index)
            return statusJSON()

        default:
            return ["error": "unknown route", "path": path, "ok": false]
        }
    }

    // MARK: - Status

    private func statusJSON() -> [String: Any] {
        guard let engine else { return ["ok": false] }
        let graphic = engine.liveGraphic ?? engine.selectedGraphic
        var json: [String: Any] = [
            "ok": true,
            "state": engine.state.rawValue,
            "graphicIndex": engine.selectedIndex,
            "line1": graphic?.line1 ?? "",
            "line2": graphic?.line2 ?? "",
            "line3": graphic?.line3 ?? "",
            "graphicCount": engine.graphicCount,
            "isOnAir": engine.isOnAir,
            "anyLayerOnAir": engine.anyLayerOnAir,
            "hasNext": engine.hasNext,
            "hasPrevious": engine.hasPrevious
        ]
        if let g = graphic {
            json["animation"] = g.animationPreset.rawValue
            json["accentColor"] = g.accentColor
            json["graphicType"] = g.graphicType.rawValue
        }
        // Active layers summary
        var activeLayers: [String: String] = [:]
        for layer in GraphicLayer.allCases {
            if engine.isLayerOnAir(layer), let g = engine.graphic(on: layer) {
                activeLayers[layer.rawValue] = g.line1
            }
        }
        json["activeLayers"] = activeLayers
        return json
    }

    private func showJSON() -> [String: Any] {
        guard let engine else { return ["ok": false] }
        let graphics = engine.graphics.enumerated().map { (index, g) -> [String: Any] in
            [
                "index": index,
                "line1": g.line1,
                "line2": g.line2 ?? "",
                "line3": g.line3 ?? "",
                "animation": g.animationPreset.rawValue,
                "accentColor": g.accentColor,
                "graphicType": g.graphicType.rawValue,
                "layer": g.effectiveLayer.rawValue
            ]
        }
        return [
            "ok": true,
            "showName": engine.show?.name ?? "",
            "graphicCount": engine.graphicCount,
            "graphics": graphics
        ]
    }

    private func layersJSON() -> [String: Any] {
        guard let engine else { return ["ok": false] }
        var layers: [[String: Any]] = []
        for layer in GraphicLayer.allCases.sorted() {
            var entry: [String: Any] = [
                "layer": layer.rawValue,
                "zIndex": layer.zIndex,
                "isOnAir": engine.isLayerOnAir(layer)
            ]
            if let g = engine.graphic(on: layer) {
                entry["line1"] = g.line1
                entry["graphicType"] = g.graphicType.rawValue
            }
            layers.append(entry)
        }
        return [
            "ok": true,
            "anyLayerOnAir": engine.anyLayerOnAir,
            "layers": layers
        ]
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
}
