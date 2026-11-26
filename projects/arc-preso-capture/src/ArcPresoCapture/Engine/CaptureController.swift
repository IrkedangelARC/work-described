//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import SwiftUI
import ScreenCaptureKit
import AppKit
import CoreGraphics
import ApplicationServices

@MainActor
final class CaptureController: ObservableObject {
    enum State: Equatable {
        case idle
        case capturing
        case finished(pdfURL: URL)
        case error(String)
    }

    @Published var state: State = .idle
    @Published var displays: [SCDisplay] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var delaySeconds: Double = 2.0
    @Published var maxSlides: Int = 250
    @Published var stableFrameThreshold: Int = 3
    @Published var leadInSeconds: Double = 3.0
    @Published var outputDirectory: URL?
    @Published var capturedCount: Int = 0
    @Published var statusMessage: String = "Ready"

    private var capturedImages: [CGImage] = []
    private var lastHashes: [String] = []
    private var captureTask: Task<Void, Never>?

    private let capturer = DisplayCapturer()
    private let keys = KeystrokeSender()

    init() {
        // Trigger Screen Recording prompt on first launch.
        _ = CGRequestScreenCaptureAccess()
        outputDirectory = defaultOutputDirectory()
        Task { await refreshDisplays() }
    }

    func refreshDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            self.displays = content.displays
            if selectedDisplayID == nil || !content.displays.contains(where: { $0.displayID == selectedDisplayID }) {
                selectedDisplayID = content.displays.first?.displayID
            }
        } catch {
            self.statusMessage = "Failed to enumerate displays: \(error.localizedDescription)"
        }
    }

    func start() {
        guard state != .capturing else { return }
        guard ensureAccessibility() else {
            state = .error("Accessibility permission required. Grant in System Settings → Privacy & Security → Accessibility, then restart.")
            return
        }
        guard let displayID = selectedDisplayID,
              let display = displays.first(where: { $0.displayID == displayID }) else {
            state = .error("No display selected")
            return
        }
        guard let outDir = outputDirectory else {
            state = .error("No output directory")
            return
        }

        capturedImages = []
        lastHashes = []
        capturedCount = 0
        statusMessage = "Lead-in \(Int(leadInSeconds))s — focus your presentation now"
        state = .capturing

        captureTask = Task { [weak self] in
            await self?.runLoop(display: display, outDir: outDir)
        }
    }

    func stop() {
        captureTask?.cancel()
        captureTask = nil
        statusMessage = "Stopped by user"
        Task { await writeOutputsIfAny() }
    }

    private func runLoop(display: SCDisplay, outDir: URL) async {
        // Lead-in pause so user can switch focus to the presentation app.
        try? await Task.sleep(nanoseconds: UInt64(leadInSeconds * 1_000_000_000))
        if Task.isCancelled { await finishCancelled(); return }

        // Capture the starting frame (no key pressed yet).
        await captureOnce(display: display)

        while !Task.isCancelled, capturedImages.count < maxSlides {
            keys.sendRightArrow()
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            if Task.isCancelled { break }

            await captureOnce(display: display)

            // Stable-frame end-of-deck detector.
            let recent = lastHashes.suffix(stableFrameThreshold)
            if recent.count == stableFrameThreshold, Set(recent).count == 1 {
                statusMessage = "End of deck detected (last \(stableFrameThreshold) frames identical)"
                // Trim trailing duplicates so the PDF doesn't end with N copies of the last slide.
                trimTrailingDuplicates()
                break
            }
        }

        if capturedImages.count >= maxSlides {
            statusMessage = "Reached max-slides safety stop (\(maxSlides))"
        }

        await writeOutputs(outDir: outDir)
    }

    private func finishCancelled() async {
        await writeOutputsIfAny()
    }

    private func captureOnce(display: SCDisplay) async {
        do {
            let img = try await capturer.capture(display: display)
            let hash = FrameHasher.sha256(of: img)
            capturedImages.append(img)
            lastHashes.append(hash)
            capturedCount = capturedImages.count
            statusMessage = "Captured frame \(capturedCount)"
        } catch {
            statusMessage = "Capture error: \(error.localizedDescription)"
        }
    }

    private func trimTrailingDuplicates() {
        guard let last = lastHashes.last else { return }
        while capturedImages.count > 1, lastHashes[lastHashes.count - 2] == last {
            capturedImages.removeLast()
            lastHashes.removeLast()
        }
        capturedCount = capturedImages.count
    }

    private func writeOutputsIfAny() async {
        guard !capturedImages.isEmpty, let outDir = outputDirectory else { return }
        await writeOutputs(outDir: outDir)
    }

    private func writeOutputs(outDir: URL) async {
        let stamp = Self.timestamp()
        let runDir = outDir.appendingPathComponent("PresoCapture-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

        let pngDir = runDir.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: pngDir, withIntermediateDirectories: true)

        for (i, img) in capturedImages.enumerated() {
            let url = pngDir.appendingPathComponent(String(format: "slide_%04d.png", i + 1))
            PDFCompiler.writePNG(img, to: url)
        }

        let pdfURL = runDir.appendingPathComponent("PresoCapture.pdf")
        do {
            try PDFCompiler.writePDF(images: capturedImages, to: pdfURL)
            state = .finished(pdfURL: pdfURL)
            statusMessage = "Saved \(capturedImages.count) frames → \(pdfURL.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([pdfURL])
        } catch {
            state = .error("PDF write failed: \(error.localizedDescription)")
        }
    }

    private func ensureAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: CFDictionary = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private func defaultOutputDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("ARC Preso Capture", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }
}
