//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import ScopeKit
import SwiftUI

func hzText(_ f: Double) -> String {
    f >= 9995 ? String(format: "%.1fk", f / 1000) : f >= 1000 ? String(format: "%.2fk", f / 1000) : String(format: "%.0f", f)
}

/// Nearest musical note and how many cents off it, A4 = 440.
func noteText(_ f: Double) -> String {
    guard f > 0 else { return "" }
    let n = 69 + 12 * log2(f / 440)
    let k = Int(n.rounded())
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    return "\(names[((k % 12) + 12) % 12])\(k / 12 - 1) \(String(format: "%+.0f", (n - Double(k)) * 100))c"
}

/// What is under the cursor, as a card: a small name over each large value. It sits in the top
/// corner away from the cursor so it never covers what is being pointed at.
func cursorReadout(_ ctx: inout GraphicsContext, _ plot: CGRect, _ cursorX: CGFloat, _ cells: [(name: String, value: String)]) {
    let pad: CGFloat = 12, gap: CGFloat = 22
    let parts = cells.map { cell in
        (name: ctx.resolve(Text(cell.name).font(ARCTheme.mono(10)).foregroundStyle(ARCTheme.text1)),
         value: ctx.resolve(Text(cell.value).font(ARCTheme.mono(20)).foregroundStyle(ARCTheme.text0)))
    }
    let widths = parts.map { max($0.name.measure(in: plot.size).width, $0.value.measure(in: plot.size).width) }
    let nameH = parts.first?.name.measure(in: plot.size).height ?? 0, valueH = parts.first?.value.measure(in: plot.size).height ?? 0
    let width = widths.reduce(0, +) + gap * CGFloat(max(cells.count - 1, 0)) + pad * 2
    let onLeft = cursorX > plot.midX
    let box = CGRect(x: onLeft ? plot.minX + 8 : plot.maxX - width - 8, y: plot.minY + 26, width: width, height: nameH + valueH + 16)
    ctx.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(ARCTheme.ink.opacity(0.96)))
    ctx.stroke(Path(roundedRect: box, cornerRadius: 4), with: .color(ARCTheme.text1), lineWidth: 1)
    var x = box.minX + pad
    for (i, part) in parts.enumerated() {
        ctx.draw(part.name, at: CGPoint(x: x, y: box.minY + 7), anchor: .topLeading)
        ctx.draw(part.value, at: CGPoint(x: x, y: box.minY + 8 + nameH), anchor: .topLeading)
        x += widths[i] + gap
        if i < parts.count - 1 {
            ctx.fill(Path(CGRect(x: x - gap / 2, y: box.minY + 7, width: 1, height: box.height - 14)), with: .color(ARCTheme.line))
        }
    }
}

/// The eight captured trace colours, by slot.
let traceColors: [Color] = [
    Color(red: 0.90, green: 0.76, blue: 0.16), Color(red: 0.31, green: 0.69, blue: 0.43), Color(red: 0.88, green: 0.57, blue: 0.26),
    Color(red: 0.76, green: 0.40, blue: 0.79), Color(red: 0.25, green: 0.76, blue: 0.79), Color(red: 0.88, green: 0.38, blue: 0.35),
    Color(red: 0.82, green: 0.82, blue: 0.82), Color(red: 0.65, green: 0.85, blue: 0.29),
]

/// The RTA: bars per band, peak hold ticks, the waterfall's floor and ceiling as lines with
/// handles on the dB scale, ring flags on the bands that are ringing, and a cursor readout.
struct SpectrumPlot: View {
    @EnvironmentObject private var model: MeterModel
    @EnvironmentObject private var scope: ScopeModel
    /// dBFS at the top and bottom of the scale.
    static let top = 0.0, bottom = -120.0
    /// The difference view (live minus reference) spans this many dB either side of zero.
    static let differenceSpan = 30.0
    /// 0 and 1 are the floor and ceiling handles, 2 is the frequency axis being dragged along.
    @State private var grabbed: Int?
    @State private var panStart = 0.0

    var body: some View {
        GeometryReader { geo in
            let plot = PlotMetrics.plot(in: geo.size, top: 8, bottom: 24)
            Canvas { ctx, _ in draw(&ctx, plot) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let db = Self.top - Double((g.location.y - plot.minY) / plot.height) * (Self.top - Self.bottom)
                            if grabbed == nil {
                                let s = model.show.scope
                                if g.startLocation.x < plot.minX + 8 {
                                    guard !model.showingDifference else { return }
                                    grabbed = abs(db - s.floorDB) < abs(db - s.ceilingDB) ? 0 : 1
                                } else {
                                    guard s.zoomed else { return }
                                    grabbed = 2
                                    panStart = s.axisLo
                                }
                            }
                            if grabbed == 2 {
                                // The picture follows the finger along the axis.
                                let span = model.show.scope.axisHi - model.show.scope.axisLo
                                let lo = panStart - Double(g.translation.width / max(plot.width, 1)) * span
                                model.updateScope { $0.axisLo = lo; $0.axisHi = lo + span }
                                return
                            }
                            let gap = ScopeSettings.minimumRangeDB
                            model.updateScope { s in
                                if grabbed == 0 { s.floorDB = min(max(db.rounded(), Self.bottom), s.ceilingDB - gap) }
                                else { s.ceilingDB = max(min(db.rounded(), Self.top), s.floorDB + gap) }
                            }
                        }
                        .onEnded { _ in grabbed = nil }
                )
                .cursorTracking(scope, plot)
                .modifier(AxisZoom(plot: plot))
        }
        .background(ARCTheme.ink)
    }

    private func y(_ db: Double, _ plot: CGRect, top: Double = SpectrumPlot.top, bottom: Double = SpectrumPlot.bottom) -> CGFloat {
        plot.minY + CGFloat((top - min(max(db, bottom), top)) / (top - bottom)) * plot.height
    }

    /// The ring time strip's value at a frequency, for the readout card.
    private func decayText(_ f: Double) -> String {
        let ms = scope.frame.ringTimeMs
        let layout = ms.count == model.scopeLayout.count ? model.scopeLayout : BandLayout.reference
        guard !ms.isEmpty, ms.count == layout.count else { return "none yet" }
        let v = Double(ms[layout.index(of: f)])
        return v <= 0 ? "none yet" : v >= 1000 ? String(format: "%.1f s", v / 1000) : String(format: "%.0f ms", v)
    }

    private func frequencyGrid(_ ctx: inout GraphicsContext, _ plot: CGRect) {
        let axis = PlotMetrics.axis(plot, model.show.scope)
        // Octaves, and every third of an octave once there is room for the names.
        let all = axis.width > plot.width * 2.4
        for (i, name) in BandLayout.thirdOctaveNames.enumerated() where all || i % 3 == 2 {
            let x = axis.minX + CGFloat(BandLayout.reference.position(of: BandLayout.reference.centers[i])) * axis.width
            guard x >= plot.minX, x <= plot.maxX else { continue }
            ctx.fill(Path(CGRect(x: x, y: plot.minY, width: 1, height: plot.height)), with: .color(ARCTheme.line.opacity(0.6)))
            ctx.draw(Text(name).font(PlotMetrics.axisFont).foregroundStyle(ARCTheme.text0), at: CGPoint(x: x, y: plot.maxY + 12))
        }
    }

    /// A line through the band centres. Bands with nothing in them break it.
    private func trace(_ values: [Float], _ offsets: [Float], _ plot: CGRect) -> Path {
        var p = Path(), pen = false
        let w = plot.width / CGFloat(values.count)
        for b in 0..<values.count {
            guard values[b] > BandAverager.floorDB else { pen = false; continue }
            let point = CGPoint(x: plot.minX + (CGFloat(b) + 0.5) * w, y: y(Double(values[b] + offsets[b]), plot))
            if pen { p.addLine(to: point) } else { p.move(to: point); pen = true }
        }
        return p
    }

    /// Live minus the reference trace, about a zero line.
    private func drawDifference(_ ctx: inout GraphicsContext, _ plot: CGRect, _ reference: Trace) {
        let span = Self.differenceSpan
        let live = scope.frame.levels, ref = reference.levels(fraction: model.show.scope.fraction)
        for step in 0...6 {
            let db = span - Double(step) * 10
            let yy = y(db, plot, top: span, bottom: -span)
            ctx.fill(Path(CGRect(x: plot.minX, y: yy, width: plot.width, height: 1)), with: .color(db == 0 ? ARCTheme.text1 : ARCTheme.line))
            ctx.draw(Text(String(format: "%+.0f", db)).font(PlotMetrics.axisFont).foregroundStyle(ARCTheme.text0),
                     at: CGPoint(x: plot.minX - 18, y: yy), anchor: .trailing)
        }
        frequencyGrid(&ctx, plot)
        let n = live.count
        if n == ref.count, n > 0 {
            var ctx = ctx
            ctx.clip(to: Path(plot))
            let plot = PlotMetrics.axis(plot, model.show.scope)
            let w = plot.width / CGFloat(n), gap: CGFloat = w >= 5 ? 1 : 0, zero = y(0, plot, top: span, bottom: -span)
            var up = Path(), down = Path()
            for b in 0..<n where live[b] > BandAverager.floorDB && ref[b] > BandAverager.floorDB {
                let d = Double(live[b] - ref[b]), yy = y(d, plot, top: span, bottom: -span)
                let rect = CGRect(x: plot.minX + CGFloat(b) * w, y: min(yy, zero), width: w - gap, height: max(abs(yy - zero), 1))
                if d >= 0 { up.addRect(rect) } else { down.addRect(rect) }
            }
            ctx.fill(up, with: .color(ARCTheme.secBlue))
            ctx.fill(down, with: .color(ARCTheme.secOrange))
        }
        let title = ctx.resolve(Text("LIVE MINUS \(reference.name)").font(ARCTheme.mono(12)).foregroundStyle(traceColors[reference.slot % 8]))
        ctx.draw(title, at: CGPoint(x: plot.minX + 8, y: plot.minY + 10), anchor: .leading)
        if let c = scope.cursor, n == ref.count, n > 0 {
            let x = plot.minX + CGFloat(c) * plot.width
            ctx.fill(Path(CGRect(x: x, y: plot.minY, width: 1, height: plot.height)), with: .color(ARCTheme.text0.opacity(0.6)))
            let f = BandLayout.reference.frequency(at: model.show.scope.axisLo + c * (model.show.scope.axisHi - model.show.scope.axisLo)), b = model.scopeLayout.index(of: f)
            let third = BandLayout.thirdOctaveNames[BandLayout.reference.index(of: f)]
            let value = live[b] > BandAverager.floorDB && ref[b] > BandAverager.floorDB ? String(format: "%+.1f dB", Double(live[b] - ref[b])) : "no data"
            cursorReadout(&ctx, plot, x, [("FREQUENCY", "\(hzText(f)) Hz"), ("LIVE MINUS TRACE", value), ("GEQ FADER", third)])
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ plot: CGRect) {
        let settings = model.show.scope
        let cal = model.calibration?.offsetDB ?? 0
        let offsets = model.bandOffsets
        let frame = scope.frame
        let layout = model.scopeLayout
        if settings.difference, let reference = model.referenceTrace {
            drawDifference(&ctx, plot, reference)
            return
        }

        // dB grid: a line every 10, a number every 20, in the unit on the big readout.
        for step in 0...Int((Self.top - Self.bottom) / 10) {
            let db = Self.top - Double(step) * 10
            let yy = y(db, plot)
            ctx.fill(Path(CGRect(x: plot.minX, y: yy, width: plot.width, height: 1)), with: .color(ARCTheme.line.opacity(step % 2 == 0 ? 1 : 0.5)))
            if step % 2 == 0 {
                ctx.draw(Text(String(format: "%.0f", db + cal)).font(PlotMetrics.axisFont).foregroundStyle(ARCTheme.text0),
                         at: CGPoint(x: plot.minX - 18, y: yy), anchor: .trailing)
            }
        }
        // Frequency grid on the octave centres, named underneath.
        frequencyGrid(&ctx, plot)

        // Bars and peak ticks.
        let n = layout.count
        let visible = plot
        if frame.levels.count == n, offsets.count == n {
            // Along the whole axis, cut to the part on screen.
            var ctx = ctx
            ctx.clip(to: Path(visible))
            let plot = PlotMetrics.axis(visible, settings)
            let w = plot.width / CGFloat(n)
            let gap: CGFloat = w >= 5 ? 1 : 0
            let ringing = Set(scope.openFlags.map { layout.index(of: $0.frequency) })
            var bars = Path(), hot = Path(), proud = Path(), peaks = Path()
            // A bar standing well over the bars around it (half an octave each side) is where a
            // ring or a tone would be. Narrower bandings show a line more sharply, so ask more of them.
            let reach = max(2, settings.fraction / 2), skip = settings.fraction >= 12 ? 1 : 0
            let over: Float = settings.fraction >= 12 ? 10 : settings.fraction == 6 ? 8 : 6
            func standsOut(_ b: Int) -> Bool {
                let v = frame.levels[b] + offsets[b]
                guard settings.style == .bars, v > Float(Self.bottom) + 6 else { return false }
                guard v >= frame.levels[max(b - 1, 0)] + offsets[max(b - 1, 0)], v >= frame.levels[min(b + 1, n - 1)] + offsets[min(b + 1, n - 1)] else { return false }
                var around: [Float] = []
                for k in max(0, b - reach)...min(n - 1, b + reach) where abs(k - b) > skip { around.append(frame.levels[k] + offsets[k]) }
                guard around.count >= 3 else { return false }
                around.sort()
                return v - around[around.count / 2] >= over
            }
            for b in 0..<n {
                let x = plot.minX + CGFloat(b) * w
                let top = y(Double(frame.levels[b] + offsets[b]), plot)
                let rect = CGRect(x: x, y: top, width: w - gap, height: plot.maxY - top)
                if ringing.contains(b) { hot.addRect(rect) } else if standsOut(b) { proud.addRect(rect) } else { bars.addRect(rect) }
                if settings.peakHold, frame.peaks.count == n {
                    peaks.addRect(CGRect(x: x, y: y(Double(frame.peaks[b] + offsets[b]), plot) - 1, width: w - gap, height: 1.5))
                }
            }
            if settings.style == .line {
                var area = trace(frame.levels, offsets, plot)
                if !area.isEmpty {
                    area.addLine(to: CGPoint(x: plot.maxX - w / 2, y: plot.maxY))
                    area.addLine(to: CGPoint(x: plot.minX + w / 2, y: plot.maxY))
                    ctx.fill(area, with: .color(ARCTheme.secBlue.opacity(0.18)))
                }
                ctx.stroke(trace(frame.levels, offsets, plot), with: .color(ARCTheme.secBlue), lineWidth: 2)
            } else {
                ctx.fill(bars, with: .color(ARCTheme.secBlue))
            }
            ctx.fill(proud, with: .color(ARCTheme.warn))
            ctx.fill(hot, with: .color(ARCTheme.arcRed))
            ctx.fill(peaks, with: .color(ARCTheme.text0))
            if !proud.isEmpty || !hot.isEmpty {
                ctx.draw(Text(String(format: "YELLOW BAR  %.0f dB over its neighbours     RED BAR  ringing", over)).font(ARCTheme.mono(10)).foregroundStyle(ARCTheme.text1),
                         at: CGPoint(x: visible.minX + 8, y: visible.minY + 10), anchor: .leading)
            }
        }

        // Captured traces, in their slot colours.
        for t in model.show.traces where t.visible {
            let values = t.levels(fraction: settings.fraction)
            guard values.count == n, offsets.count == n else { continue }
            var ctx = ctx
            ctx.clip(to: Path(visible))
            ctx.stroke(trace(values, offsets, PlotMetrics.axis(visible, settings)), with: .color(traceColors[t.slot % 8]),
                       lineWidth: t.id == settings.referenceTrace ? 2.5 : 1.5)
        }

        // Ring flags: named above the band.
        for flag in scope.openFlags {
            let axis = PlotMetrics.axis(plot, settings)
            let x = axis.minX + CGFloat(BandLayout.reference.position(of: flag.frequency)) * axis.width
            guard x >= plot.minX, x <= plot.maxX else { continue }
            let label = ctx.resolve(Text("RING \(hzText(flag.frequency))").font(ARCTheme.mono(11)).foregroundStyle(.white))
            let s = label.measure(in: plot.size)
            let box = CGRect(x: min(max(x - s.width / 2 - 5, plot.minX), plot.maxX - s.width - 10), y: plot.minY + 2, width: s.width + 10, height: s.height + 4)
            ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(ARCTheme.arcRed))
            ctx.draw(label, at: CGPoint(x: box.midX, y: box.midY))
            ctx.fill(Path(CGRect(x: x, y: box.maxY, width: 1, height: plot.height - box.height - 2)), with: .color(ARCTheme.arcRed.opacity(0.7)))
        }

        // The waterfall's ceiling and floor, with their handles on the scale.
        for (db, name, color) in [(settings.ceilingDB, "C", Color.white), (settings.floorDB, "F", ARCTheme.warn)] {
            let yy = y(db, plot)
            ctx.stroke(Path { p in p.move(to: CGPoint(x: plot.minX, y: yy)); p.addLine(to: CGPoint(x: plot.maxX, y: yy)) },
                       with: .color(color.opacity(0.75)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            let tab = CGRect(x: plot.minX - 12, y: yy - 7, width: 12, height: 14)
            ctx.fill(Path(roundedRect: tab, cornerRadius: 2), with: .color(color))
            ctx.draw(Text(name).font(ARCTheme.mono(10)).foregroundStyle(ARCTheme.ink), at: CGPoint(x: tab.midX, y: tab.midY))
        }

        // The last hand mark stays on the bars for a while: this is the fader to reach for.
        if let m = model.lastMark, let c = m.candidates.first, Date().timeIntervalSince(m.made) < 15 {
            let axis = PlotMetrics.axis(plot, settings)
            let x = axis.minX + CGFloat(BandLayout.reference.position(of: c.frequency)) * axis.width
            if x >= plot.minX, x <= plot.maxX {
                ctx.fill(Path(CGRect(x: x - 1, y: plot.minY, width: 2, height: plot.height)), with: .color(ARCTheme.warn))
                let label = ctx.resolve(Text("MARK \(hzText(c.frequency)) Hz").font(ARCTheme.mono(13)).foregroundStyle(ARCTheme.warn))
                let left = x > plot.midX
                ctx.draw(label, at: CGPoint(x: x + (left ? -6 : 6), y: plot.minY + 34), anchor: left ? .trailing : .leading)
            }
        }

        // Cursor: frequency, level, the GEQ band and the note.
        if let c = scope.cursor, frame.levels.count == n, offsets.count == n {
            let x = plot.minX + CGFloat(c) * plot.width
            ctx.fill(Path(CGRect(x: x, y: plot.minY, width: 1, height: plot.height)), with: .color(ARCTheme.text0.opacity(0.6)))
            let f = BandLayout.reference.frequency(at: settings.axisLo + c * (settings.axisHi - settings.axisLo))
            let b = layout.index(of: f)
            let third = BandLayout.thirdOctaveNames[BandLayout.reference.index(of: f)]
            cursorReadout(&ctx, plot, x, [("FREQUENCY", "\(hzText(f)) Hz"),
                                          ("LEVEL", String(format: "%.1f dB", Double(frame.levels[b] + offsets[b]) + cal)),
                                          ("GEQ FADER", third), ("NOTE", noteText(f)), ("DECAY", decayText(f))])
        }

        if settings.zoomed {
            let ref = BandLayout.reference
            let text = "ZOOM  \(hzText(ref.frequency(at: settings.axisLo))) to \(hzText(ref.frequency(at: settings.axisHi))) Hz.  Drag to move, double tap for all."
            let label = ctx.resolve(Text(text).font(ARCTheme.mono(11)).foregroundStyle(ARCTheme.ink))
            let s = label.measure(in: plot.size)
            let box = CGRect(x: plot.minX + 6, y: plot.maxY - s.height - 10, width: s.width + 10, height: s.height + 4)
            ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(ARCTheme.warn))
            ctx.draw(label, at: CGPoint(x: box.midX, y: box.midY))
        }
    }
}

/// Under the bars: how long each 1/24 band takes to fall 20 dB, slowly averaged. A frequency that
/// keeps hanging on stands up here even when no single hit was flagged.
/// Remembers each band's last value so a band that has just been measured again can light up.
final class DecayStripMemory {
    var last: [Float] = []
    var changedAt: [Double] = []
    /// Measurements in a row that came out long, and the frame the last one was counted on.
    var streak: [Int] = []
    var countedAt: [Double] = []
}

struct RingTimeStrip: View {
    @EnvironmentObject private var model: MeterModel
    @EnvironmentObject private var scope: ScopeModel
    @State private var memory = DecayStripMemory()
    static let height: CGFloat = 118
    /// Above this the analyser's top bands read long on any signal, and no one rings out up there.
    static let gradedBelowHz = 18_000.0
    /// How long a band stays lit after a new measurement, seconds.
    static let glow = 1.5
    /// Times the room's own figure around a band: raised, long, very long.
    static let steps = [1.5, 2.0, 3.0]
    /// Top of the scale, times the room's figure.
    static let topRatio = 3.6

    private static func timeText(_ ms: Double) -> String {
        ms >= 1000 ? String(format: "%.1f s", ms / 1000) : String(format: "%.0f ms", ms)
    }

    /// 0 normal, 1 raised, 2 long, 3 very long.
    private static func grade(_ v: Double, _ typical: Double) -> Int {
        guard v > typical + 100 else { return 0 }
        return v > steps[2] * typical ? 3 : v > steps[1] * typical ? 2 : v > steps[0] * typical ? 1 : 0
    }
    private static let gradeColors: [Color] = [ARCTheme.text2.opacity(0.55), ARCTheme.warn.opacity(0.5), ARCTheme.warn, ARCTheme.arcRed]

    var body: some View {
        GeometryReader { geo in
            let visible = PlotMetrics.plot(in: geo.size, top: 40, bottom: 3)
            Canvas { ctx, _ in
                let ms = scope.frame.ringTimeMs, now = scope.frame.time
                let known = ms.filter { $0 > 0 }.sorted()
                var edge = visible.minX + 2
                func put(_ text: String, _ color: Color, size: CGFloat = 11, gap: CGFloat = 14) {
                    let t = ctx.resolve(Text(text).font(ARCTheme.mono(size)).foregroundStyle(color))
                    ctx.draw(t, at: CGPoint(x: edge, y: 10), anchor: .leading)
                    edge += t.measure(in: geo.size).width + gap
                }
                put("DECAY TIME", ARCTheme.text0, size: 12, gap: 10)
                guard !known.isEmpty else {
                    put("waiting for a hit or a stop in the sound", ARCTheme.text1)
                    return
                }
                put("bands that ring on longer than the bands around them, seen twice running", ARCTheme.text1, gap: 22)

                // Which bands were measured again just now.
                if memory.last.count != ms.count || now < (memory.changedAt.max() ?? 0) {
                    memory.last = ms
                    memory.changedAt = [Double](repeating: -100, count: ms.count)
                    memory.streak = [Int](repeating: 0, count: ms.count)
                    memory.countedAt = [Double](repeating: -100, count: ms.count)
                }
                for b in 0..<ms.count where abs(ms[b] - memory.last[b]) > 0.5 {
                    memory.changedAt[b] = now
                    memory.last[b] = ms[b]
                }

                let room = Double(known[known.count / 2])

                // The scale is times the room's own figure around each band. The bottom line is
                // the room (1x), so a band that behaves like its neighbours draws nothing.
                func yr(_ ratio: Double) -> CGFloat {
                    visible.maxY - CGFloat(min(max(ratio - 1, 0), Self.topRatio - 1) / (Self.topRatio - 1)) * visible.height
                }
                for (ratio, name) in [(1.0, "ROOM"), (2.0, "2x"), (3.0, "3x")] {
                    let yy = yr(ratio)
                    ctx.fill(Path(CGRect(x: visible.minX, y: yy, width: visible.width, height: 1)), with: .color(ARCTheme.line))
                    ctx.draw(Text(name).font(ARCTheme.mono(12)).foregroundStyle(ratio == 1 ? ARCTheme.text1 : Self.gradeColors[Int(ratio)]),
                             at: CGPoint(x: visible.minX - 8, y: min(yy, visible.maxY - 5)), anchor: .trailing)
                }

                let layout = ms.count == model.scopeLayout.count ? model.scopeLayout : BandLayout.reference
                var bars = ctx
                bars.clip(to: Path(visible))
                let plot = PlotMetrics.axis(visible, model.show.scope)
                // Octave lines carried down from the bars above.
                for hz in [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] {
                    let x = plot.minX + CGFloat(BandLayout.reference.position(of: hz)) * plot.width
                    bars.fill(Path(CGRect(x: x, y: visible.minY, width: 1, height: visible.height)), with: .color(ARCTheme.line))
                }
                let w = plot.width / CGFloat(ms.count)
                var paths = [Path(), Path(), Path(), Path()]
                var typicals = [Double](repeating: 0, count: ms.count)
                var grades = [Int](repeating: 0, count: ms.count)
                // Runs of bands that hang on, each named once at its longest band.
                var runs: [(band: Int, ms: Double, grade: Int)] = []
                var inRun = false
                for b in 0..<ms.count where ms[b] > 0 {
                    // Judged against its own region (an octave each side): low bands decay slowly
                    // in any room and through the analyser's longer windows there.
                    let near = ms[max(0, b - 24)...min(ms.count - 1, b + 24)].filter { $0 > 0 }.sorted()
                    let typical = Double(near[near.count / 2]), v = Double(ms[b])
                    typicals[b] = typical
                    let raw = b < layout.count && layout.centers[b] < Self.gradedBelowHz ? Self.grade(v, typical) : 0
                    // One long reading is not a finding: a band is graded once two measurements
                    // running came out long.
                    if memory.changedAt[b] == now, memory.countedAt[b] != now {
                        memory.countedAt[b] = now
                        memory.streak[b] = raw >= 1 ? memory.streak[b] + 1 : 0
                    }
                    let g = memory.streak[b] >= 2 ? raw : 0
                    grades[b] = g
                    let x = plot.minX + CGFloat(b) * w
                    // A long band is never thinner than three points, so it cannot hide.
                    let width = g >= 2 ? max(w - 1, 3) : max(w - (w >= 4 ? 1 : 0), 1)
                    let top = yr(v / max(typical, 1))
                    if top < plot.maxY {
                        paths[g].addRect(CGRect(x: x + (w - width) / 2 - (w >= 4 ? 0.5 : 0), y: top, width: width, height: plot.maxY - top))
                    }
                    if g >= 2 {
                        if inRun, let last = runs.last, b - last.band <= 3 {
                            if v > last.ms { runs[runs.count - 1] = (b, v, max(g, last.grade)) }
                        } else { runs.append((b, v, g)) }
                        inRun = true
                    } else {
                        inRun = false
                    }
                }
                for g in 0..<4 { bars.fill(paths[g], with: .color(Self.gradeColors[g])) }
                // Bands measured again in the last moments: a bright cap that fades.
                for b in 0..<ms.count where ms[b] > 0 && grades[b] >= 1 {
                    let age = now - memory.changedAt[b]
                    guard age >= 0, age < Self.glow else { continue }
                    let fade = 1 - age / Self.glow, top = yr(Double(ms[b]) / max(typicals[b], 1))
                    let x = plot.minX + CGFloat(b) * w
                    bars.fill(Path(CGRect(x: x, y: top - 1, width: max(w, 1), height: 2)), with: .color(.white.opacity(fade)))
                }

                // Legend, then the two numbers that sum it up, as far as there is room.
                let worst = runs.max { $0.ms / max(typicals[$0.band], 1) < $1.ms / max(typicals[$1.band], 1) }
                var summary = ""
                if let worst, worst.band < layout.count {
                    summary += String(format: "LONGEST \(hzText(layout.centers[worst.band])) Hz  \(Self.timeText(worst.ms))  %.1fx", worst.ms / max(typicals[worst.band], 1))
                } else {
                    summary += "nothing rings on"
                }
                let summaryText = ctx.resolve(Text(summary).font(ARCTheme.mono(12)).foregroundStyle(worst == nil ? ARCTheme.text0 : worst!.grade == 3 ? ARCTheme.arcRed : ARCTheme.warn))
                let longestWidth = summaryText.measure(in: geo.size).width
                ctx.draw(summaryText, at: CGPoint(x: visible.maxX - 2, y: 10), anchor: .trailing)
                let roomText = ctx.resolve(Text("ROOM \(Self.timeText(room))").font(ARCTheme.mono(12)).foregroundStyle(ARCTheme.text0))
                ctx.draw(roomText, at: CGPoint(x: visible.maxX - longestWidth - 22, y: 10), anchor: .trailing)
                let summaryWidth = longestWidth + roomText.measure(in: geo.size).width + 20
                for (name, color) in [("1.5x", Self.gradeColors[1]), ("2x", Self.gradeColors[2]), ("3x ITS NEIGHBOURS", Self.gradeColors[3])] {
                    let t = ctx.resolve(Text(name).font(ARCTheme.mono(10)).foregroundStyle(ARCTheme.text1))
                    let tw = t.measure(in: geo.size).width
                    guard edge + 14 + tw < visible.maxX - summaryWidth - 20 else { break }
                    ctx.fill(Path(CGRect(x: edge, y: 5, width: 9, height: 10)), with: .color(color))
                    ctx.draw(t, at: CGPoint(x: edge + 13, y: 10), anchor: .leading)
                    edge += 13 + tw + 12
                }

                // Name the longest few in their own row above the bars, each tied to its band.
                // The worst first, so the band that matters most is never the one left unnamed.
                var placed: [CGRect] = []
                func ratio(_ r: (band: Int, ms: Double, grade: Int)) -> Double { r.ms / max(typicals[r.band], 1) }
                for run in runs.sorted(by: { ratio($0) > ratio($1) }) where run.band < layout.count && placed.count < 6 {
                    let x = plot.minX + (CGFloat(run.band) + 0.5) * w
                    guard x >= visible.minX, x <= visible.maxX else { continue }
                    let text = String(format: "\(hzText(layout.centers[run.band])) Hz  \(Self.timeText(run.ms))  %.1fx", ratio(run))
                    let label = ctx.resolve(Text(text).font(ARCTheme.mono(12)).foregroundStyle(run.grade == 3 ? ARCTheme.text0 : ARCTheme.ink))
                    let size = label.measure(in: geo.size)
                    let left = min(max(x - (size.width + 8) / 2, visible.minX), visible.maxX - size.width - 8)
                    let box = CGRect(x: left, y: 21, width: size.width + 8, height: 16)
                    guard !placed.contains(where: { $0.insetBy(dx: -6, dy: 0).intersects(box) }) else { continue }
                    let color = Self.gradeColors[run.grade]
                    ctx.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(color))
                    ctx.draw(label, at: CGPoint(x: box.midX, y: box.midY))
                    ctx.fill(Path(CGRect(x: x - 0.5, y: box.maxY, width: 1, height: max(0, yr(ratio(run)) - box.maxY))), with: .color(color))
                    placed.append(box)
                }

                // The cursor carries through, with this band's time against the room's.
                if let c = scope.cursor {
                    let cx = visible.minX + CGFloat(c) * visible.width
                    ctx.fill(Path(CGRect(x: cx, y: visible.minY, width: 1, height: visible.height)), with: .color(ARCTheme.text0.opacity(0.6)))
                    let s = model.show.scope
                    let b = layout.index(of: BandLayout.reference.frequency(at: s.axisLo + c * (s.axisHi - s.axisLo)))
                    if b < ms.count, ms[b] > 0, typicals[b] > 0 {
                        let text = String(format: "\(Self.timeText(Double(ms[b])))  %.1fx", Double(ms[b]) / typicals[b])
                        let label = ctx.resolve(Text(text).font(ARCTheme.mono(12)).foregroundStyle(ARCTheme.text0))
                        let size = label.measure(in: geo.size), right = cx + size.width + 14 < visible.maxX
                        let box = CGRect(x: right ? cx + 4 : cx - size.width - 12, y: visible.maxY - 20, width: size.width + 8, height: 16)
                        ctx.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(ARCTheme.moduleBg.opacity(0.92)))
                        ctx.draw(label, at: CGPoint(x: box.midX, y: box.midY))
                    }
                }
            }
        }
        .background(ARCTheme.ink)
    }
}
