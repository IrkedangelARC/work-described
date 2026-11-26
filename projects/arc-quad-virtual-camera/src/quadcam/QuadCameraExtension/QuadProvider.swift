//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo
import CoreGraphics
import CoreText
import os

/// Output geometry. The source is the cameras' 1280x720 MJPEG, so 720p is native.
let kWidth: Int32 = 1280
let kHeight: Int32 = 720
let kFrameRate: Int32 = 30

/// Where the program comes from. PHASE 0 (spike): fixed. The extension runs as the camera
/// assistant user in a sandbox, so it cannot read the operator's defaults; phase 2 sets this
/// from the host app through a custom device property (PLAN_quad_virtual_camera.md §5).
let kProgramURL = URL(string: "http://127.0.0.1:8779/program.mjpeg")!

/// A frame older than this is not live: slate instead of freezing.
let kStaleAfter: Double = 1.0

/// The keepalive repeats the last frame only once the source has clearly missed one
/// (1.5 frame intervals). Below that the arrival path is doing the publishing.
let kRepeatAfter: Double = 1.5 / Double(kFrameRate)

// MARK: - Provider

final class QuadProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: QuadDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = QuadDeviceSource(localizedName: "ARC QUAD")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("ARC QUAD: could not add the device: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "ARC Event Productions" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: - Device

final class QuadDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: QuadStreamSource!
    private var streamingCount = 0
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.example.arc.ArcQuadCamera.timer", qos: .userInteractive)
    private var formatDescription: CMFormatDescription!
    private var pool: CVPixelBufferPool!
    private let poolAux = [kCVPixelBufferPoolAllocationThresholdKey: 6] as NSDictionary
    private let feed = ProgramFeed(url: kProgramURL)
    private lazy var slate = Slate(width: Int(kWidth), height: Int(kHeight))
    private let log = Logger(subsystem: "com.example.arc.ArcQuadCamera", category: "device")
    private var lastSent = DispatchTime(uptimeNanoseconds: 0)
    private var sentLive = 0, sentRepeat = 0, sentSlate = 0, lastReport = DispatchTime.now()

    init(localizedName: String) {
        super.init()
        // Fixed IDs so apps remember "ARC QUAD" across restarts and reinstalls.
        let deviceID = UUID(uuidString: "A7C0DA0D-0A1C-4E57-9A2D-0000A4C0DA01")!
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: nil, source: self)

        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: kWidth, height: kHeight, extensions: nil, formatDescriptionOut: &formatDescription)
        let attrs = [
            kCVPixelBufferWidthKey: kWidth,
            kCVPixelBufferHeightKey: kHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ] as NSDictionary
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &pool)

        let frameDuration = CMTime(value: 1, timescale: kFrameRate)
        let format = CMIOExtensionStreamFormat(formatDescription: formatDescription, maxFrameDuration: frameDuration,
                                               minFrameDuration: frameDuration, validFrameDurations: nil)
        let streamID = UUID(uuidString: "A7C0DA0D-0A1C-4E57-9A2D-0000A4C0DA02")!
        streamSource = QuadStreamSource(localizedName: "ARC QUAD Program", streamID: streamID, streamFormat: format, device: device)
        do {
            try device.addStream(streamSource.stream)
        } catch {
            fatalError("ARC QUAD: could not add the stream: \(error)")
        }
        // Source-paced output: every decoded frame goes out the moment it lands.
        feed.onFrame = { [weak self] frame in
            guard let self else { return }
            self.timerQueue.async {
                guard self.timer != nil else { return }
                self.publish(frame.image, kind: .live)
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = 0x7669_7274 } // 'virt'
        if properties.contains(.deviceModel) { p.model = "ARC QUAD Program" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // Only pull from QUAD while some app is actually watching: ~26 Mbps per Mac otherwise.
    func startStreaming() {
        timerQueue.async {
            self.streamingCount += 1
            guard self.timer == nil else { return }
            self.feed.start()
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: self.timerQueue)
            t.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
            self.log.info("streaming started")
        }
    }

    func stopStreaming() {
        timerQueue.async {
            self.streamingCount = max(0, self.streamingCount - 1)
            guard self.streamingCount == 0 else { return }
            self.timer?.cancel()
            self.timer = nil
            self.feed.stop()
            self.log.info("streaming stopped")
        }
    }

    private enum Kind { case live, repeated, slate }

    /// Keepalive on OUR clock. Live frames go out on arrival (`feed.onFrame`); this only fills
    /// a gap the source left: repeat the last frame while it is fresh, else the slate. Never a
    /// frozen picture, never black.
    private func tick() {
        let now = DispatchTime.now()
        guard Double(now.uptimeNanoseconds - lastSent.uptimeNanoseconds) / 1e9 >= kRepeatAfter else { return }
        if let f = feed.latest, Double(now.uptimeNanoseconds - f.at.uptimeNanoseconds) / 1e9 < kStaleAfter {
            publish(f.image, kind: .repeated)
        } else {
            publish(slate.image, kind: .slate)
        }
    }

    /// A NEW pixel buffer with a fresh timestamp every time (the ATEM `-fps_mode passthrough`
    /// and ARC Zoom reused-buffer lessons).
    private func publish(_ image: CGImage, kind: Kind) {
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, poolAux, &pb) == kCVReturnSuccess,
              let pixelBuffer = pb else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                               width: Int(kWidth), height: Int(kHeight), bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            let bounds = CGRect(x: 0, y: 0, width: Int(kWidth), height: Int(kHeight))
            if kind == .slate {
                ctx.draw(image, in: bounds)
            } else {
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: aspectFit(CGSize(width: image.width, height: image.height), in: bounds, ctx: ctx))
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var sampleBuffer: CMSampleBuffer?
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: kFrameRate), presentationTimeStamp: now, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
                                                 makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
                                                 sampleTiming: &timing, sampleBufferOut: &sampleBuffer) == noErr,
              let sb = sampleBuffer else { return }
        streamSource.stream.send(sb, discontinuity: [], hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC)))
        lastSent = .now()
        switch kind {
        case .live: sentLive += 1
        case .repeated: sentRepeat += 1
        case .slate: sentSlate += 1
        }
        report()
    }

    private func report() {
        let now = DispatchTime.now()
        guard now.uptimeNanoseconds - lastReport.uptimeNanoseconds > 5_000_000_000 else { return }
        lastReport = now
        log.notice("out: live \(self.sentLive) repeated \(self.sentRepeat) slate \(self.sentSlate)")
    }

    /// Letterbox a non-16:9 source on black rather than stretching it.
    private func aspectFit(_ src: CGSize, in bounds: CGRect, ctx: CGContext) -> CGRect {
        let scale = min(bounds.width / src.width, bounds.height / src.height)
        let size = CGSize(width: src.width * scale, height: src.height * scale)
        if size.width < bounds.width || size.height < bounds.height {
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(bounds)
        }
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
}

// MARK: - Stream

final class QuadStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let format: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.format = streamFormat
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: kFrameRate) }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let i = streamProperties.activeFormatIndex { activeFormatIndex = i }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        (device.source as? QuadDeviceSource)?.startStreaming()
    }

    func stopStream() throws {
        (device.source as? QuadDeviceSource)?.stopStreaming()
    }
}

// MARK: - Slate

/// "ARC QUAD / NO PROGRAM" on the ARC sub-group ground: what every app sees when QUAD is not
/// serving a live program. Never black (feedback_never_a_black_page).
final class Slate {
    let image: CGImage

    init(width: Int, height: Int) {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)
        ctx.setFillColor(CGColor(red: 0x26 / 255.0, green: 0x28 / 255.0, blue: 0x2C / 255.0, alpha: 1))   // #26282C
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0xC1 / 255.0, green: 0x27 / 255.0, blue: 0x2D / 255.0, alpha: 1))   // ARC red #C1272D
        ctx.fill(CGRect(x: w * 0.1, y: h * 0.5 - 3, width: w * 0.08, height: 6))
        Self.text("ARC QUAD", size: h * 0.11, weight: "Futura-Bold", at: CGPoint(x: w * 0.1, y: h * 0.53), ctx: ctx, white: 1.0)
        Self.text("NO PROGRAM", size: h * 0.05, weight: "Futura-Medium", at: CGPoint(x: w * 0.1, y: h * 0.40), ctx: ctx, white: 0.75)
        image = ctx.makeImage()!
    }

    private static func text(_ s: String, size: CGFloat, weight: String, at p: CGPoint, ctx: CGContext, white: CGFloat) {
        let font = CTFontCreateWithName(weight as CFString, size, nil)
        let attrs = [kCTFontAttributeName: font,
                     kCTForegroundColorAttributeName: CGColor(gray: white, alpha: 1)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, s as CFString, attrs))
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }
}
