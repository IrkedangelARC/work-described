//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import CoreVideo
import Accelerate
import ZoomSDK

/// One participant's live video: a `ZoomSDKRenderer` subscribed to their user id, whose I420 frames are
/// converted to BGRA and handed on as an IOSurface-backed `CVPixelBuffer` the output windows can show
/// with no copy.
///
/// THE RENDERER MUST COME FROM THE SDK. `ZoomSDKRenderer()` allocates a perfectly valid Objective-C
/// object that the SDK core has never heard of: `subscribe` stores the id in its ivars, answers
/// Success, and no frame ever arrives, which cost most of 2026-09-20. The factory is
/// `ZoomSDKRawDataController.createRender(&renderer)`, paired with `destroyRender` (Zoom's own answer
/// on devforum thread 91827; header ZoomSDKRawDataController.h).
///
/// TWO THINGS LEARNED THE HARD WAY, both already paid for elsewhere in this project:
///   - **Rotate the buffers.** Handing a CALayer the same IOSurface again is not a change as far as
///     CoreAnimation is concerned, so the layer never goes dirty, the window server never recomposites,
///     and anything capturing that window sees nothing (2026-09-20, `FakeZoomEngine.pools`). A ring of
///     three, exactly as the fake does.
///   - **The frame arrives on the SDK's thread**, not the main actor. Convert there, hand over on main.
final class VideoSubscription: NSObject {
    /// A user id for video, a SHARE SOURCE id for a share (ZoomSDKRenderer.h: "If subscribe the sharing,
    /// the subscribeID is share source ID").
    let userID: UInt32
    let rawDataType: ZoomSDKRawDataType
    private var renderer: ZoomSDKRenderer?
    private let onFrame: @Sendable (UInt32, CVPixelBuffer) -> Void

    private let lock = NSLock()
    private var pool: [CVPixelBuffer] = []
    private var next = 0
    private var size = CGSize.zero
    private static let poolDepth = 3

    private(set) var isReceiving = false
    private(set) var frameCount = 0
    /// The user's main video source has delivered: from then on, other sources on this subscription are dropped.
    private var mainSourceSeen = false
    private var foreignSourceLogged = false

    init(userID: UInt32, rawDataType: ZoomSDKRawDataType = ZoomSDKRawDataType_Video, onFrame: @escaping @Sendable (UInt32, CVPixelBuffer) -> Void) {
        self.userID = userID
        self.rawDataType = rawDataType
        self.onFrame = onFrame
        super.init()
    }

    /// The resolution asked of the SDK. 720p for the ONE participant on program; 360p for everyone
    /// else, because the SDK allows one HD subscription at a time (or two 720p) and a gallery tile
    /// never needs more. The default, if nothing is asked, is 90p.
    private(set) var resolution = ZoomSDKResolution_360P

    func setResolution(_ r: ZoomSDKResolution) {
        guard r != resolution else { return }
        resolution = r
        if let renderer { _ = renderer.setResolution(r) }
    }

    /// Ask the SDK for this user's video. `ZoomSDKRawDataType_Video` is the participant's camera.
    @discardableResult
    func start() -> Bool {
        guard let controller = ZoomSDK.shared().getRawDataController() else {
            ShowLog.error("video: the SDK has no raw data controller")
            return false
        }
        var made: ZoomSDKRenderer?
        let make = controller.createRender(&made)
        guard make == ZoomSDKError_Success, let r = made else {
            ShowLog.error("video: the SDK would not create a renderer for \(userID) (\(SDKZoomEngine.name(for: make)), renderer \(made == nil ? "nil" : "present"))")
            return false
        }
        renderer = r
        r.delegate = self
        let res = r.setResolution(resolution)
        if res != ZoomSDKError_Success {
            ShowLog.log("video: resolution request refused (\(SDKZoomEngine.name(for: res))); the SDK default applies")
        }
        let err = r.subscribe(userID, rawDataType: rawDataType)
        if err != ZoomSDKError_Success {
            ShowLog.error("video: could not subscribe to \(userID) (\(SDKZoomEngine.name(for: err)))")
            r.delegate = nil
            controller.destroyRender(r)
            renderer = nil
            return false
        }
        ShowLog.log("\(rawDataType == ZoomSDKRawDataType_Share ? "share" : "video"): subscribed to \(userID) through the SDK's renderer, resolution \(resolution.rawValue)")
        return true
    }

    func stop() {
        if let r = renderer {
            r.unSubscribe()
            r.delegate = nil
            ZoomSDK.shared().getRawDataController()?.destroyRender(r)
            renderer = nil
        }
        lock.lock(); pool = []; lock.unlock()
        ShowLog.log("video: unsubscribed from \(userID)")
    }

    // MARK: - I420 to BGRA

    /// The SDK hands planar I420: a full-size luma plane and two half-size chroma planes. vImage does
    /// the conversion; the result goes straight into an IOSurface-backed buffer so the layer takes it
    /// without a copy.
    private func convert(_ data: ZoomSDKYUVRawDataI420) -> CVPixelBuffer? {
        let w = Int(data.getStreamWidth()), h = Int(data.getStreamHeight())
        guard w > 1, h > 1,
              let y = data.getYBuffer(), let u = data.getUBuffer(), let v = data.getVBuffer() else { return nil }

        lock.lock()
        if size != CGSize(width: w, height: h) || pool.count < Self.poolDepth {
            pool = (0..<Self.poolDepth).compactMap { _ in PixelBufferFactory.make(width: w, height: h) }
            size = CGSize(width: w, height: h)
            next = 0
        }
        guard !pool.isEmpty else { lock.unlock(); return nil }
        let buffer = pool[next % pool.count]
        next = (next + 1) % pool.count
        lock.unlock()

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let dest = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        var yPlane = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: y), height: vImagePixelCount(h),
                                   width: vImagePixelCount(w), rowBytes: w)
        var uPlane = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: u), height: vImagePixelCount(h / 2),
                                   width: vImagePixelCount(w / 2), rowBytes: w / 2)
        var vPlane = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: v), height: vImagePixelCount(h / 2),
                                   width: vImagePixelCount(w / 2), rowBytes: w / 2)
        var out = vImage_Buffer(data: dest, height: vImagePixelCount(h), width: vImagePixelCount(w),
                                rowBytes: CVPixelBufferGetBytesPerRow(buffer))

        guard let info = Self.conversionInfo else { return nil }
        let err = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&yPlane, &uPlane, &vPlane, &out, &info.pointee,
                                                         [3, 2, 1, 0],   // ARGB source order -> BGRA
                                                         255, vImage_Flags(kvImageDoNotTile))
        return err == kvImageNoError ? buffer : nil
    }

    /// Set up once: video-range BT.709, which is what a Zoom stream is.
    private static let conversionInfo: UnsafeMutablePointer<vImage_YpCbCrToARGB>? = {
        let info = UnsafeMutablePointer<vImage_YpCbCrToARGB>.allocate(capacity: 1)
        var pixelRange = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235,
                                                 CbCrRangeMax: 240, YpMax: 235, YpMin: 16,
                                                 CbCrMax: 240, CbCrMin: 16)
        let err = vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &pixelRange, info,
            kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { info.deallocate(); return nil }
        return info
    }()
}

extension VideoSubscription: ZoomSDKRendererDelegate {
    func onSubscribedUserDataOn() {
        isReceiving = true
        ShowLog.log("video: \(userID) is sending")
    }

    func onSubscribedUserDataOff() {
        isReceiving = false
        ShowLog.log("video: \(userID) stopped sending")
    }

    /// Deprecated by Zoom and never called, but the protocol has no @optional so it must exist.
    func onSubscribedUserLeft() {}

    func onRendererBeDestroyed() {
        isReceiving = false
        ShowLog.log("video: renderer for \(userID) destroyed")
    }

    /// On the SDK's thread. Convert here; the callback hops to the main actor itself.
    /// Only the participant's OWN camera. While ARC Zoom shares a second camera, the video subscription on its
    /// own user also delivers that share's frames (another source ID, e.g. 16778243 beside 16778240), and the
    /// self view flipped between the two cameras frame by frame (live 2026-09-24; the iPad was right).
    /// A frame whose source is not the user's main video source is dropped, once that source has been seen.
    func onRawDataReceived(_ data: ZoomSDKYUVRawDataI420?) {
        guard let data else { return }
        let source = data.getSourceID()
        if source != 0, source != userID {
            if mainSourceSeen {
                if !foreignSourceLogged { foreignSourceLogged = true; ShowLog.log("video: \(userID) also delivers source \(source) (a camera share): dropped from this tile") }
                return
            }
        } else if source == userID { mainSourceSeen = true }
        guard let buffer = convert(data) else { return }
        frameCount &+= 1
        onFrame(userID, buffer)
    }
}
