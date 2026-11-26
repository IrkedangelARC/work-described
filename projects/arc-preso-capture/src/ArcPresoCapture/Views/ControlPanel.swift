//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import ScreenCaptureKit

struct ControlPanel: View {
    @EnvironmentObject var controller: CaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            displaySection
            timingSection
            outputSection
            statusSection
            Spacer(minLength: 0)
            controlsSection
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ARC Preso Capture")
                .font(.system(size: 22, weight: .bold))
            Text("Capture every animation step of a deck into a PDF.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DISPLAY").font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("", selection: Binding(
                    get: { controller.selectedDisplayID ?? 0 },
                    set: { controller.selectedDisplayID = $0 }
                )) {
                    ForEach(controller.displays, id: \.displayID) { d in
                        Text("Display \(d.displayID) — \(d.width)×\(d.height)").tag(d.displayID)
                    }
                }
                .labelsHidden()
                Button("Refresh") {
                    Task { await controller.refreshDisplays() }
                }
            }
        }
    }

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TIMING").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Lead-in:")
                Slider(value: $controller.leadInSeconds, in: 0...10, step: 0.5)
                Text(String(format: "%.1fs", controller.leadInSeconds))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
            HStack {
                Text("Delay between advances:")
                Slider(value: $controller.delaySeconds, in: 0.5...10.0, step: 0.5)
                Text(String(format: "%.1fs", controller.delaySeconds))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
            HStack {
                Text("Max slides safety stop:")
                Stepper(value: $controller.maxSlides, in: 10...1000, step: 10) {
                    Text("\(controller.maxSlides)").monospacedDigit()
                }
            }
            HStack {
                Text("Stop after N identical frames:")
                Stepper(value: $controller.stableFrameThreshold, in: 2...10) {
                    Text("\(controller.stableFrameThreshold)").monospacedDigit()
                }
            }
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OUTPUT").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(controller.outputDirectory?.path ?? "(no folder)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") { chooseOutputDir() }
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STATUS").font(.caption).foregroundStyle(.secondary)
            Text(controller.statusMessage)
                .font(.system(.body, design: .monospaced))
            Text("Captured: \(controller.capturedCount)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        HStack {
            switch controller.state {
            case .capturing:
                Button("Stop") { controller.stop() }
                    .keyboardShortcut(.escape)
                    .controlSize(.large)
                    .tint(.red)
            default:
                Button("Start Capture") { controller.start() }
                    .keyboardShortcut(.return)
                    .controlSize(.large)
            }
            Spacer()
        }
    }

    private func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = controller.outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            controller.outputDirectory = url
        }
    }
}
