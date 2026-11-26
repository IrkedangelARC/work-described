//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct KeyboardHelpOverlay: View {
    @Binding var isVisible: Bool

    private let shortcuts: [(key: String, action: String)] = [
        ("Right Arrow", "Next slide"),
        ("Left Arrow", "Previous slide"),
        ("Cmd + Left", "First slide"),
        ("Cmd + Right", "Last slide"),
        ("B", "Toggle black output"),
        ("⌘ Esc", "Close all outputs"),
        ("# + Enter", "Jump to slide number"),
        ("Cmd + O", "Open PDF"),
        ("Cmd + Shift + O", "Open program output"),
        ("Cmd + Shift + M", "Open confidence monitor"),
        ("Cmd + Shift + L", "Open all outputs"),
        ("Cmd + Shift + I", "Identify screens"),
        ("Cmd + Shift + T", "Start/stop timer"),
        ("Cmd + Shift + R", "Reset timer"),
        ("Cmd + Shift + C", "Clear message"),
        ("Cmd + Shift + Enter", "Take (push preview to live)"),
        ("Cmd + Shift + U", "Stage the live deck's new version"),
        ("Cmd + Opt + Shift + U", "Swap to it (stage and take)"),
        ("Cmd + ]", "Next deck (preview)"),
        ("Cmd + [", "Previous deck (preview)"),
        ("?", "Show/hide this help"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { isVisible = false }

            VStack(spacing: 0) {
                HStack {
                    Text("KEYBOARD SHORTCUTS")
                        .font(ARCTheme.headerBar)
                        .foregroundStyle(ARCTheme.textPrimary)
                    Spacer()
                    Button { isVisible = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(ARCTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 16)

                ForEach(Array(shortcuts.enumerated()), id: \.offset) { _, shortcut in
                    HStack {
                        Text(shortcut.key)
                            .font(ARCTheme.mono(14, .semibold))
                            .foregroundStyle(ARCTheme.accent)
                            .frame(width: 160, alignment: .trailing)

                        Text(shortcut.action)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(ARCTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 16)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(32)
            .frame(width: 480)
            .background(ARCTheme.surface)
            .cornerRadius(6)
            .shadow(color: .black.opacity(0.5), radius: 20)
        }
    }
}
