//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Accent color controls: hex input + color picker + quick presets.
struct ColorControls: View {
    @Binding var hex: String

    private let quickColors: [(String, String)] = [
        ("#33D9F5", "Cyan"),
        ("#FFD600", "Yellow"),
        ("#00C853", "Green"),
        ("#FF9100", "Orange"),
        ("#FF1744", "Red"),
        ("#FFFFFF", "White"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Hex input + preview
            HStack(spacing: 8) {
                Text("Color")
                    .font(.system(size: 11))
                    .foregroundStyle(ARCTheme.textSecondary)
                    .frame(width: 60, alignment: .leading)

                RoundedRectangle(cornerRadius: 4)
                    .fill(ARCTheme.color(from: hex))
                    .frame(width: 24, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(ARCTheme.divider, lineWidth: 1)
                    )

                TextField("#33D9F5", text: $hex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .controlSize(.small)
                    .frame(maxWidth: 100)

                ColorPicker("", selection: colorBinding)
                    .labelsHidden()
                    .controlSize(.small)
            }

            // Quick presets
            HStack(spacing: 6) {
                ForEach(quickColors, id: \.0) { colorHex, name in
                    Button {
                        hex = colorHex
                    } label: {
                        Circle()
                            .fill(ARCTheme.color(from: colorHex))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .stroke(hex == colorHex ? Color.white : Color.clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                }
            }
        }
    }

    // Bridge hex string to SwiftUI Color binding
    private var colorBinding: Binding<Color> {
        Binding(
            get: { ARCTheme.color(from: hex) },
            set: { newColor in
                if let components = NSColor(newColor).cgColor.components, components.count >= 3 {
                    let r = Int(components[0] * 255)
                    let g = Int(components[1] * 255)
                    let b = Int(components[2] * 255)
                    hex = String(format: "#%02X%02X%02X", r, g, b)
                }
            }
        )
    }
}
