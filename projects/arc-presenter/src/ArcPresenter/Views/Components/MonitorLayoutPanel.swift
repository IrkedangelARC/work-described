//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// The presenter's monitor, shaped from the operator's seat (2026-09-19:
/// "the presenter view fully customisable and resizable using controls on the
/// operator page"). Opens from the MONITOR footer group, the menu, or
/// Cmd Opt Shift L.
///
/// The miniature at the top is the monitor itself: the same solver, at the
/// assigned display's real size, so what the operator drags here is what the
/// presenter gets. Under it, the layout, the one size each layout is solved
/// from, the notes text size, and which modules are on the monitor at all.
/// Every control writes UserPreferences; the monitor re-lays itself out at once.
struct MonitorLayoutPanel: View {
    @Environment(UserPreferences.self) private var prefs
    @Environment(DisplayManager.self) private var displayManager
    @Environment(SlideEngine.self) private var engine

    @State private var dragStart: Double?
    /// A slider writes only while the operator holds it: SwiftUI's Slider writes its value back on
    /// appearance and teardown too, which turned AUTO into a share and dropped the slide to its floor
    /// when the popover closed with the app (seen 2026-09-19).
    @State private var editing: ConfidenceLayout.Quantity?
    @State private var editingText = false

    private static let previewW: CGFloat = 460

    /// The assigned confidence display's size; a 1080-line monitor when none is assigned yet.
    private var monitorSize: CGSize {
        if let s = displayManager.screenFor(.confidence)?.frame.size, s.width > 0, s.height > 0 { return s }
        return CGSize(width: 1920, height: 1080)
    }

    private var slideAspect: Double {
        guard let b = engine.pdfDocument?.page(at: engine.currentIndex)?.bounds(for: .mediaBox), b.height > 0 else { return 16.0 / 9.0 }
        return Double(b.width / b.height)
    }

    var body: some View {
        let _ = prefs.confidenceLayoutVersion
        let mode = prefs.confidenceLayoutMode
        let modules = prefs.confidenceModules
        let screen = displayManager.screenFor(.confidence)
        let L = prefs.solveConfidenceLayout(size: monitorSize, aspect: slideAspect)
        VStack(spacing: 10) {
            preview(L)
                .arcModule(title: "Monitor Layout", tint: ARCTheme.secBlue,
                           badge: ARCBandBadge(text: screen.map { "\($0.localizedName.uppercased())  \($0.resolution)" } ?? "NO MONITOR  1920x1080",
                                               fill: screen == nil ? ARCTheme.warn : ARCTheme.text0))

            // LAYOUT: which of the two, and the one quantity each is solved from.
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    caption("LAYOUT")
                    HStack(spacing: 0) {
                        chip("SLIDES", on: mode == .slides, tip: "The slide leads, notes beside it") { prefs.confidenceLayoutMode = .slides }
                        chip("NOTES", on: mode == .notes, tip: "The notes lead at full width, CURRENT and NEXT as thumbnails") { prefs.confidenceLayoutMode = .notes }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    Spacer(minLength: 0)
                    chip("RESET", on: false, tip: "Back to the stock layout: everything on, default sizes") { prefs.resetConfidenceLayout() }
                }
                if mode == .slides {
                    quantitySlider("SLIDE WIDTH", .slide, L, tip: "The slide's share of the width; the rest is NEXT and NOTES")
                        .disabled(!modules.contains(.next) && !modules.contains(.notes))
                    quantitySlider("TIMER HEIGHT", .timer, L, tip: "The timer strip's share of the slide's column; AUTO is what the slide leaves at its aspect")
                        .disabled(!modules.contains(.timer))
                    quantitySlider("NOTES HEIGHT", .notes, L, tip: "The notes' share of their column; AUTO is what NEXT leaves at its aspect")
                        .disabled(!(modules.contains(.notes) && modules.contains(.next)))
                } else {
                    quantitySlider("ROW HEIGHT", .row, L, tip: "The thumbnail row's share of the height; the notes take the rest")
                    quantitySlider("TIMER WIDTH", .timer, L, tip: "The timer's share of the row; AUTO is what the thumbnails leave at their aspect")
                        .disabled(!modules.contains(.timer))
                }
                HStack(spacing: 8) {
                    slider("NOTES TEXT", value: Binding(get: { prefs.confidenceNotesFontSize }, set: { prefs.confidenceNotesFontSize = $0.rounded() }),
                           range: ConfidenceLayout.notesFontSizeRange, readout: "\(Int(prefs.confidenceNotesFontSize)) PT",
                           tip: "The notes' text size (Cmd+Shift+- / =); each layout keeps its own")
                    Color.clear.frame(width: 52, height: 1)
                }
                .disabled(!modules.contains(.notes))
            }
            .padding(ARCTheme.modulePad)
            .arcModule(title: "Size", tint: ARCTheme.line)

            // MODULES: what is on the monitor besides the live slide, which always is.
            HStack(spacing: 6) {
                chip("NEXT", on: modules.contains(.next), tip: "The next click: a build of this slide, or the next slide") { prefs.setModule(.next, shown: !modules.contains(.next)) }
                chip("TIMER", on: modules.contains(.timer), tip: "The countdown strip") { prefs.setModule(.timer, shown: !modules.contains(.timer)) }
                chip("NOTES", on: modules.contains(.notes), tip: mode == .notes ? "NOTES layout is the notes: switch to SLIDES to take them off" : "The presenter's notes for the live slide") { prefs.setModule(.notes, shown: !modules.contains(.notes)) }
                    .disabled(mode == .notes)
                Rectangle().fill(ARCTheme.line).frame(width: 1, height: 22)
                chip("LOGO", on: prefs.confidenceTimerLogo, tip: "The logo at the right of the TIMER strip") { prefs.confidenceTimerLogo.toggle() }
                    .disabled(!modules.contains(.timer))
                chip("CLOCK", on: prefs.confidenceTimerClock, tip: "The time of day in the TIMER band") { prefs.confidenceTimerClock.toggle() }
                    .disabled(!modules.contains(.timer))
                Spacer(minLength: 0)
            }
            .padding(ARCTheme.modulePad)
            .arcModule(title: "Modules with the slide", tint: ARCTheme.line)

            // TIMER STRIP: what it says besides its digits. The message from the booth lives here too, always.
            let info = prefs.confidenceTimerInfo
            HStack(spacing: 6) {
                chip("NOW", on: info.contains(.cue), tip: "The selected cue's title and speakers, from the RUNDOWN") { prefs.setTimerInfo(.cue, shown: !info.contains(.cue)) }
                chip("NEXT", on: info.contains(.nextCue), tip: "The cue after it") { prefs.setTimerInfo(.nextCue, shown: !info.contains(.nextCue)) }
                chip("ENDS", on: info.contains(.ends), tip: "The time of day a running countdown reaches zero") { prefs.setTimerInfo(.ends, shown: !info.contains(.ends)) }
                chip("ELAPSED", on: info.contains(.elapsed), tip: "Beside a countdown, how long it has run") { prefs.setTimerInfo(.elapsed, shown: !info.contains(.elapsed)) }
                Spacer(minLength: 0)
            }
            .disabled(!modules.contains(.timer))
            .padding(ARCTheme.modulePad)
            .arcModule(title: "Timer readouts", tint: ARCTheme.line)
        }
        .padding(ARCTheme.paddingMedium)
        .frame(width: Self.previewW + 2 * ARCTheme.paddingMedium + 2 * ARCTheme.modulePad + 2)
        .background(ARCTheme.background)
    }

    // MARK: - The miniature

    /// The monitor at the assigned display's real size, scaled to the panel: the
    /// same solver and the same chrome closures as ConfidenceMonitorView, so
    /// every frame here is the frame there. The grip drags here too.
    private func preview(_ L: ConfidenceLayout.Frames) -> some View {
        let size = monitorSize
        let k = Self.previewW / size.width
        return ZStack(alignment: .topLeading) {
            ARCTheme.ink
            Group {
                miniModule("CURRENT", tint: ARCTheme.secCrimson, L.current, L, k)
                if L.shows(.next) { miniModule("NEXT", tint: ARCTheme.secBlue, L.next, L, k) }
                if L.shows(.timer) { miniModule("TIMER", tint: ARCTheme.secGreen, L.timer, L, k) }
                if L.shows(.notes) { miniModule("NOTES", tint: ARCTheme.text2, L.notes, L, k) }
                ForEach(L.grips, id: \.quantity) { g in miniGrip(g, L, k) }
            }
            .offset(x: L.gap * k, y: L.gap * k)
        }
        .frame(width: Self.previewW, height: (size.height * k).rounded())
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    /// A boundary of the miniature: the same drag as the monitor's own grip, scaled. A wider grab than the gap itself: a 6 px gap scaled down is a hair.
    private func miniGrip(_ g: ConfidenceLayout.Grip, _ L: ConfidenceLayout.Frames, _ k: CGFloat) -> some View {
        let grab: CGFloat = 10
        let r = g.rect
        return Rectangle().fill(Color.clear).contentShape(Rectangle())
            .frame(width: g.sideways ? grab : r.width * k, height: g.sideways ? r.height * k : grab)
            .offset(x: r.minX * k - (g.sideways ? (grab - r.width * k) / 2 : 0), y: r.minY * k - (g.sideways ? 0 : (grab - r.height * k) / 2))
            .onHover { inside in if inside { (g.sideways ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStart == nil { dragStart = L.value(of: g.quantity) }
                    guard let start = dragStart else { return }
                    let sign: Double = g.quantity == .notes || g.quantity == .timer ? -1 : 1   // both timer boundaries grow it toward the drag's negative direction
                    let delta = g.sideways ? Double(value.translation.width / ((g.quantity == .slide ? L.content.width - L.gap : L.content.width) * k))
                                           : Double(value.translation.height / (L.content.height * k))
                    prefs.dragQuantity(g.quantity, start + sign * delta)
                }
                .onEnded { _ in dragStart = nil })
    }

    /// One module of the miniature: its band in the module's colour, its name, its ground.
    private func miniModule(_ title: String, tint: Color, _ r: CGRect, _ L: ConfidenceLayout.Frames, _ k: CGFloat) -> some View {
        let band = max(11, (ARCTheme.moduleHeaderH * L.scale * k).rounded())
        return VStack(spacing: 0) {
            HStack {
                Text(title).font(ARCTheme.mono(8, .heavy)).foregroundStyle(ARCTheme.ink).lineLimit(1).padding(.leading, 4)
                Spacer(minLength: 0)
            }
            .frame(height: band)
            .background(tint)
            ARCTheme.panel
        }
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(tint, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .frame(width: max(0, r.width * k), height: max(0, r.height * k))
        .offset(x: r.minX * k, y: r.minY * k)
    }

    // MARK: - Controls

    private func caption(_ text: String) -> some View {
        Text(text).font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.text1).lineLimit(1).fixedSize().frame(width: 112, alignment: .leading)
    }

    /// A quantity's slider: the value the solution shows (AUTO or set), the range for the layout in force,
    /// and an AUTO chip for the two that have one. A slider inside its range can still show AUTO's
    /// value outside it (a 4:3 deck): the readout is honest and the first move clamps.
    private func quantitySlider(_ title: String, _ q: ConfidenceLayout.Quantity, _ L: ConfidenceLayout.Frames, tip: String) -> some View {
        let range = ConfidenceLayout.range(of: q, mode: L.mode)
        let v = L.value(of: q)
        let auto = prefs.isAuto(q)
        return HStack(spacing: 8) {
            caption(title)
            Slider(value: Binding(get: { min(max(v, range.lowerBound), range.upperBound) }, set: { if editing == q { prefs.setQuantity(q, $0) } }),
                   in: range, onEditingChanged: { editing = $0 ? q : nil })
                .tint(auto ? ARCTheme.text2 : ARCTheme.secBlue).controlSize(.small)
            Text("\(Int((v * 100).rounded())) %").font(ARCTheme.mono(13, .bold)).foregroundStyle(auto ? ARCTheme.text1 : ARCTheme.text0).lineLimit(1).fixedSize().frame(width: 52, alignment: .trailing)
            if q == .timer || q == .notes {
                chip("AUTO", on: auto, tip: "Back to the remainder: the picture at its aspect, this in what is left") { prefs.setAuto(q) }
            } else {
                Color.clear.frame(width: 52, height: 1)
            }
        }
        .help(tip)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, readout: String, tip: String) -> some View {
        HStack(spacing: 8) {
            caption(title)
            Slider(value: Binding(get: { value.wrappedValue }, set: { if editingText { value.wrappedValue = $0 } }), in: range, onEditingChanged: { editingText = $0 })
                .tint(ARCTheme.secBlue).controlSize(.small)
            Text(readout).font(ARCTheme.mono(13, .bold)).foregroundStyle(ARCTheme.text0).lineLimit(1).fixedSize().frame(width: 52, alignment: .trailing)
        }
        .help(tip)
    }

    private func chip(_ label: String, on: Bool, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(ARCTheme.mono(13, .heavy))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(on ? ARCTheme.secBlue : ARCTheme.surfaceLight)
                .foregroundStyle(on ? ARCTheme.ink : ARCTheme.textPrimary)
                .cornerRadius(on || label.count > 2 ? 0 : 4)
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}
