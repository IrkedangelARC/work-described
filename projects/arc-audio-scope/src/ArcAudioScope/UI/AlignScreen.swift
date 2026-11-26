//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import ScopeKit
import SwiftUI

/// ALIGN: the transfer function (mic against the reference) as magnitude, phase and coherence
/// on the RTA's frequency axis, the impulse response the delay is read from, and the generator.
struct AlignScreen: View {
    var body: some View {
        HStack(alignment: .top, spacing: ARCTheme.paddingSmall) {
            GeometryReader { geo in
                VStack(spacing: 1) {
                    TransferPlot(kind: .magnitude).frame(height: geo.size.height * 0.44)
                    TransferPlot(kind: .phase).frame(height: geo.size.height * 0.26)
                    ImpulsePlot()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius))
            VStack(spacing: ARCTheme.paddingSmall) {
                GeneratorControls()
                TransferControls()
                DelayControls()
                Spacer(minLength: 0)
            }
            .frame(width: 330)
        }
    }
}

private struct TransferPlot: View {
    enum Kind { case magnitude, phase }
    let kind: Kind
    @EnvironmentObject private var model: MeterModel
    @EnvironmentObject private var align: AlignModel
    /// The magnitude scale runs this many dB either side of zero.
    static let span = 24.0

    var body: some View {
        GeometryReader { geo in
            let plot = PlotMetrics.plot(in: geo.size, top: 8, bottom: 24)
            Canvas { ctx, _ in draw(&ctx, plot) }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let x = Double((p.x - plot.minX) / plot.width)
                        align.cursor = (0...1).contains(x) ? x : nil
                    case .ended: align.cursor = nil
                    }
                }
        }
        .background(ARCTheme.ink)
    }

    private func draw(_ ctx: inout GraphicsContext, _ plot: CGRect) {
        let r = model.displayedTransfer
        let settings = model.show.align
        let threshold = settings.coherenceThreshold
        let unwrap = kind == .phase && settings.unwrap
        let traces = model.show.transferTraces.filter(\.visible)
        let liveCount = r.frequencies.count
        let n = liveCount > 0 ? liveCount : traces.first?.magnitudeDB.count ?? 0
        let livePhase = unwrap ? r.unwrappedPhase(threshold: Float(threshold)) : r.phaseDegrees
        let tracePhases = traces.map { unwrap ? TransferResult.unwrap($0.phaseDegrees, trusted: $0.trusted) : $0.phaseDegrees }
        // Unwrapped phase runs as far as it runs: the scale grows in half turns to hold it.
        var top = kind == .magnitude ? Self.span : 180.0
        if unwrap {
            let reach = (tracePhases + [livePhase]).flatMap { $0 }.filter(\.isFinite).map { abs(Double($0)) }.max() ?? 0
            top = max(180, (reach / 180).rounded(.up) * 180)
        }
        let step = kind == .magnitude ? 6.0 : top / 4
        // One line through the points that count. A wrap from +180 to -180 is not a line across the plot.
        func curve(_ count: Int, _ value: (Int) -> Float?) -> Path {
            var line = Path(), pen = false
            var last: Float = 0
            for b in 0..<count {
                guard let v = value(b), v.isFinite else { pen = false; continue }
                if kind == .phase, !unwrap, pen, abs(v - last) > 180 { pen = false }
                last = v
                let p = CGPoint(x: plot.minX + (CGFloat(b) + 0.5) / CGFloat(max(count, 1)) * plot.width,
                                y: plot.minY + CGFloat((top - min(max(Double(v), -top), top)) / (2 * top)) * plot.height)
                if pen { line.addLine(to: p) } else { line.move(to: p); pen = true }
            }
            return line
        }
        func y(_ v: Double) -> CGFloat { plot.minY + CGFloat((top - min(max(v, -top), top)) / (2 * top)) * plot.height }
        func x(_ b: Int) -> CGFloat { plot.minX + (CGFloat(b) + 0.5) / CGFloat(max(n, 1)) * plot.width }

        var v = top
        while v >= -top {
            ctx.fill(Path(CGRect(x: plot.minX, y: y(v), width: plot.width, height: 1)), with: .color(v == 0 ? ARCTheme.text2 : ARCTheme.line))
            ctx.draw(Text(String(format: v == 0 ? "%.0f" : "%+.0f", v)).font(PlotMetrics.axisFont).foregroundStyle(ARCTheme.text0),
                     at: CGPoint(x: plot.minX - 8, y: y(v)), anchor: .trailing)
            v -= step * 2
        }
        for (i, name) in BandLayout.thirdOctaveNames.enumerated() where i % 3 == 2 {
            let gx = plot.minX + CGFloat(BandLayout.reference.position(of: BandLayout.reference.centers[i])) * plot.width
            ctx.fill(Path(CGRect(x: gx, y: plot.minY, width: 1, height: plot.height)), with: .color(ARCTheme.line.opacity(0.6)))
            ctx.draw(Text(name).font(PlotMetrics.axisFont).foregroundStyle(ARCTheme.text0), at: CGPoint(x: gx, y: plot.maxY + 12))
        }

        let centre = kind == .magnitude ? model.transferZero(r) : 0
        var title = kind == .magnitude ? "MAGNITUDE  mic over reference" : unwrap ? "PHASE  unwrapped" : "PHASE"
        if kind == .magnitude, settings.smoothing != 24 { title += "   smoothed 1/\(settings.smoothing) octave" }
        // Captured traces, under the live curve.
        for (i, t) in traces.enumerated() {
            let values = kind == .magnitude ? t.magnitudeDB.map { $0 - centre } : tracePhases[i]
            let path = curve(values.count) { b in b < t.trusted.count && t.trusted[b] ? values[b] : nil }
            ctx.stroke(path, with: .color(traceColors[t.slot % traceColors.count]), lineWidth: 1.2)
        }
        if liveCount == 0 || !r.valid.contains(true) {
            title += align.frame.referenceDB < -90 ? "   NO REFERENCE SIGNAL" : "   WAITING FOR DATA"
        } else {
            if kind == .magnitude {
                // Coherence across the full height, 0 at the bottom to 1 at the top.
                var coh = Path(), pen = false
                for b in 0..<n {
                    guard r.valid[b] else { pen = false; continue }
                    let p = CGPoint(x: x(b), y: plot.maxY - CGFloat(r.coherence[b]) * plot.height)
                    if pen { coh.addLine(to: p) } else { coh.move(to: p); pen = true }
                }
                ctx.stroke(coh, with: .color(ARCTheme.arcRed.opacity(0.55)), lineWidth: 1)
                let ty = plot.maxY - CGFloat(threshold) * plot.height
                ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: ty)); $0.addLine(to: CGPoint(x: plot.maxX, y: ty)) },
                           with: .color(ARCTheme.arcRed.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                ctx.draw(Text("COHERENCE").font(ARCTheme.mono(9)).foregroundStyle(ARCTheme.arcRed.opacity(0.8)),
                         at: CGPoint(x: plot.maxX - 4, y: plot.minY + 8), anchor: .trailing)
                title += String(format: "   0 dB = %+.1f dB", centre)
            }
            let line = curve(liveCount) { b in
                guard r.valid[b], Double(r.coherence[b]) >= threshold else { return nil }
                return kind == .magnitude ? r.magnitudeDB[b] - centre : livePhase[b]
            }
            ctx.stroke(line, with: .color(kind == .magnitude ? ARCTheme.secBlue : ARCTheme.secOrange), lineWidth: 1.5)
        }
        ctx.draw(Text(title).font(ARCTheme.mono(11)).foregroundStyle(ARCTheme.text1), at: CGPoint(x: plot.minX + 8, y: plot.minY + 8), anchor: .leading)

        if let c = align.cursor, n > 0 {
            let cx = plot.minX + CGFloat(c) * plot.width
            ctx.fill(Path(CGRect(x: cx, y: plot.minY, width: 1, height: plot.height)), with: .color(ARCTheme.text0.opacity(0.6)))
            guard kind == .magnitude else { return }
            guard liveCount > 0 else { return }
            let b = min(max(Int(c * Double(liveCount)), 0), liveCount - 1)
            let cells: [(name: String, value: String)] = r.valid[b]
                ? [("FREQUENCY", "\(hzText(r.frequencies[b])) Hz"), ("MAGNITUDE", String(format: "%+.1f dB", Double(r.magnitudeDB[b] - centre))),
                   ("PHASE", String(format: "%+.0f deg", Double(r.phaseDegrees[b]))), ("COHERENCE", String(format: "%.0f%%", Double(r.coherence[b]) * 100))]
                : [("FREQUENCY", "\(hzText(r.frequencies[b])) Hz"), ("MAGNITUDE", "no data")]
            cursorReadout(&ctx, plot, plot.minX + CGFloat(c) * plot.width, cells)
        }
    }
}

/// The impulse response around the arrival: where the delay reading comes from, and what
/// follows it (reflections, a second source).
private struct ImpulsePlot: View {
    @EnvironmentObject private var model: MeterModel
    @EnvironmentObject private var align: AlignModel

    var body: some View {
        GeometryReader { geo in
            let plot = PlotMetrics.plot(in: geo.size, top: 8, bottom: 24)
            Canvas { ctx, _ in
                let f = align.frame, n = f.impulse.count, fs = model.sampleRate
                let mid = plot.midY
                ctx.fill(Path(CGRect(x: plot.minX, y: mid, width: plot.width, height: 1)), with: .color(ARCTheme.line))
                var title = "IMPULSE RESPONSE"
                if n > 1 {
                    let peak = max(f.impulse.map { abs($0) }.max() ?? 0, 1e-12)
                    func x(_ i: Double) -> CGFloat { plot.minX + CGFloat(i / Double(n - 1)) * plot.width }
                    let startMs = Double(f.impulseStart) / fs * 1000, lengthMs = Double(n) / fs * 1000
                    var tick = (startMs / 5).rounded(.up) * 5
                    while tick <= startMs + lengthMs {
                        let tx = x((tick - startMs) / 1000 * fs)
                        ctx.fill(Path(CGRect(x: tx, y: plot.minY, width: 1, height: plot.height)), with: .color(ARCTheme.line.opacity(0.6)))
                        if tx < plot.maxX - 24 { ctx.draw(Text(String(format: "%.0f ms", tick)).font(PlotMetrics.axisFont).foregroundStyle(ARCTheme.text0),
                                 at: CGPoint(x: tx, y: plot.maxY + 12)) }
                        tick += 5
                    }
                    var p = Path()
                    for i in 0..<n {
                        let point = CGPoint(x: x(Double(i)), y: mid - CGFloat(f.impulse[i] / peak) * plot.height * 0.46)
                        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                    }
                    let found = f.estimate?.found ?? false
                    ctx.stroke(p, with: .color(found ? ARCTheme.text0 : ARCTheme.text2), lineWidth: 1)
                    // The delay in use.
                    let ax = x(Double(f.appliedSamples - f.impulseStart))
                    if ax >= plot.minX, ax <= plot.maxX {
                        ctx.fill(Path(CGRect(x: ax, y: plot.minY, width: 1, height: plot.height)), with: .color(ARCTheme.warn))
                        ctx.draw(Text("DELAY IN USE").font(ARCTheme.mono(9)).foregroundStyle(ARCTheme.warn), at: CGPoint(x: ax + 4, y: plot.maxY - 8), anchor: .leading)
                    }
                    if !found { title += "   NO CLEAR ARRIVAL" } else if f.estimate?.inverted == true { title += "   POLARITY INVERTED" }
                } else {
                    title += "   WAITING FOR DATA"
                }
                ctx.draw(Text(title).font(ARCTheme.mono(11)).foregroundStyle(ARCTheme.text1), at: CGPoint(x: plot.minX + 8, y: plot.minY + 8), anchor: .leading)
            }
        }
        .background(ARCTheme.ink)
    }
}

private func stepper(_ text: String, down: @escaping () -> Void, up: @escaping () -> Void) -> some View {
    HStack(spacing: 4) {
        ARCBank([ARCBankItem("-", action: down)]).frame(width: 40)
        Text(text).font(ARCTheme.mono(13)).foregroundStyle(ARCTheme.text0).frame(maxWidth: .infinity)
        ARCBank([ARCBankItem("+", action: up)]).frame(width: 40)
    }
}

private struct GeneratorControls: View {
    @EnvironmentObject private var model: MeterModel

    var body: some View {
        let a = model.show.align, g = a.generator
        VStack(spacing: 6) {
            row("PLAY") {
                ARCBank([ARCBankItem("OFF", on: !model.generatorOn) { model.setGenerator(false) },
                         ARCBankItem("ON", on: model.generatorOn, enabled: model.generatorAvailable) { model.setGenerator(true) }],
                        tint: model.generatorOn ? ARCTheme.warn : ARCTheme.secBlue)
            }
            row("SIGNAL") {
                ARCBank(GeneratorSignal.allCases.map { s in ARCBankItem(s.rawValue, on: g.signal == s) { model.updateAlign { $0.generator.signal = s } } })
            }
            row("LEVEL") {
                stepper(String(format: "%.0f dBFS", g.clampedLevel),
                        down: { model.updateAlign { $0.generator.levelDBFS = $0.generator.clampedLevel - 1 } },
                        up: { model.updateAlign { $0.generator.levelDBFS = $0.generator.clampedLevel + 1 } })
            }
            if g.signal == .sine {
                row("FREQ") {
                    stepper("\(hzText(g.frequency)) Hz",
                            down: { model.updateAlign { $0.generator.frequency = BandLayout.reference.centers[max(BandLayout.reference.index(of: $0.generator.frequency) - 1, 0)] } },
                            up: { model.updateAlign { $0.generator.frequency = BandLayout.reference.centers[min(BandLayout.reference.index(of: $0.generator.frequency) + 1, 30)] } })
                }
            }
            row("OUT") {
                ARCBank(AlignSettings.Output.allCases.map { o in ARCBankItem(o.rawValue, on: a.output == o) { model.updateAlign { $0.output = o } } })
            }
            if !model.generatorAvailable { ARCModuleCaption("This interface has no outputs, so the generator cannot play.") }
        }
        .arcModule(title: "GENERATOR", tint: model.generatorOn ? ARCTheme.warn : ARCTheme.secBlue)
    }
}

private struct TransferControls: View {
    @EnvironmentObject private var model: MeterModel
    @EnvironmentObject private var align: AlignModel

    var body: some View {
        let a = model.show.align, f = align.frame
        func level(_ db: Double) -> String { db.isFinite ? String(format: "%.0f dBFS", db) : "silent" }
        return VStack(spacing: 6) {
            row("REF") {
                ARCBank([ARCBankItem("GENERATOR", on: a.reference == .generator) { model.updateAlign { $0.reference = .generator } },
                         ARCBankItem("INPUT \(model.micChannel == 0 ? 2 : 1)", on: a.reference == .input, enabled: model.mode == .dual) {
                             model.updateAlign { $0.reference = .input }
                         }])
            }
            row("LEVELS") {
                Text("REF \(level(f.referenceDB))   MIC \(level(f.measurementDB))")
                    .font(ARCTheme.mono(12)).foregroundStyle(ARCTheme.text0).frame(maxWidth: .infinity, alignment: .leading)
            }
            row("AVG") {
                ARCBank(AlignSettings.averages.map { s in
                    ARCBankItem(s == 0 ? "INF" : "\(Int(s)) S", on: a.averagingSeconds == s) { model.updateAlign { $0.averagingSeconds = s } }
                })
            }
            row("HIDE") {
                stepper(String(format: "under %.0f%%", a.coherenceThreshold * 100),
                        down: { model.updateAlign { $0.coherenceThreshold -= 0.05 } },
                        up: { model.updateAlign { $0.coherenceThreshold += 0.05 } })
            }
            row("SMOOTH") {
                ARCBank(TransferResult.smoothings.map { s in
                    ARCBankItem(s == 24 ? "OFF" : "1/\(s)", on: a.smoothing == s) { model.updateAlign { $0.smoothing = s } }
                })
            }
            row("PHASE") {
                ARCBank([ARCBankItem("WRAP", on: !a.unwrap) { model.updateAlign { $0.unwrap = false } },
                         ARCBankItem("UNWRAP", on: a.unwrap) { model.updateAlign { $0.unwrap = true } }])
            }
            row("TRACES") { TransferSlots() }
        }
        .arcModule(title: "TRANSFER FUNCTION", tint: ARCTheme.secBlue)
    }
}

/// Eight slots, like the RTA's. Tap an empty one to capture the curves on screen, tap a filled
/// one to show or hide it. Right click or long press to delete it.
private struct TransferSlots: View {
    @EnvironmentObject private var model: MeterModel

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<TransferTrace.limit, id: \.self) { slot in
                let trace = model.show.transferTraces.first { $0.slot == slot }
                Text("\(slot + 1)")
                    .font(ARCTheme.mono(12))
                    .foregroundStyle(trace == nil ? ARCTheme.text2 : trace!.visible ? ARCTheme.ink : traceColors[slot])
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .background(trace != nil && trace!.visible ? traceColors[slot] : ARCTheme.moduleBg, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(trace == nil ? ARCTheme.line : traceColors[slot], lineWidth: 1))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let trace { model.toggleTransferTrace(trace.id) } else { model.captureTransfer(slot: slot) }
                    }
                    .contextMenu {
                        if let trace {
                            Button("Delete trace \(slot + 1)", role: .destructive) { model.deleteTransferTrace(trace.id) }
                        } else {
                            Button("Capture into \(slot + 1)") { model.captureTransfer(slot: slot) }
                        }
                    }
            }
        }
    }
}

private struct DelayControls: View {
    @EnvironmentObject private var model: MeterModel
    @EnvironmentObject private var align: AlignModel

    var body: some View {
        let a = model.show.align, f = align.frame
        let ms = Double(a.delaySamples) / model.sampleRate * 1000
        let metres = ms / 1000 * (331.3 + 0.606 * a.celsius)
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.2f", ms)).font(ARCTheme.mono(30)).monospacedDigit().foregroundStyle(ARCTheme.text0)
                Text("ms").font(ARCTheme.mono(12)).foregroundStyle(ARCTheme.text1)
                Spacer()
                Text(String(format: "%.2f m   %.1f ft", metres, metres / 0.3048)).font(ARCTheme.mono(13)).foregroundStyle(ARCTheme.text0)
            }
            row("DELAY") {
                ARCBank([ARCBankItem(f.finding ? "FINDING" : "FIND", on: f.finding) { model.findDelay() },
                         ARCBankItem("TRACK", on: a.track) { model.updateAlign { $0.track.toggle() } },
                         ARCBankItem("ZERO") { model.updateAlign { $0.track = false; $0.delaySamples = 0 } }])
            }
            row("NUDGE") {
                stepper("\(a.delaySamples) samples",
                        down: { model.updateAlign { $0.track = false; $0.delaySamples -= 1 } },
                        up: { model.updateAlign { $0.track = false; $0.delaySamples += 1 } })
            }
            row("AIR") {
                stepper(String(format: "%.0f C   %.0f F", a.celsius, a.celsius * 9 / 5 + 32),
                        down: { model.updateAlign { $0.celsius -= 1 } }, up: { model.updateAlign { $0.celsius += 1 } })
            }
            ARCModuleCaption(caption(f, a))
        }
        .arcModule(title: "DELAY", tint: ARCTheme.secOrange)
    }

    private func caption(_ f: TransferFrame, _ a: AlignSettings) -> String {
        guard let e = f.estimate else { return "Listening. A reading takes about a second of signal." }
        guard e.found else { return "No clear arrival: the mic is not hearing the reference. Check the generator and the level." }
        var s = String(format: "Measured %.2f ms, arrival %.0f dB over the floor.", e.milliseconds, e.peakToNoiseDB)
        if e.inverted { s += " Polarity is inverted." }
        if a.reference == .generator { s += " With the generator as reference the figure includes the interface's own latency, so the distance reads long." }
        return s
    }
}
