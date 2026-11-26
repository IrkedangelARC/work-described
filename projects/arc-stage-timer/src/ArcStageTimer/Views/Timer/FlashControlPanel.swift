//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Color flash controls for the stage display.
struct FlashControlPanel: View {
    /// A module on the control DECK fills its column, so it must not hug its keys. The older layouts, which
    /// lay their controls out by content, still do.
    var hugging: Bool = true
    @Environment(StageDirector.self) private var director

    private let flashButtons: [(label: String, color: Color)] = [
        ("Red", .red),
        ("Yellow", .yellow),
        ("Green", .green),
        ("White", .white)
    ]

    var body: some View {
        @Bindable var director = director

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ForEach(flashButtons, id: \.label) { button in
                    Button {
                        director.flash(color: button.color)
                    } label: {
                        // The colour IS the label, so it is a key of that colour, not a floating dot.
                        Text(button.label.uppercased())
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundStyle(ARCTheme.ink)
                            .frame(width: 76, height: 40)
                            .background(button.color)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(button.color, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help(flashHelp(for: button.label))
                }

                Toggle("AUTO-FLASH", isOn: $director.autoFlashEnabled)
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .foregroundStyle(ARCTheme.text0)
                    .toggleStyle(.switch)
                    .tint(ARCTheme.secCrimson)
                    .fixedSize()
                    .help("Auto-Flash: automatically flash the confidence monitor when the timer changes color zones (warning/danger)")
            }
        }
        .frame(maxHeight: hugging ? nil : .infinity, alignment: .topLeading)   // fill the deck row, see TimerRunView.deckFill
        .arcModule(title: "Stage Flash", tint: ARCTheme.secCrimson, hugging: hugging)
    }

    private func flashHelp(for label: String) -> String {
        switch label {
        case "Red": "Flash Red — flash the entire confidence monitor red to urgently signal the speaker"
        case "Yellow": "Flash Yellow — flash the confidence monitor yellow as a warning to the speaker"
        case "Green": "Flash Green — flash the confidence monitor green to signal all clear or go ahead"
        case "White": "Flash White — flash the confidence monitor white to get attention without color meaning"
        default: "Flash \(label) on the confidence monitor"
        }
    }
}
