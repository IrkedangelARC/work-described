//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit
import ARCShowFormat

struct ContentView: View {
    @Environment(SlideEngine.self) private var engine
    @Environment(ShowFolderSession.self) private var show
    @Environment(TimerEngine.self) private var timer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if engine.isLoaded {
                OperatorView()
            } else {
                LoadView()
            }
        }
        // The session restore is started by the app delegate 0.3 s after
        // launch (after its sweep of stale output windows); this view only
        // has to exist so the scene layer can answer window requests below.
        .onReceive(NotificationCenter.default.publisher(for: .openOutputWindow)) { note in
            guard let raw = note.userInfo?["output"] as? String, let type = OutputType(rawValue: raw) else { return }
            openWindow(id: type.rawValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProgramWindowOnly)) { _ in
            openWindow(id: OutputType.program.rawValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openShareWindow)) { _ in
            openWindow(id: ShareOutput.sceneID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openShowFolder)) { note in
            if let url = note.object as? URL { Task { await show.open(folder: url, timer: timer) } }
            else { pickShowFolder() }
        }
    }

    /// OPEN SHOW: a folder with show.json (from ARC Capture). Documents/ARC Shows by default.
    private func pickShowFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/ARC Shows")
        panel.message = "Choose a show folder (it holds show.json, decks/ and arcdecks/)"
        panel.prompt = "Open Show"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if (try? ShowSpec.load(from: url)) == nil { NSSound.beep(); ShowLog.error("OPEN SHOW: \(url.lastPathComponent) has no show.json"); return }
                await show.open(folder: url, timer: timer)
            }
        }
    }
}
