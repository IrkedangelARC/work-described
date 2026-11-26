//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import UniformTypeIdentifiers

struct PreferencesView: View {
    @Environment(UserPreferences.self) private var prefs
    @Environment(KeyBindings.self) private var keyBindings
    @Environment(TimerEngine.self) private var timer

    var body: some View {
        TabView {
            generalTab
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .tabItem { Label("General", systemImage: "gear") }

            keyBindingsTab
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .tabItem { Label("Controls", systemImage: "keyboard") }
        }
        // PTZ surface: ink ground, mono type, labels aligned in a grouped
        // form, captions that wrap instead of truncating (2026-09-12).
        .frame(width: 560, height: 560)
        .font(.system(size: 13, weight: .regular, design: .monospaced))
        .background(ARCTheme.ink)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Confidence Monitor Logo") {
                HStack {
                    if let logo = prefs.customLogoImage {
                        Image(nsImage: logo)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 120, height: 60)
                            .background(Color.black)
                            .cornerRadius(4)
                    } else {
                        Image("ARCLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 120, height: 60)
                            .background(Color.black)
                            .cornerRadius(4)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Button("Choose Logo...") {
                            chooseLogo()
                        }

                        if prefs.hasCustomLogo {
                            Button("Reset to Default") {
                                prefs.clearLogo()
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Text("PNG or JPEG with transparent background works best. Displayed in the bottom-right of the confidence monitor.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ARCTheme.text1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Confidence Monitor Layout") {
                Picker("Layout", selection: Binding(get: { prefs.confidenceLayoutMode }, set: { prefs.confidenceLayoutMode = $0 })) {
                    Text("Slides").tag(ConfidenceLayout.Mode.slides)
                    Text("Notes").tag(ConfidenceLayout.Mode.notes)
                }
                .pickerStyle(.segmented)
                layoutSlider(label: "Notes text size", value: Binding(
                    get: { prefs.confidenceNotesFontSize },
                    set: { prefs.confidenceNotesFontSize = $0 }
                ), range: ConfidenceLayout.notesFontSizeRange, step: ConfidenceLayout.notesFontStep, format: { "\(Int($0)) pt" })
                layoutSlider(label: "Slide width", value: Binding(
                    get: { prefs.confidenceSlideFraction },
                    set: { prefs.confidenceSlideFraction = $0 }
                ), range: ConfidenceLayout.slideFractionRange, step: 0.01, format: { "\(Int(($0 * 100).rounded()))%" })
                layoutSlider(label: "Notes layout: top row", value: Binding(
                    get: { prefs.confidenceNotesRowFraction },
                    set: { prefs.confidenceNotesRowFraction = $0 }
                ), range: ConfidenceLayout.rowFractionRange, step: 0.01, format: { "\(Int(($0 * 100).rounded()))%" })

                HStack {
                    Button("Reset Layout") { prefs.resetConfidenceLayout() }
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Text("Applies live. The slide width is the one thing to set: NOTES takes the room under the slide, NEXT and the timer share the other column, and NOTES and the timer always keep room. Notes text that does not fit shrinks to fit, because a presenter cannot scroll a stage monitor. Also: A- / A+ on the monitor itself, Cmd Shift - / =, and drag the gap between the columns.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ARCTheme.text1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Console") {
                Picker("Console Text Size", selection: Binding(get: { prefs.consoleTextScale }, set: { prefs.consoleTextScale = $0 })) {
                    Text("Standard").tag(1.0)
                    Text("Large").tag(1.15)
                    Text("Larger").tag(1.3)
                }
                Text("Labels, buttons and captions on the operator console. The big readouts (slide counter, clock, timer) do not change. Takes effect at the next launch.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ARCTheme.text1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Show Folder") {
                Toggle("Apply deck updates automatically when the deck is not live", isOn: Binding(
                    get: { prefs.autoApplyDeckUpdates },
                    set: { prefs.autoApplyDeckUpdates = $0 }
                ))

                Text("A newer verified version from ARC Capture replaces a deck that is not live, on the matching slide. The live deck is never changed on its own: its tab reads READY and the operator stages or swaps it.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ARCTheme.text1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Session") {
                Toggle("Reset on Quit", isOn: Binding(
                    get: { prefs.resetOnQuit },
                    set: { prefs.resetOnQuit = $0 }
                ))

                Text("When enabled, quitting ARC Presenter clears all loaded decks and session state. The app opens completely fresh on next launch.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ARCTheme.text1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Timer Defaults") {
                Picker("Default Mode", selection: Binding(
                    get: { timer.mode },
                    set: { timer.mode = $0 }
                )) {
                    ForEach(TimerEngine.Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            }

            Section("Countdown Urgency") {
                urgencyStepper(
                    label: "Warning at",
                    value: Binding(
                        get: { prefs.timerWarningSeconds },
                        set: { prefs.timerWarningSeconds = max($0, prefs.timerCriticalSeconds + 30) }
                    )
                )
                urgencyStepper(
                    label: "Critical at",
                    value: Binding(
                        get: { prefs.timerCriticalSeconds },
                        set: { prefs.timerCriticalSeconds = min($0, prefs.timerWarningSeconds - 30) }
                    )
                )
                Text("Time remaining at which the countdown turns yellow (Warning) and red (Critical). If a countdown is shorter than the threshold, that level is skipped.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ARCTheme.text1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
    }

    private func layoutSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String) -> some View {
        HStack {
            Text(label)
                .frame(width: 130, alignment: .trailing)
            Slider(value: value, in: range, step: step)
            Text(format(value.wrappedValue))
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func urgencyStepper(label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .frame(width: 100, alignment: .trailing)
            Text(formatMMSS(value.wrappedValue))
                .monospacedDigit()
                .frame(width: 60, alignment: .leading)
            Stepper("", value: value, in: 30...3600, step: 30)
                .labelsHidden()
        }
    }

    private func formatMMSS(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Key Bindings Tab

    private var keyBindingsTab: some View {
        Form {
            Section("Navigation Keys") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Next Slide:")
                            .frame(width: 100, alignment: .trailing)
                        Text(keyBindings.nextSlide.map { KeyBindings.keyName(for: $0) }.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Previous Slide:")
                            .frame(width: 100, alignment: .trailing)
                        Text(keyBindings.prevSlide.map { KeyBindings.keyName(for: $0) }.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Toggle Black:")
                            .frame(width: 100, alignment: .trailing)
                        Text(KeyBindings.keyName(for: keyBindings.toggleBlack))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Text("Key bindings are currently read-only. Arrow keys and Page Up/Down work globally (through Stage Manager). Space, Up, and Down arrows work when ARC Presenter is in focus.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ARCTheme.text1)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Reset to Defaults") {
                    keyBindings.resetToDefaults()
                }
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .svg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a logo image for the confidence monitor"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            prefs.setLogo(url: url)
        }
    }
}
