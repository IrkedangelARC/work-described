//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import UniformTypeIdentifiers

/// One column. SOURCE and OUTPUT are fixed-height tool modules; QUEUE takes
/// the remainder (fixed tools / flexible picture). Window width is the one
/// given quantity; every row fills it.
struct ContentView: View {
    @Bindable var queue: GrabQueue
    @Bindable var settings: Settings

    static let gap: CGFloat = 10
    static let outerPad: CGFloat = 12

    var body: some View {
        VStack(spacing: ContentView.gap) {
            SourceModule(queue: queue, settings: settings)
            OutputModule(settings: settings)
            QueueModule(queue: queue)
                .frame(maxHeight: .infinity)
            FooterBar(queue: queue, settings: settings)
        }
        .padding(ContentView.outerPad)
        .frame(minWidth: 860, minHeight: 640)
        .background(ARCTheme.ink)
        .onDrop(of: [.url, .plainText], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers {
            if p.canLoadObject(ofClass: NSURL.self) {
                handled = true
                _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                    if let u = (obj as? NSURL)?.absoluteString {
                        Task { @MainActor in queue.add(text: u, options: settings.options) }
                    }
                }
            } else if p.canLoadObject(ofClass: NSString.self) {
                handled = true
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    if let s = obj as? String {
                        Task { @MainActor in queue.add(text: s, options: settings.options) }
                    }
                }
            }
        }
        return handled
    }
}
