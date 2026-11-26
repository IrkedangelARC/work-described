//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    #if os(macOS)
    @State private var panel = OutputsPanelController.shared
    #endif

    var body: some View {
        #if os(macOS)
        @Bindable var panel = panel
        // The header, with the OUTPUTS strip, sits above the navigation, so it is on every screen of the
        // console: show list, editor and run view (2026-09-24).
        VStack(spacing: 0) {
            AppHeaderBar()
            NavigationStack {
                ShowListView()
            }
        }
        .background(ARCTheme.background)
        .tint(ARCTheme.accent)
        // With the panel open, the panel shows the confirmation; otherwise the console does.
        .outputConflictAlert(when: !panel.isOpen)
        .sheet(isPresented: $panel.isOpen) {
            OutputsPanel()
                .environment(ArcStageTimerApp.sharedRoutingManager)
                .environment(ArcStageTimerApp.sharedDeckLinkManager)
        }
        // The mode controller cannot open a scene; the console's root view does it for it.
        .onReceive(NotificationCenter.default.publisher(for: .openOperateWidget)) { _ in
            DisplayPlacement.openOutput(StageWindowID.widget, using: openWindow)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openControlWindow)) { _ in
            DisplayPlacement.openOutput(StageWindowID.control, using: openWindow)
        }
        // GO LIVE / OFF AIR from the Show menu (Cmd-Shift-L) and POST /api/golive.
        .onReceive(NotificationCenter.default.publisher(for: .goLive)) { note in
            GoLive.perform(note.userInfo?["on"] as? Bool, open: openWindow)
        }
        #else
        NavigationStack {
            ShowListView()
        }
        .tint(ARCTheme.accent)
        #endif
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Show.self, Cue.self], inMemory: true)
}
