//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import CoreGraphics
import CryptoKit
import Foundation

enum FrameHasher {
    /// Hash a downsampled version of the image so tiny capture noise (cursor jitter, antialias)
    /// does not cause spurious mismatches. 64x36 is enough to detect "is this the same slide".
    static func sha256(of image: CGImage) -> String {
        guard let downsampled = downsample(image, to: CGSize(width: 64, height: 36)),
              let cfData = downsampled.dataProvider?.data else {
            return UUID().uuidString
        }
        let data = cfData as Data
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func downsample(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }
}
