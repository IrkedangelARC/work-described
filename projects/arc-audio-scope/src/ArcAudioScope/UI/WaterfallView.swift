//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import MetalKit
import ScopeKit
import SwiftUI

#if os(macOS)
private typealias PlatformRepresentable = NSViewRepresentable
#else
private typealias PlatformRepresentable = UIViewRepresentable
#endif

/// The Metal view itself. All state comes in through `display`.
private struct WaterfallSurface: PlatformRepresentable {
    let renderer: WaterfallRenderer
    let display: WaterfallDisplay

    private func make() -> MTKView {
        let v = MTKView(frame: .zero, device: renderer.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.preferredFramesPerSecond = 30
        v.delegate = renderer
        return v
    }

    #if os(macOS)
    func makeNSView(context: Context) -> MTKView { make() }
    func updateNSView(_ view: MTKView, context: Context) { renderer.display = display }
    #else
    func makeUIView(context: Context) -> MTKView { make() }
    func updateUIView(_ view: MTKView, context: Context) { renderer.display = display }
    #endif
}

/// The waterfall with its time axis, ring and clip markers, cursor line, and the press-to-freeze
/// and drag-to-scrub gestures. Shares the bars' frequency axis: same gutter, same width.
struct WaterfallPanel: View {
    @EnvironmentObject private var model: MeterModel
    @EnvironmentObject private var scope: ScopeModel
    /// Set while a press that started live is holding the picture.
    @State private var holding = false
    @State private var scrubStart = 0.0
    @State private var dragging = false

    var body: some View {
        let settings = model.show.scope
        GeometryReader { geo in
            let plot = PlotMetrics.plot(in: geo.size)
            ZStack(alignment: .topLeading) {
                if let renderer = scope.renderer {
                    WaterfallSurface(renderer: renderer, display: model.waterfallDisplay)
                        .frame(width: plot.width, height: plot.height)
                        .offset(x: plot.minX, y: plot.minY)
                } else {
                    Text("NO WATERFALL. \(WaterfallRenderer.failure)").font(ARCTheme.caption).foregroundStyle(ARCTheme.arcRed)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Canvas { ctx, size in overlay(&ctx, plot, settings) }
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging {
                            dragging = true
                            holding = !scope.isFrozen
                            scope.setFrozen(true)
                            scrubStart = scope.scrubSeconds
                        }
                        // The picture follows the finger: pull up to bring older slices into view.
                        let seconds = scrubStart - Double(g.translation.height / max(plot.height, 1)) * settings.spanSeconds
                        scope.scrub(to: seconds, span: settings.spanSeconds)
                    }
                    .onEnded { g in
                        dragging = false
                        // A click on the frozen picture: analyse the sound at that spot.
                        let still = abs(g.translation.width) < 4 && abs(g.translation.height) < 4
                        if !holding, still, plot.contains(g.startLocation) {
                            let age = Double((g.startLocation.y - plot.minY) / max(plot.height, 1)) * settings.spanSeconds
                            let across = Double((g.startLocation.x - plot.minX) / max(plot.width, 1))
                            let hz = BandLayout.reference.frequency(at: settings.axisLo + across * (settings.axisHi - settings.axisLo))
                            model.markRing(atSlice: scope.headSlice - Int((age / scope.sliceInterval).rounded()), focus: hz)
                        }
                        if holding { scope.setFrozen(false) }
                        holding = false
                    }
            )
            .cursorTracking(scope, plot)
            .modifier(AxisZoom(plot: plot))
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.frame(in: .named("root")), initial: true) { _, frame in
                    scope.waterfallFrame = CGRect(x: frame.minX + plot.minX, y: frame.minY + plot.minY, width: plot.width, height: plot.height)
                }
            })
        }
        .background(ARCTheme.ink)
    }

    private func overlay(_ ctx: inout GraphicsContext, _ plot: CGRect, _ settings: ScopeSettings) {
        let span = settings.spanSeconds
        // Time axis: a tick every second, a label every fifth of the span.
        let labelEvery = max(1, Int(span / 5))
        for s in 0...Int(span) {
            let y = plot.minY + CGFloat(Double(s) / span) * plot.height
            let major = s % labelEvery == 0
            ctx.fill(Path(CGRect(x: plot.minX - (major ? 7 : 4), y: y, width: major ? 7 : 4, height: 1)), with: .color(ARCTheme.text2))
            if major, s > 0, y < plot.maxY - 8 {
                ctx.draw(Text("\(s + Int(scope.scrubSeconds.rounded())) s").font(PlotMetrics.axisFont).foregroundStyle(ARCTheme.text0),
                         at: CGPoint(x: plot.minX - 10, y: y), anchor: .trailing)
            }
        }
        // Frozen: the four seconds the spacebar will analyse, at the top of the view.
        if scope.isFrozen {
            let h = min(CGFloat(ScopeEngine.markSeconds / span) * plot.height, plot.height)
            ctx.fill(Path(CGRect(x: plot.minX, y: plot.minY, width: 3, height: h)), with: .color(ARCTheme.warn))
            ctx.fill(Path(CGRect(x: plot.maxX - 3, y: plot.minY, width: 3, height: h)), with: .color(ARCTheme.warn))
            var edge = Path()
            edge.move(to: CGPoint(x: plot.minX, y: plot.minY + h)); edge.addLine(to: CGPoint(x: plot.maxX, y: plot.minY + h))
            ctx.stroke(edge, with: .color(ARCTheme.warn), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
            let note = ctx.resolve(Text("SPACEBAR ANALYSES THESE 4 SECONDS.  Or click any streak to analyse that spot.").font(ARCTheme.mono(11)).foregroundStyle(ARCTheme.ink))
            let size = note.measure(in: CGSize(width: plot.width, height: 40))
            let box = CGRect(x: plot.minX + 8, y: plot.minY + h - size.height - 8, width: size.width + 10, height: size.height + 4)
            ctx.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(ARCTheme.warn))
            ctx.draw(note, at: CGPoint(x: box.midX, y: box.midY))
        }
        // Ring and clip markers, on the slices they happened at.
        for mark in scope.marks {
            let age = scope.headTime - mark.time
            guard age >= 0, age <= span else { continue }
            let y = plot.minY + CGFloat(age / span) * plot.height
            switch mark.kind {
            case .ring:
                ctx.fill(Path(CGRect(x: plot.minX - 4, y: y - 1, width: 4, height: 3)), with: .color(ARCTheme.arcRed))
                if let hz = mark.frequency {
                    let axis = PlotMetrics.axis(plot, settings)
                    let x = axis.minX + CGFloat(BandLayout.reference.position(of: hz)) * axis.width
                    guard x >= plot.minX, x <= plot.maxX else { continue }
                    var p = Path()
                    p.move(to: CGPoint(x: x - 5, y: y - 7)); p.addLine(to: CGPoint(x: x + 5, y: y - 7)); p.addLine(to: CGPoint(x: x, y: y))
                    p.closeSubpath()
                    ctx.fill(p, with: .color(.white))
                    ctx.stroke(p, with: .color(ARCTheme.arcRed), lineWidth: 1.5)
                }
            case .manual:
                ctx.fill(Path(CGRect(x: plot.minX - 10, y: y - 1, width: 10, height: 3)), with: .color(ARCTheme.warn))
                if let hz = mark.frequency {
                    let axis = PlotMetrics.axis(plot, settings)
                    let x = axis.minX + CGFloat(BandLayout.reference.position(of: hz)) * axis.width
                    guard x >= plot.minX, x <= plot.maxX else { continue }
                    var p = Path()
                    p.move(to: CGPoint(x: x - 6, y: y - 9)); p.addLine(to: CGPoint(x: x + 6, y: y - 9)); p.addLine(to: CGPoint(x: x, y: y))
                    p.closeSubpath()
                    ctx.fill(p, with: .color(ARCTheme.warn))
                    ctx.stroke(p, with: .color(ARCTheme.ink), lineWidth: 1)
                }
            case .clip:
                ctx.fill(Path(CGRect(x: 0, y: y, width: plot.minX, height: 2)), with: .color(ARCTheme.arcRed))
                ctx.draw(Text("CLIP").font(ARCTheme.mono(9)).foregroundStyle(ARCTheme.arcRed), at: CGPoint(x: 2, y: y + 7), anchor: .leading)
            }
        }
        if let c = scope.cursor {
            ctx.fill(Path(CGRect(x: plot.minX + CGFloat(c) * plot.width, y: plot.minY, width: 1, height: plot.height)),
                     with: .color(ARCTheme.text0.opacity(0.6)))
        }
        if scope.isFrozen {
            let text = scope.scrubSeconds > 0.05 ? String(format: "FROZEN  %.1f s BACK", scope.scrubSeconds) : "FROZEN"
            let label = Text(text).font(ARCTheme.mono(12)).foregroundStyle(ARCTheme.ink)
            let resolved = ctx.resolve(label)
            let s = resolved.measure(in: plot.size)
            let box = CGRect(x: plot.maxX - s.width - 18, y: plot.minY + 6, width: s.width + 12, height: s.height + 6)
            ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(ARCTheme.warn))
            ctx.draw(resolved, at: CGPoint(x: box.midX, y: box.midY))
        }
    }
}

/// The frequency axis every plot on the RING OUT screen shares.
enum PlotMetrics {
    /// Left gutter for the dB and time scales, and a little air on the right.
    /// The numbers on every axis: large and bright enough to read from the mix position.
    static let axisFont = ARCTheme.mono(13)
    static let gutter: CGFloat = 60
    static let trailing: CGFloat = 10

    /// The whole frequency axis as a rectangle, of which `plot` is the part on screen. Anything
    /// placed along the axis is placed in this and clipped to `plot`.
    static func axis(_ plot: CGRect, _ s: ScopeSettings) -> CGRect {
        let span = CGFloat(max(s.axisHi - s.axisLo, ScopeSettings.minimumAxisSpan))
        let width = plot.width / span
        return CGRect(x: plot.minX - CGFloat(s.axisLo) * width, y: plot.minY, width: width, height: plot.height)
    }

    static func plot(in size: CGSize, top: CGFloat = 0, bottom: CGFloat = 0) -> CGRect {
        CGRect(x: gutter, y: top, width: max(size.width - gutter - trailing, 1), height: max(size.height - top - bottom, 1))
    }
}

extension BandLayout {
    /// Every banding spans the same range, so any of them places a frequency on the axis.
    static let reference = BandLayout(fraction: 3)
}

/// Pinch to zoom the frequency axis about the fingers, double tap to see all of it again. On
/// every plot that shares the axis, so the bars, the ring time strip and the waterfall move as one.
struct AxisZoom: ViewModifier {
    @EnvironmentObject private var model: MeterModel
    let plot: CGRect
    @State private var start: (lo: Double, hi: Double)?

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { g in
                        let s = model.show.scope
                        let from = start ?? (s.axisLo, s.axisHi)
                        start = from
                        let was = from.hi - from.lo
                        let span = min(max(was / max(Double(g.magnification), 0.01), ScopeSettings.minimumAxisSpan), 1)
                        // The frequency under the fingers stays under them.
                        let at = min(max(Double((g.startLocation.x - plot.minX) / max(plot.width, 1)), 0), 1)
                        let lo = from.lo + at * (was - span)
                        model.updateScope { $0.axisLo = lo; $0.axisHi = lo + span }
                    }
                    .onEnded { _ in start = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.updateScope { $0.axisLo = 0; $0.axisHi = 1 } })
    }
}

extension View {
    /// Pointer position across the plot, as 0...1, into the scope's cursor (Mac pointer or trackpad).
    func cursorTracking(_ scope: ScopeModel, _ plot: CGRect) -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active(let p):
                let x = Double((p.x - plot.minX) / plot.width)
                scope.cursor = (0...1).contains(x) ? x : nil
            case .ended:
                scope.cursor = nil
            }
        }
    }
}
