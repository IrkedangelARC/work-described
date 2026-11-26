//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import CoreVideo
import ARCDeckLink

/// The held frame: Presenter's last program picture with a red border that
/// says FROZEN, for the display window and for SDI.
enum HeldFrame {
    static let borderWidth: CGFloat = 24
    static let red = CGColor(red: 0.85, green: 0.05, blue: 0.05, alpha: 1)

    /// Presenter's last-frame.bgra (same layout as LastFrameStore writes).
    static func lastImage(at url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url), data.count > 16 else { return nil }
        func u32(_ i: Int) -> UInt32 { data.subdata(in: i..<i+4).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian }
        guard u32(0) == 0x4152_4346 else { return nil }
        let w = Int(u32(4)), h = Int(u32(8)), row = Int(u32(12))
        guard w > 0, h > 0, row >= w * 4, data.count >= 16 + row * h,
              let provider = CGDataProvider(data: data.subdata(in: 16..<16 + row * h) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Draw the picture letterboxed into `size` on black with the red border.
    static func draw(_ image: CGImage?, in ctx: CGContext, size: CGSize) {
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
        if let image {
            let ar = CGFloat(image.width) / CGFloat(image.height)
            var r = CGRect(origin: .zero, size: size)
            if size.width / size.height > ar { r.size.width = (size.height * ar).rounded(); r.origin.x = ((size.width - r.width) / 2).rounded() }
            else { r.size.height = (size.width / ar).rounded(); r.origin.y = ((size.height - r.height) / 2).rounded() }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: r)
        }
        ctx.setStrokeColor(red); ctx.setLineWidth(borderWidth * 2)   // half the stroke lies outside the frame
        ctx.stroke(CGRect(origin: .zero, size: size))
    }

    /// A 1920x1080 BGRA pixel buffer for the DeckLink output.
    static func pixelBuffer(_ image: CGImage?, width: Int = 1920, height: Int = 1080) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferCGImageCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        draw(image, in: ctx, size: CGSize(width: width, height: height))
        return pb
    }

    /// The window's content: the picture with the red border.
    final class View: NSView {
        var image: CGImage?
        override var isOpaque: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            HeldFrame.draw(image, in: ctx, size: bounds.size)
        }
    }
}
