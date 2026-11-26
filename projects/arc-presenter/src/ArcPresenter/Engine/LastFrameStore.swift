//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import Foundation

/// The last program picture, kept on disk for the Guard. When Presenter dies
/// the Guard cannot ask it for anything, so every live slide change writes
/// the page image (at the program display's pixel size) to
/// `last-frame.bgra`: a 16-byte header, then BGRA rows. 2026-09-18:
/// on a crash the room holds the last frame with a red border that says it
/// is frozen, on the display and over SDI, instead of going black.
enum LastFrameStore {
    static let magic: UInt32 = 0x4152_4346   // "ARCF"
    static let url: URL = RunMarker.url.deletingLastPathComponent().appendingPathComponent("last-frame.bgra")
    private static let queue = DispatchQueue(label: "arc.presenter.lastframe", qos: .utility)
    nonisolated(unsafe) private static var lastWritten: ObjectIdentifier?

    /// Off the main thread; a repeat of the same image is skipped.
    static func write(_ image: CGImage) {
        let id = ObjectIdentifier(image)
        if lastWritten == id { return }
        lastWritten = id
        queue.async { writeNow(image) }
    }

    static func writeNow(_ image: CGImage) {
        let w = image.width, h = image.height, row = w * 4
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: row,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let base = ctx.data else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var data = Data(capacity: 16 + row * h)
        for v in [magic, UInt32(w), UInt32(h), UInt32(row)] { var le = v.littleEndian; data.append(Data(bytes: &le, count: 4)) }
        data.append(Data(bytes: base, count: row * h))
        try? data.write(to: url, options: .atomic)
    }

    /// The header and pixels back, or nil when there is no usable file.
    static func read(from url: URL = url) -> (width: Int, height: Int, bytesPerRow: Int, pixels: Data)? {
        guard let data = try? Data(contentsOf: url), data.count > 16 else { return nil }
        func u32(_ i: Int) -> UInt32 { data.subdata(in: i..<i+4).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian }
        guard u32(0) == magic else { return nil }
        let w = Int(u32(4)), h = Int(u32(8)), row = Int(u32(12))
        guard w > 0, h > 0, row >= w * 4, data.count >= 16 + row * h else { return nil }
        return (w, h, row, data.subdata(in: 16..<16 + row * h))
    }

    static func image(from url: URL = url) -> CGImage? {
        guard let f = read(from: url) else { return nil }
        guard let provider = CGDataProvider(data: f.pixels as CFData) else { return nil }
        return CGImage(width: f.width, height: f.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
