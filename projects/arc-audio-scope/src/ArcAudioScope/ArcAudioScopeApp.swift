//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

@main
struct ArcAudioScopeApp: App {
    @StateObject private var meter = MeterModel()

    var body: some Scene {
        WindowGroup("ARC Audio Scope") {
            RootScreen()
                .environmentObject(meter)
                .environmentObject(meter.scope)
                .environmentObject(meter.align)
                .preferredColorScheme(.dark)
                .onAppear { meter.begin() }
            #if os(macOS)
                .frame(minWidth: 1180, minHeight: 720)
            #endif
        }
    }
}
