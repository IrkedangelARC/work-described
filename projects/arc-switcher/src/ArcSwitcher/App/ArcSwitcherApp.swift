//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

@main
struct ArcSwitcherApp: App {
    @State private var engine = SwitcherEngine()
    @State private var server = HTTPRemoteServer()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                MainView()
            }
            .environment(engine)
            .environment(server)
            .preferredColorScheme(.dark)
            .onAppear {
                server.engine = engine
                server.start()

                // Check accessibility permission (still needed for AppleScript/CGEvent)
                if !WindowManager.hasAccessibilityPermission {
                    WindowManager.requestAccessibilityPermission()
                }

                // Detect the control screen (the display ARC Switcher is on)
                // Slight delay to ensure window is placed on screen
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    engine.windowManager.detectControlScreen()
                }

                // Load saved OBS settings and auto-connect
                if let host = UserDefaults.standard.string(forKey: "OBSHost") {
                    engine.obs.host = host
                }
                if let port = UserDefaults.standard.string(forKey: "OBSPort"),
                   let portNum = UInt16(port) {
                    engine.obs.port = portNum
                }
                if let password = UserDefaults.standard.string(forKey: "OBSPassword"), !password.isEmpty {
                    engine.obs.password = password
                }

                engine.connectOBS()
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    await engine.initializeOBS()
                }
            }
        }
        .windowResizability(.contentSize)

        // Menu bar extra for quick access
        MenuBarExtra {
            MenuBarView()
                .environment(engine)
                .environment(server)
        } label: {
            Image(systemName: "rectangle.on.rectangle.angled")
        }
    }
}
