//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

@main
struct ArcPresoCaptureApp: App {
    @StateObject private var controller = CaptureController()

    var body: some Scene {
        WindowGroup("ARC Preso Capture") {
            ControlPanel()
                .environmentObject(controller)
                .frame(minWidth: 520, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
    }
}
