//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit

struct SourceModule: View {
    @Bindable var queue: GrabQueue
    @Bindable var settings: Settings
    @State private var text = ""
    @State private var flash = ""

    var body: some View {
        VStack(spacing: ARCRow.gap) {
            HStack(spacing: ARCRow.gap) {
                ARCField(placeholder: "ANY VIDEO LINK · YOUTUBE · VIMEO · DRIVE · DROPBOX · A FILE URL · OR SEVERAL", text: $text, onSubmit: add)
                ARCButton(title: "ADD", accent: true, width: 96, disabled: text.isEmpty, action: add)
                ARCButton(title: "PASTE + ADD", width: 120, action: pasteAndAdd)
            }
            ARCLabeledRow(label: "COOKIES") {
                ARCSegment(items: CookieSource.allCases, selection: $settings.options.cookies) { $0.label }
                Text(flash)
                    .font(ARCRow.font)
                    .foregroundStyle(ARCTheme.text2)
                    .frame(width: 220, alignment: .trailing)
            }
            // What an embedded player may need: the page it lives on (a domain-locked Vimeo embed plays
            // only from there) and a password (Vimeo review links, Zoom recordings). Both travel with the job.
            ARCLabeledRow(label: "EMBED") {
                ARCField(placeholder: "REFERER · THE PAGE THE PLAYER IS ON, IF THE LINK ALONE FAILS", text: $settings.options.referer)
                ARCField(placeholder: "PASSWORD", text: $settings.options.videoPassword)
                    .frame(width: 180)
            }
        }
        .arcModule(title: "SOURCE", tint: ARCTheme.secBlue)
    }

    private func add() {
        let n = queue.add(text: text, options: settings.options)
        flash = n == 0 ? "NO URL IN INPUT" : "QUEUED \(n)"
        if n > 0 { text = "" }
    }

    private func pasteAndAdd() {
        guard let s = NSPasteboard.general.string(forType: .string) else { flash = "CLIPBOARD EMPTY"; return }
        let n = queue.add(text: s, options: settings.options)
        flash = n == 0 ? "NO URL ON CLIPBOARD" : "QUEUED \(n)"
    }
}
