//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct SlideNumberField: View {
    @Bindable var engine: SlideEngine

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.right.square")
                .font(.system(size: 13))
                .foregroundStyle(ARCTheme.textSecondary)

            TextField("Go to", text: $engine.jumpText)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundStyle(ARCTheme.textPrimary)
                .textFieldStyle(.plain)
                .frame(width: ARCTheme.jumpFieldW)
                .onSubmit {
                    engine.commitJump()
                }
                .onChange(of: engine.jumpText) { _, newValue in
                    let filtered = newValue.filter { $0.isNumber }
                    if filtered != newValue {
                        engine.jumpText = filtered
                    }
                }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(ARCTheme.surfaceLight)
        .cornerRadius(4)
        .help("Type a slide number and press Enter to jump")
    }
}
