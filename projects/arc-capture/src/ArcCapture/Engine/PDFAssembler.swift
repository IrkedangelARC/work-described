//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// Assembles an array of NSImages into a single PDF document.
enum PDFAssembler {

    /// JPEG quality for slide images embedded in the PDF (0.0-1.0).
    /// 0.85 gives excellent visual quality at ~10-20x smaller than uncompressed.
    static let jpegQuality: CGFloat = 0.85

    /// Create a PDF from captured slide images and write to the specified URL.
    /// Images are JPEG-compressed and scaled to 1x to keep file size reasonable.
    /// Returns the URL of the written PDF.
    @discardableResult
    static func assemble(images: [NSImage], to outputURL: URL) throws -> URL {
        let document = PDFDocument()

        for (index, image) in images.enumerated() {
            guard let compressed = compressImage(image) else {
                NSLog("[PDFAssembler] Warning: Could not compress image at index %d", index)
                continue
            }
            guard let page = PDFPage(image: compressed) else {
                NSLog("[PDFAssembler] Warning: Could not create PDF page from image at index %d", index)
                continue
            }
            document.insert(page, at: index)
        }

        guard document.pageCount > 0 else {
            throw AssemblyError.noPages
        }

        ARCCredit.stamp(document)
        guard document.write(to: outputURL) else {
            throw AssemblyError.writeFailed(outputURL.path)
        }

        NSLog("[PDFAssembler] Wrote %d pages to %@", document.pageCount, outputURL.path)
        return outputURL
    }

    /// The page JPEG for one slide: scaled from the 2x capture to 1x and
    /// compressed, the same picture `assemble(images:)` embeds. The checkpoint
    /// writes this per slide so the bitmap can be let go (V3, plan 1.1).
    static func pageJPEG(from image: NSImage) -> Data? {
        autoreleasepool { compressedData(image) }
    }

    /// A small copy for the filmstrip, made from the page JPEG without
    /// decoding it at full size.
    static func thumbnail(fromJPEG data: Data, maxPixel: Int = 320) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Assemble a PDF from JPEG files, one page at a time. Nothing but the
    /// page being written is resident, so a 100-slide deck costs the same as
    /// a 10-slide one; `assemble(images:)` needed every bitmap at once, which
    /// is half of what a long run used to hold (V3, plan 1.1).
    ///
    /// Each page is drawn from a CGImage backed by the JPEG file itself, so
    /// Quartz embeds the existing JPEG stream rather than re-encoding it: the
    /// pages are byte-for-byte the ones the checkpoint wrote.
    @discardableResult
    static func assemble(jpegFiles: [URL], to outputURL: URL) throws -> URL {
        guard !jpegFiles.isEmpty else { throw AssemblyError.noPages }
        try? FileManager.default.removeItem(at: outputURL)
        guard let consumer = CGDataConsumer(url: outputURL as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, ARCCredit.quartzInfo) else {
            throw AssemblyError.writeFailed(outputURL.path)
        }
        var written = 0
        for (index, file) in jpegFiles.enumerated() {
            autoreleasepool {
                guard let provider = CGDataProvider(url: file as CFURL),
                      let cg = CGImage(jpegDataProviderSource: provider, decode: nil,
                                       shouldInterpolate: true, intent: .defaultIntent) else {
                    DebugLog.log("PDF", "page \(index + 1): \(file.lastPathComponent) could not be read")
                    return
                }
                var box = CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))
                ctx.beginPage(mediaBox: &box)
                ctx.draw(cg, in: box)
                ctx.endPage()
                written += 1
            }
        }
        ctx.closePDF()
        guard written > 0 else { throw AssemblyError.noPages }
        DebugLog.log("PDF", "wrote \(written) page(s) to \(outputURL.lastPathComponent)")
        return outputURL
    }

    /// Compress an NSImage to JPEG and scale from Retina 2x to 1x.
    private static func compressImage(_ image: NSImage) -> NSImage? {
        compressedData(image).flatMap { NSImage(data: $0) }
    }

    /// Scale a captured frame from Retina 2x to 1x and JPEG-compress it.
    /// The single place the page picture is made: the checkpoint writes these
    /// bytes to disk and the PDF embeds the same bytes again (V3, plan 1.1).
    private static func compressedData(_ image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }

        // Scale to 1x: use the pixel dimensions divided by the backing scale
        let pixelWidth = bitmap.pixelsWide
        let pixelHeight = bitmap.pixelsHigh
        let pointWidth = Int(image.size.width)
        let pointHeight = Int(image.size.height)

        // If pixel dimensions are larger than point dimensions, we have a Retina capture
        let targetWidth = pixelWidth > pointWidth ? pointWidth : pixelWidth
        let targetHeight = pixelHeight > pointHeight ? pointHeight : pixelHeight

        guard targetWidth > 0, targetHeight > 0, let resized = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
        NSGraphicsContext.current?.imageInterpolation = .high
        bitmap.draw(in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        NSGraphicsContext.restoreGraphicsState()

        return resized.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }

    enum AssemblyError: LocalizedError {
        case noPages
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noPages: "No pages to assemble into PDF."
            case .writeFailed(let path): "Failed to write PDF to \(path)"
            }
        }
    }
}
