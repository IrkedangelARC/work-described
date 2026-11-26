//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit

struct OutputModule: View {
    @Bindable var settings: Settings

    var body: some View {
        VStack(spacing: ARCRow.gap) {
            ARCLabeledRow(label: "MODE") {
                ARCSegment(items: GrabMode.allCases, selection: $settings.options.mode) { $0.label }
                    .frame(width: 220)
                Text("QUALITY")
                    .font(ARCRow.font).tracking(0.8).foregroundStyle(ARCTheme.text1)
                    .frame(width: ARCRow.labelWidth, alignment: .trailing)
                ARCSegment(items: Quality.allCases, selection: $settings.options.quality,
                           label: { $0.label }, disabled: settings.options.mode == .audio)
            }
            ARCLabeledRow(label: "FORMAT") {
                if settings.options.mode == .video {
                    ARCSegment(items: VideoFormat.allCases, selection: $settings.options.videoFormat) { $0.label }
                } else {
                    ARCSegment(items: AudioFormat.allCases, selection: $settings.options.audioFormat) { $0.label }
                }
            }
            ARCLabeledRow(label: "EXTRAS") {
                ARCChip(title: "SUBTITLES", isOn: $settings.options.subtitles)
                ARCChip(title: "THUMBNAIL", isOn: $settings.options.thumbnail)
                ARCChip(title: "CHAPTERS", isOn: $settings.options.chapters)
                ARCChip(title: "KEEP SOURCE", isOn: $settings.options.keepSource)
                ARCChip(title: "TRANSCRIPT", isOn: $settings.options.transcript)
            }
            ARCLabeledRow(label: "SECTION") {
                ARCField(placeholder: "IN  0:00", text: $settings.options.sectionIn).frame(width: 110)
                ARCField(placeholder: "OUT  END", text: $settings.options.sectionOut).frame(width: 110)
                Text(sectionHint)
                    .font(ARCRow.font)
                    .foregroundStyle(ARCTheme.text2)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            ARCLabeledRow(label: "TO") {
                Text(settings.options.destination)
                    .font(ARCRow.fieldFont)
                    .foregroundStyle(ARCTheme.text0)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: ARCRow.height)
                    .background(ARCTheme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(ARCTheme.line, lineWidth: 1))
                ARCButton(title: "CHOOSE", width: 96, action: choose)
                ARCButton(title: "REVEAL", width: 96) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: settings.options.destination))
                }
            }
        }
        .arcModule(title: "OUTPUT", tint: ARCTheme.secCrimson)   // OUT: what leaves the box (brand roles, 2026-09-18)
    }

    private var sectionHint: String {
        guard settings.options.hasSection else { return "BLANK = WHOLE VIDEO · m:ss OR h:mm:ss" }
        return CommandBuilder.forcesKeyframes(settings.options)
            ? "EXACT CUTS · NO BYTE PROGRESS" : "ORIGINAL CUTS ON KEYFRAMES · NO BYTE PROGRESS"
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: settings.options.destination)
        p.prompt = "Use Folder"
        if p.runModal() == .OK, let u = p.url { settings.options.destination = u.path }
    }
}
