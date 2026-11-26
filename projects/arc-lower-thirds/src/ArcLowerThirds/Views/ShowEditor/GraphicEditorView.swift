//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Editor for a single graphic's properties.
struct GraphicEditorView: View {
    @Bindable var graphic: Graphic
    let defaultAnimation: AnimationPreset

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Text Lines") {
                TextField("Line 1 (required)", text: $graphic.line1)
                TextField("Line 2 (optional)", text: Binding(
                    get: { graphic.line2 ?? "" },
                    set: { graphic.line2 = $0.isEmpty ? nil : $0 }
                ))
                TextField("Line 3 (optional)", text: Binding(
                    get: { graphic.line3 ?? "" },
                    set: { graphic.line3 = $0.isEmpty ? nil : $0 }
                ))
            }

            Section("Animation") {
                Picker("Preset", selection: $graphic.animationPreset) {
                    ForEach(AnimationPreset.allCases) { preset in
                        Label(preset.displayName, systemImage: preset.sfSymbol)
                            .tag(preset)
                    }
                }
            }

            Section("Accent Color") {
                TextField("Hex color (e.g. #33D9F5)", text: $graphic.accentColor)

                // Color preview
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ARCTheme.color(from: graphic.accentColor))
                        .frame(width: 40, height: 24)
                    Text("Preview")
                        .font(ARCTheme.caption)
                        .foregroundStyle(ARCTheme.textSecondary)
                }

                // Quick presets
                HStack(spacing: 8) {
                    colorButton("#33D9F5", "Cyan")
                    colorButton("#FFD600", "Yellow")
                    colorButton("#00C853", "Green")
                    colorButton("#FF9100", "Orange")
                    colorButton("#FF1744", "Red")
                    colorButton("#FFFFFF", "White")
                }
            }

            Section("Notes") {
                TextField("Notes (optional)", text: Binding(
                    get: { graphic.notes ?? "" },
                    set: { graphic.notes = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                .lineLimit(3...6)
            }

            // Template preview
            Section("Preview") {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black)
                        .frame(height: 120)

                    TemplateRendererView(graphic: graphic, scale: 0.3)
                        .padding(.leading, 12)
                        .padding(.bottom, 10)
                }
            }
        }
        .navigationTitle("Edit Graphic")
    }

    private func colorButton(_ hex: String, _ name: String) -> some View {
        Button {
            graphic.accentColor = hex
        } label: {
            Circle()
                .fill(ARCTheme.color(from: hex))
                .frame(width: 28, height: 28)
                .overlay(
                    Circle()
                        .stroke(graphic.accentColor == hex ? Color.white : Color.clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}
