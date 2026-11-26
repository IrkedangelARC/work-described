//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Network
import ImageIO
import CoreGraphics
import os

/// Reads QUAD's `GET /program.mjpeg` and keeps the newest decoded frame.
///
/// Raw TCP (Network framework), not URLSession: URLSession splits `multipart/x-mixed-replace`
/// into one response per part and only tells you a part ended when the NEXT one starts, which
/// costs a frame of latency. The wire contract (PLAN_quad_virtual_camera.md, program_relay.py):
///
///     --arcquad\r\nContent-Type: image/jpeg\r\nContent-Length: <n>\r\n\r\n<n bytes>\r\n
///
/// Reconnects forever with backoff; `latest` goes stale on its own when frames stop, and the
/// renderer slates on staleness, so a dead QUAD shows the slate and never a frozen picture.
final class ProgramFeed {
    struct Frame { let image: CGImage; let at: DispatchTime }

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let path: String
    private let queue = DispatchQueue(label: "com.example.arc.ArcQuadCamera.feed")
    private let lock = OSAllocatedUnfairLock<Frame?>(initialState: nil)
    private var connection: NWConnection?
    private var buffer = Data()
    private var headerDone = false
    private var running = false
    private var backoff = 0.5
    private let log = Logger(subsystem: "com.example.arc.ArcQuadCamera", category: "feed")

    private(set) var framesReceived = 0
    private var partsSeen = 0, incomplete = 0, decodeFailed = 0, lastReport = DispatchTime.now()

    init(url: URL) {
        host = NWEndpoint.Host(url.host ?? "127.0.0.1")
        port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) ?? 80
        path = url.path.isEmpty ? "/" : url.path
    }

    var latest: Frame? { lock.withLock { $0 } }

    /// Called on the feed queue for every decoded frame, so the renderer can publish on
    /// ARRIVAL instead of sampling `latest` on its own clock (that sampling made repeat+skip
    /// pairs whenever an arrival landed near a tick: 21 of 300 frames, visible judder on moves).
    var onFrame: ((Frame) -> Void)?

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.connection?.cancel()
            self.connection = nil
        }
    }

    private func connect() {
        guard running else { return }
        buffer.removeAll(keepingCapacity: true)
        headerDone = false
        let c = NWConnection(host: host, port: port, using: .tcp)
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.backoff = 0.5
                let req = "GET \(self.path) HTTP/1.1\r\nHost: \(self.host)\r\nConnection: keep-alive\r\n\r\n"
                c.send(content: Data(req.utf8), completion: .contentProcessed { _ in })
                self.receive(on: c)
            case .failed(let e):
                self.log.error("program feed failed: \(e.localizedDescription, privacy: .public)")
                self.retry(c)
            case .waiting(let e):
                self.log.error("program feed waiting: \(e.localizedDescription, privacy: .public)")
                self.retry(c)
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func retry(_ c: NWConnection) {
        c.cancel()
        guard running, connection === c else { return }
        connection = nil
        let wait = backoff
        backoff = min(backoff * 2, 5)
        queue.asyncAfter(deadline: .now() + wait) { self.connect() }
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parse()
            }
            if done || error != nil { self.retry(c); return }
            self.receive(on: c)
        }
    }

    private static let crlf2 = Data("\r\n\r\n".utf8)

    private func parse() {
        if !headerDone {
            guard let end = buffer.range(of: Self.crlf2) else { return }
            let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            guard head.hasPrefix("HTTP/1.") && head.contains(" 200") else {
                log.error("program feed refused: \(head.prefix(40), privacy: .public)")
                buffer.removeAll()
                return
            }
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            headerDone = true
        }
        while true {
            guard let end = buffer.range(of: Self.crlf2) else { return }
            let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            guard let length = Self.contentLength(head) else {
                // Not a part header (stray bytes): drop through the separator and resync.
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                continue
            }
            let bodyStart = end.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return }
            let body = buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: length))
            buffer.removeSubrange(buffer.startIndex..<buffer.index(bodyStart, offsetBy: length))
            decode(body)
        }
    }

    private func report() {
        let now = DispatchTime.now()
        guard now.uptimeNanoseconds - lastReport.uptimeNanoseconds > 5_000_000_000 else { return }
        lastReport = now
        log.notice("feed: parts \(self.partsSeen) decoded \(self.framesReceived) incomplete \(self.incomplete) decodeFailed \(self.decodeFailed) buffered \(self.buffer.count)")
    }

    private static func contentLength(_ head: String) -> Int? {
        for line in head.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private func decode(_ jpeg: Data) {
        partsSeen += 1
        report()
        // A part whose bytes do not run SOI..EOI would decode with a grey tail: drop it and
        // keep showing the previous frame for one tick instead.
        guard jpeg.count > 4, jpeg[jpeg.startIndex] == 0xFF, jpeg[jpeg.startIndex + 1] == 0xD8,
              jpeg[jpeg.endIndex - 2] == 0xFF, jpeg[jpeg.endIndex - 1] == 0xD9 else {
            incomplete += 1
            return
        }
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { decodeFailed += 1; return }
        framesReceived += 1
        let frame = Frame(image: image, at: .now())
        lock.withLock { $0 = frame }
        onFrame?(frame)
    }
}
