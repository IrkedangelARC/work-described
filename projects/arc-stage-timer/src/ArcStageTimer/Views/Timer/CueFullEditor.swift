//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// The full CUE EDITOR: every field of a cue in one sheet, opened from the expand glyph on the
/// sidebar's inline editor (2026-09-25) and from the SHOW EDITOR's run order ("switch the show
/// editor to the new cue editor", same day; it replaced the old CueEditorView form). It edits a CueDraft
/// copy; nothing reaches the cue until SAVE. On the run screen SAVE goes through TimerEngine.updateCue
/// so the edit is one UNDO step; the show editor applies it and re-chains its own start times.
struct CueFullEditor: View {
    let cue: Cue
    /// "CUE 4 / 12" and, on the run screen, whether it is done, next or later (nil in the show editor).
    let position: Int
    let count: Int
    let status: String?
    /// A cue + ADD just made: SAVE reads ADD and works with the defaults unchanged, CANCEL takes it back out.
    var isNew: Bool = false
    let onSave: (CueDraft) -> Void
    var onDelete: (() -> Void)?
    /// CANCEL (or Esc). The show editor uses it to drop a cue that was added and then cancelled.
    var onCancel: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CueDraft
    @State private var original: CueDraft
    @State private var showDeleteConfirm = false

    init(cue: Cue, position: Int, count: Int, status: String?, isNew: Bool = false,
         onSave: @escaping (CueDraft) -> Void, onDelete: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        self.cue = cue
        self.position = position
        self.count = count
        self.status = status
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        let d = CueDraft(cue)
        _draft = State(initialValue: d)
        _original = State(initialValue: d)
    }

    private var isDirty: Bool { draft.normalized != original.normalized }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                HStack(alignment: .top, spacing: ARCTheme.paddingSmall) {
                    VStack(spacing: ARCTheme.paddingSmall) {
                        identityModule
                        formatModule
                        notesModule
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: ARCTheme.paddingSmall) {
                        durationModule
                        scheduleModule
                        thresholdsModule
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(ARCTheme.paddingSmall)
            }
            footer
        }
        .background(ARCTheme.background)
        .frame(minWidth: 900, idealWidth: 900, minHeight: 560, idealHeight: 720)
        .confirmationDialog("Remove this cue?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 0) {
            Image(systemName: draft.format.icon)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(ARCTheme.ink)
                .padding(.leading, ARCTheme.modulePad)
            Text("CUE EDITOR")
                .font(ARCTheme.mono(13, .heavy))
                .tracking(1.4)
                .foregroundStyle(ARCTheme.ink)
                .padding(.leading, 8)
            Spacer()
            Rectangle().fill(ARCTheme.moduleBg).frame(width: ARCTheme.capGap)
            Text(isNew ? "NEW CUE · \(position) / \(count)" : "CUE \(position) / \(count)" + (status.map { " · \($0)" } ?? ""))
                .font(ARCTheme.mono(11, .heavy))
                .foregroundStyle(ARCTheme.text0)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                .background(ARCTheme.ink)
        }
        .frame(height: ARCTheme.moduleHeaderH + 8)
        .background(ARCTheme.secOrange)
    }

    private var footer: some View {
        HStack(spacing: ARCTheme.paddingSmall) {
            if onDelete != nil {
                ARCChip("Remove cue", tint: ARCTheme.liveRed) { showDeleteConfirm = true }
                    .help("Take this cue out of the run order (UNDO brings it back)")
            }
            if isDirty {
                ARCChip("Revert") { draft = original }
                    .help("Put every field back the way it was when the editor opened")
            }
            Spacer()
            Text(isNew ? "NOT ADDED YET" : (isDirty ? "UNSAVED CHANGES" : "NO CHANGES"))
                .font(ARCTheme.mono(11, .heavy))
                .foregroundStyle(isNew || isDirty ? ARCTheme.warn : ARCTheme.text2)
            Button("CANCEL") { onCancel?(); dismiss() }
                .buttonStyle(.plain)
                .font(ARCTheme.mono(13, .heavy))
                .foregroundStyle(ARCTheme.text0)
                .padding(.horizontal, 18)
                .frame(maxHeight: .infinity)
                .background(ARCTheme.surfaceLight)
                .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(ARCTheme.line, lineWidth: 1))
                .cornerRadius(ARCTheme.cornerRadius)
                .keyboardShortcut(.cancelAction)
                .help(isNew ? "Close without adding the cue (Esc)" : "Close without changing the cue (Esc)")
            ARCActionButton(isNew ? "Add" : "Save", enabled: draft.isValid && (isDirty || isNew), size: 13) {
                onSave(draft.normalized)
                dismiss()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .help("Store the changes; UNDO reverts them in one step (⌘↩)")
        }
        .frame(height: 40)
        .padding(ARCTheme.paddingSmall)
        .background(ARCTheme.surface)
    }

    // MARK: - Identity

    private var identityModule: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("TITLE", "Stage and run order", text: $draft.title, prompt: "Keynote Address")
            if draft.title.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("A cue needs a title")
                    .font(ARCTheme.mono(11, .bold))
                    .foregroundStyle(ARCTheme.liveRed)
            }
            field("SUBTITLE", "Stage, under the title", text: $draft.subtitle, prompt: "The Future of AI in Healthcare")
            field("SPEAKERS", "Stage, in the accent colour", text: $draft.speakers, prompt: "Dr. Jane Smith, Alex Chen")
        }
        .arcModule(title: "Cue", tint: ARCTheme.secOrange)
    }

    // MARK: - Format

    private var formatModule: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 4)], spacing: 4) {
                ForEach(CueFormat.allCases) { fmt in
                    ARCChip(tint: ARCTheme.secBlue, on: draft.format == fmt, wide: true) {
                        draft.format = fmt
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: fmt.icon).font(.system(size: 10, weight: .bold))
                            Text(fmt.label.uppercased())
                        }
                    }
                }
            }
            if draft.format == .custom {
                field("CUSTOM FORMAT", "Shown wherever the format is named", text: $draft.customFormatLabel, prompt: "Awards, Demo, Roundtable")
            }
            HStack(spacing: 6) {
                let def = draft.format.defaultDurationSeconds
                ARCChip("Use \(draft.format.label) length \(Self.clock(def))", on: false) {
                    draft.durationSeconds = def
                }
                .disabled(draft.durationSeconds == def)
                .help("Set the duration to this format's standard length")
                Spacer()
            }
        }
        .arcModule(title: "Format", tint: ARCTheme.secBlue)
    }

    // MARK: - Notes

    private var notesModule: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OPERATOR ONLY · NEVER ON STAGE")
                .font(ARCTheme.mono(10, .heavy))
                .foregroundStyle(ARCTheme.text2)
            TextEditor(text: $draft.notes)
                .font(ARCTheme.mono(13, .regular))
                .foregroundStyle(ARCTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 110)
                .background(ARCTheme.surfaceLight)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
                .cornerRadius(4)
        }
        .arcModule(title: "Notes", tint: ARCTheme.line)
    }

    // MARK: - Duration

    private var durationModule: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimeSetter(seconds: $draft.durationSeconds, showHours: true, minimum: 1)
            HStack(spacing: 4) {
                ForEach([-300, -60, -10, 10, 60, 300], id: \.self) { step in
                    ARCChip(Self.nudgeLabel(step), wide: true) {
                        draft.durationSeconds = max(1, draft.durationSeconds + step)
                    }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                ForEach([300, 600, 900, 1200, 1800, 2700, 3600, 5400, 7200, 10800], id: \.self) { preset in
                    ARCChip(Self.presetLabel(preset), tint: ARCTheme.secGreen, on: draft.durationSeconds == preset, wide: true) {
                        draft.durationSeconds = preset
                    }
                }
            }
        }
        .arcModule(title: "Duration", tint: ARCTheme.secGreen,
                   badge: ARCBandBadge(text: Self.clock(draft.durationSeconds), fill: ARCTheme.ink))
    }

    // MARK: - Schedule

    private var scheduleModule: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ARCChip("Unscheduled", tint: ARCTheme.secGreen, on: draft.startTime == nil) {
                    draft.startTime = nil
                }
                ARCChip("Scheduled", tint: ARCTheme.secGreen, on: draft.startTime != nil) {
                    if draft.startTime == nil { draft.startTime = original.startTime ?? Self.nextFiveMinutes() }
                }
                Spacer()
            }
            if let start = draft.startTime {
                HStack(spacing: 10) {
                    Text("START")
                        .font(ARCTheme.mono(11, .heavy))
                        .foregroundStyle(ARCTheme.text1)
                    DatePicker("", selection: Binding(get: { start }, set: { draft.startTime = $0 }),
                               displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                    Text("END \(Self.timeOfDay(start.addingTimeInterval(Double(draft.durationSeconds))))")
                        .font(ARCTheme.mono(13, .heavy))
                        .foregroundStyle(ARCTheme.text0)
                    Spacer()
                }
                ARCModuleCaption("Every later cue re-chains from this one's end when you save.")
            } else {
                ARCModuleCaption("No clock time. The cue runs when it is reached.")
            }
        }
        .arcModule(title: "Schedule", tint: ARCTheme.secGreen)
    }

    // MARK: - Thresholds

    private var thresholdsModule: some View {
        let d = draft.normalized
        return VStack(alignment: .leading, spacing: 10) {
            thresholdRow("WARNING", color: ARCTheme.timerYellow, seconds: $draft.warningThreshold,
                         note: "Timer turns yellow with this much left")
            thresholdRow("DANGER", color: ARCTheme.timerRed, seconds: $draft.dangerThreshold,
                         note: "Timer turns red with this much left")
            if d.warningThreshold != draft.warningThreshold || d.dangerThreshold != draft.dangerThreshold {
                Text("SAVES AS WARNING \(Self.clock(d.warningThreshold)) · DANGER \(Self.clock(d.dangerThreshold)) (danger must be under warning, both inside the duration)")
                    .font(ARCTheme.mono(10, .heavy))
                    .foregroundStyle(ARCTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ThresholdPreview(duration: d.durationSeconds, warning: d.warningThreshold, danger: d.dangerThreshold)
                .frame(height: 18)

            VStack(alignment: .leading, spacing: 6) {
                Text("AT 00:00")
                    .font(ARCTheme.mono(11, .heavy))
                    .foregroundStyle(ARCTheme.text1)
                HStack(spacing: 4) {
                    ARCChip("Count up overtime", tint: ARCTheme.timerRed, on: draft.overtimeAllowed, wide: true) {
                        draft.overtimeAllowed = true
                    }
                    ARCChip("Stop at zero", tint: ARCTheme.secBlue, on: !draft.overtimeAllowed, wide: true) {
                        draft.overtimeAllowed = false
                    }
                }
                ARCModuleCaption(draft.overtimeAllowed
                    ? "Keeps counting in red (+01:23) until the operator moves on."
                    : "Holds at 00:00, or goes straight to the next cue when AUTO-ADVANCE is on.")
            }
        }
        .arcModule(title: "Thresholds", tint: ARCTheme.secCrimson)
    }

    private func thresholdRow(_ label: String, color: Color, seconds: Binding<Int>, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Rectangle().fill(color).frame(width: 10, height: 10).cornerRadius(2)
                Text(label)
                    .font(ARCTheme.mono(11, .heavy))
                    .foregroundStyle(ARCTheme.text1)
                    .frame(width: 70, alignment: .leading)
                TimeSetter(seconds: seconds, showHours: false, minimum: 0, step: label == "DANGER" ? 5 : 15)
            }
            Text(note.uppercased())
                .font(ARCTheme.mono(10, .bold))
                .foregroundStyle(ARCTheme.text2)
                .padding(.leading, 18)
        }
    }

    // MARK: - Pieces

    private func field(_ label: String, _ where_: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(ARCTheme.mono(11, .heavy))
                    .foregroundStyle(ARCTheme.text1)
                Text(where_.uppercased())
                    .font(ARCTheme.mono(10, .bold))
                    .foregroundStyle(ARCTheme.text2)
            }
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(ARCTheme.text2))
                .font(ARCTheme.mono(14, .medium))
                .foregroundStyle(ARCTheme.textPrimary)
                .textFieldStyle(.plain)
                .padding(7)
                .background(ARCTheme.surfaceLight)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
                .cornerRadius(4)
        }
    }

    static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 5M ... 45M, then 1H, 1H30, 2H, 3H: short enough that five fit a row without an ellipsis.
    private static func presetLabel(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h == 0 { return "\(m)M" }
        return m == 0 ? "\(h)H" : "\(h)H\(m)"
    }

    private static func nudgeLabel(_ step: Int) -> String {
        let sign = step < 0 ? "−" : "+"
        let a = abs(step)
        return a >= 60 ? "\(sign)\(a / 60)M" : "\(sign)\(a)S"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static func timeOfDay(_ date: Date) -> String { timeFormatter.string(from: date) }

    private static func nextFiveMinutes() -> Date {
        let t = Date().timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / 300).rounded(.up) * 300)
    }
}

/// HH : MM : SS typed fields with − / + around them. Typing a value and leaving the field (or Return)
/// commits it; the buttons step by `step` seconds.
private struct TimeSetter: View {
    @Binding var seconds: Int
    var showHours: Bool
    var minimum: Int
    var step: Int = 60

    var body: some View {
        HStack(spacing: 4) {
            stepButton("minus") { seconds = max(minimum, seconds - step) }
            if showHours {
                segment(\.h, max: 23, label: "H", width: 40)
                colon
            }
            segment(\.m, max: showHours ? 59 : 999, label: "M", width: showHours ? 40 : 54)
            colon
            segment(\.s, max: 59, label: "S", width: 40)
            stepButton("plus") { seconds += step }
            Spacer(minLength: 0)
        }
    }

    private var colon: some View {
        Text(":").font(ARCTheme.mono(18, .heavy)).foregroundStyle(ARCTheme.text2)
    }

    /// The total split into the fields shown: H:M:S, or M:S with minutes past 59 when there is no hour field.
    private struct Parts { var h: Int; var m: Int; var s: Int }

    private var parts: Parts {
        showHours ? Parts(h: seconds / 3600, m: (seconds % 3600) / 60, s: seconds % 60)
                  : Parts(h: 0, m: seconds / 60, s: seconds % 60)
    }

    private func segment(_ key: WritableKeyPath<Parts, Int>, max upper: Int, label: String, width: CGFloat) -> some View {
        let value = Binding<Int>(
            get: { parts[keyPath: key] },
            set: { new in
                var p = parts
                p[keyPath: key] = min(Swift.max(new, 0), upper)
                seconds = Swift.max(minimum, p.h * 3600 + p.m * 60 + p.s)
            })
        return VStack(spacing: 1) {
            TextField("", value: value, format: .number.grouping(.never))
                .font(ARCTheme.mono(20, .heavy))
                .foregroundStyle(ARCTheme.textPrimary)
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .frame(width: width)
                .padding(.vertical, 4)
                .background(ARCTheme.surfaceLight)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
                .cornerRadius(4)
            Text(label).font(ARCTheme.mono(9, .heavy)).foregroundStyle(ARCTheme.text2)
        }
    }

    private func stepButton(_ glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .heavy))
                .frame(width: 28, height: 28)
                .foregroundStyle(ARCTheme.text0)
                .background(ARCTheme.surfaceLight)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 12)
    }
}

/// The cue's run as a bar: green, then yellow from WARNING, then red from DANGER, to scale.
private struct ThresholdPreview: View {
    let duration: Int
    let warning: Int
    let danger: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let total = CGFloat(max(duration, 1))
            let dangerW = w * CGFloat(danger) / total
            let warnW = w * CGFloat(max(0, warning - danger)) / total
            HStack(spacing: 0) {
                Rectangle().fill(ARCTheme.timerGreen)
                Rectangle().fill(ARCTheme.timerYellow).frame(width: warnW)
                Rectangle().fill(ARCTheme.timerRed).frame(width: dangerW)
            }
            .cornerRadius(3)
        }
        .help("The run to scale: green, yellow from WARNING, red from DANGER")
    }
}
