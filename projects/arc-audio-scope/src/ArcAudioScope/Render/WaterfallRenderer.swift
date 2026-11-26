//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import ImageIO
import MetalKit
import ScopeKit
import UniformTypeIdentifiers

/// How the waterfall is drawn right now. Changing any of it never touches the stored slices.
struct WaterfallDisplay: Equatable {
    /// Index into `SliceHistory.bandCounts`.
    var fractionIndex = 3
    /// dBFS after weighting. Below the floor is black, above the ceiling white.
    var floorDB: Float = -100
    var ceilingDB: Float = -40
    /// Slices shown top to bottom.
    var spanSlices: Float = 500
    /// Slice number at the top edge. Nil = live (the newest slice).
    var head: Int?
    var map = ScopeSettings.ColorMap.smaart
    /// Per band dB added before colouring (the A or C weighting curve; later the mic correction).
    var offsets: [Float] = []
    /// The part of the frequency axis shown, 0...1 along it.
    var axisLo: Float = 0
    var axisHi: Float = 1
}

enum ColorMaps {
    /// 256 RGBA entries from the floor to the ceiling.
    static func table(_ map: ScopeSettings.ColorMap) -> [UInt8] {
        let stops: [(Double, Double, Double, Double)]
        switch map {
        case .smaart:   // spectrograph: deep blue up through cyan, green, yellow to red
            stops = [(0, 0.02, 0.02, 0.22), (0.2, 0.0, 0.22, 0.85), (0.4, 0.0, 0.75, 0.88), (0.55, 0.05, 0.82, 0.25),
                     (0.75, 0.95, 0.9, 0.05), (0.9, 0.95, 0.4, 0.02), (1, 0.85, 0.05, 0.03)]
        case .inferno:
            stops = [(0, 0.0, 0.0, 0.02), (0.13, 0.12, 0.05, 0.28), (0.25, 0.26, 0.04, 0.41), (0.38, 0.42, 0.09, 0.43),
                     (0.5, 0.58, 0.15, 0.40), (0.63, 0.74, 0.22, 0.32), (0.75, 0.87, 0.32, 0.22), (0.87, 0.96, 0.49, 0.08),
                     (0.95, 0.98, 0.70, 0.12), (1, 0.99, 1.0, 0.64)]
        case .grey:
            stops = [(0, 0.06, 0.06, 0.06), (1, 0.92, 0.92, 0.92)]
        }
        var out = [UInt8](repeating: 255, count: 256 * 4)
        var s = 0
        for i in 0..<256 {
            let t = Double(i) / 255
            while s < stops.count - 2, t > stops[s + 1].0 { s += 1 }
            let a = stops[s], b = stops[s + 1]
            let u = min(max((t - a.0) / max(b.0 - a.0, 1e-9), 0), 1)
            out[i * 4] = UInt8((a.1 + (b.1 - a.1) * u) * 255)
            out[i * 4 + 1] = UInt8((a.2 + (b.2 - a.2) * u) * 255)
            out[i * 4 + 2] = UInt8((a.3 + (b.3 - a.3) * u) * 255)
        }
        return out
    }
}

/// Draws the slice history as a waterfall: newest slice at the top, directly under the bars,
/// one column per band. The history is one float texture used as a ring (row = slice number
/// modulo its height); each frame only the new rows are uploaded.
final class WaterfallRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    var display = WaterfallDisplay()

    private let history: SliceHistory
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let data: MTLTexture
    private let lut: MTLTexture
    private let offsets: MTLTexture
    private var uploadedGeneration = -1, uploadedTotal = 0, uploadedFraction = -1
    private var loadedMap: ScopeSettings.ColorMap?
    private var loadedOffsets: [Float]?
    private var total = 0

    /// `headRow`: texture row just past the slice at the top edge. `held`: slices still stored
    /// behind the top edge. Both are small whole numbers, exact in a float however long the app runs.
    private struct Uniforms {
        var headRow: Float, span: Float, rows: Float, bands: Float
        var floorDB: Float, ceilingDB: Float, held: Float, axisLo: Float = 0
        var axisSpan: Float = 1, pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 pos [[position]]; float2 uv; };
    struct U { float headRow; float span; float rows; float bands; float floorDB; float ceilingDB; float held; float axisLo;
               float axisSpan; float pad0; float pad1; float pad2; };
    vertex V vmain(uint vid [[vertex_id]]) {
        float2 p = float2(vid & 1 ? 1.0 : -1.0, vid & 2 ? 1.0 : -1.0);
        V o;
        o.pos = float4(p, 0, 1);
        o.uv = float2((p.x + 1) * 0.5, (1 - p.y) * 0.5);
        return o;
    }
    fragment float4 fmain(V in [[stage_in]], constant U& u [[buffer(0)]], texture2d<float> data [[texture(0)]],
                          texture2d<float> lut [[texture(1)]], texture2d<float> offs [[texture(2)]]) {
        float age = floor(in.uv.y * u.span);
        if (age >= u.held) return float4(0.045, 0.045, 0.05, 1);
        uint band = min(uint((u.axisLo + in.uv.x * u.axisSpan) * u.bands), uint(u.bands) - 1);
        uint row = uint(fmod(u.headRow - 1.0 - age + u.rows, u.rows));
        float db = data.read(uint2(band, row)).r + offs.read(uint2(band, 0)).r;
        float t = (db - u.floorDB) / max(u.ceilingDB - u.floorDB, 1.0);
        if (t <= 0.0) return float4(0, 0, 0, 1);
        if (t >= 1.0) return float4(1, 1, 1, 1);
        return float4(lut.read(uint2(uint(t * 255.0), 0)).rgb, 1);
    }
    """

    /// Why the last `init` returned nil, for the screen and the control API.
    private(set) static var failure = ""

    init?(history: SliceHistory) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            Self.failure = "this machine has no Metal device"
            return nil
        }
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: Self.shader, options: nil) } catch {
            Self.failure = "the waterfall shader did not compile: \(error.localizedDescription)"
            return nil
        }
        self.device = device
        self.queue = queue
        self.history = history
        let p = MTLRenderPipelineDescriptor()
        p.vertexFunction = library.makeFunction(name: "vmain")
        p.fragmentFunction = library.makeFunction(name: "fmain")
        p.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: p) else {
            Self.failure = "the waterfall pipeline was refused"
            return nil
        }
        self.pipeline = pipeline
        let widest = SliceHistory.bandCounts.max()!
        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = .shaderRead
            return device.makeTexture(descriptor: d)
        }
        guard let data = texture(.r32Float, widest, SliceHistory.capacity), let lut = texture(.rgba8Unorm, 256, 1),
              let offsets = texture(.r32Float, widest, 1) else {
            Self.failure = "the waterfall textures were refused"
            return nil
        }
        self.data = data
        self.lut = lut
        self.offsets = offsets
        super.init()
    }

    /// Bring the textures up to date with the history and the display settings.
    private func sync() {
        let f = display.fractionIndex, n = SliceHistory.bandCounts[f], cap = SliceHistory.capacity
        history.withRows(f) { base, state in
            let all = state.generation != uploadedGeneration || f != uploadedFraction || state.total - uploadedTotal >= cap
            if all {
                data.replace(region: MTLRegionMake2D(0, 0, n, cap), mipmapLevel: 0, withBytes: base, bytesPerRow: n * 4)
            } else {
                for seq in uploadedTotal..<state.total {
                    let row = seq % cap
                    data.replace(region: MTLRegionMake2D(0, row, n, 1), mipmapLevel: 0, withBytes: base + row * n, bytesPerRow: n * 4)
                }
            }
            uploadedGeneration = state.generation
            uploadedTotal = state.total
            uploadedFraction = f
            total = state.total
        }
        if loadedMap != display.map {
            lut.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: ColorMaps.table(display.map), bytesPerRow: 256 * 4)
            loadedMap = display.map
        }
        if loadedOffsets != display.offsets || loadedOffsets?.count != n {
            var o = [Float](repeating: 0, count: n)
            for i in 0..<min(n, display.offsets.count) { o[i] = display.offsets[i] }
            offsets.replace(region: MTLRegionMake2D(0, 0, n, 1), mipmapLevel: 0, withBytes: o, bytesPerRow: n * 4)
            loadedOffsets = display.offsets
        }
    }

    private func encode(_ buffer: MTLCommandBuffer, _ pass: MTLRenderPassDescriptor) {
        sync()
        guard let enc = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let head = min(max(display.head ?? total, 0), total)
        let held = max(0, min(total, SliceHistory.capacity) - (total - head))
        var u = Uniforms(headRow: Float(head % SliceHistory.capacity), span: max(display.spanSlices, 1),
                         rows: Float(SliceHistory.capacity), bands: Float(SliceHistory.bandCounts[display.fractionIndex]),
                         floorDB: display.floorDB, ceilingDB: display.ceilingDB, held: Float(held),
                         axisLo: display.axisLo, axisSpan: max(display.axisHi - display.axisLo, 0.01))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(data, index: 0)
        enc.setFragmentTexture(lut, index: 1)
        enc.setFragmentTexture(offsets, index: 2)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer() else { return }
        encode(buffer, pass)
        buffer.present(drawable)
        buffer.commit()
    }

    /// The waterfall exactly as drawn, as an image: what the control API serves, so a test can
    /// read the picture without anyone looking at the screen.
    func image(width: Int, height: Int) -> CGImage? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: max(width, 1), height: max(height, 1), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        #if os(macOS)
        d.storageMode = .managed
        #endif
        guard let target = device.makeTexture(descriptor: d), let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        encode(buffer, pass)
        #if os(macOS)
        if let blit = buffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        #endif
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: d.width * d.height * 4)
        target.getBytes(&bytes, bytesPerRow: d.width * 4, from: MTLRegionMake2D(0, 0, d.width, d.height), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: d.width, height: d.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: d.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

func pngData(_ image: CGImage) -> Data? {
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest) ? out as Data : nil
}
