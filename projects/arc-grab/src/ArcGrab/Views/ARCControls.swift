//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Shared geometry for every control row so siblings align by construction.
enum ARCRow {
    static let height: CGFloat = 26
    static let labelWidth: CGFloat = 84
    static let gap: CGFloat = 8
    static let font = Font.system(size: 12, weight: .bold, design: .monospaced)
    static let fieldFont = Font.system(size: 13, weight: .regular, design: .monospaced)
}

/// Segmented selector: every segment the same width, the row fills the module.
struct ARCSegment<T: Hashable & Identifiable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    var disabled = false

    var body: some View {
        HStack(spacing: 1) {
            ForEach(items) { item in
                let on = item == selection
                Button { selection = item } label: {
                    Text(label(item))
                        .font(ARCRow.font)
                        .tracking(0.6)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(on ? ARCTheme.text0 : ARCTheme.text1)
                        .frame(maxWidth: .infinity)
                        .frame(height: ARCRow.height)
                        .background(on ? ARCTheme.appGrey : ARCTheme.panel)
                }
                .buttonStyle(.plain)
            }
        }
        .background(ARCTheme.line)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(ARCTheme.line, lineWidth: 1))
        .opacity(disabled ? 0.35 : 1)
        .allowsHitTesting(!disabled)
    }
}

/// On/off chip; live green border when on.
struct ARCChip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(title)
                .font(ARCRow.font)
                .tracking(0.6)
                .foregroundStyle(isOn ? ARCTheme.text0 : ARCTheme.text1)
                .frame(maxWidth: .infinity)
                .frame(height: ARCRow.height)
                .background(isOn ? ARCTheme.appGrey : ARCTheme.panel)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(isOn ? ARCTheme.live : ARCTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Push button. `accent` = ARC red fill (the one accent), else raised grey.
struct ARCButton: View {
    let title: String
    var accent = false
    var width: CGFloat? = nil
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(ARCRow.font)
                .tracking(0.6)
                .lineLimit(1)
                .foregroundStyle(ARCTheme.text0)
                .padding(.horizontal, 12)
                .frame(width: width)
                .frame(height: ARCRow.height)
                .background(accent ? ARCTheme.arcRed : ARCTheme.appGrey)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
    }
}

/// Mono text field on the panel ground with a hairline.
struct ARCField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(ARCRow.fieldFont)
            .foregroundStyle(ARCTheme.text0)
            .padding(.horizontal, 8)
            .frame(height: ARCRow.height)
            .background(ARCTheme.panel)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ARCTheme.line, lineWidth: 1))
            .onSubmit(onSubmit)
    }
}

/// Label column + control, the skeleton every OUTPUT row shares.
struct ARCLabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: ARCRow.gap) {
            Text(label)
                .font(ARCRow.font)
                .tracking(0.8)
                .foregroundStyle(ARCTheme.text1)
                .frame(width: ARCRow.labelWidth, alignment: .leading)
            content
        }
        .frame(height: ARCRow.height)
    }
}
