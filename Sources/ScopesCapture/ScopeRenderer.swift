import Foundation
import Metal
import MetalKit

// MARK: - Scope types and per-pane settings

enum ScopeKind: String, CaseIterable, Codable, Identifiable {
    case waveform, vectorscope, satLum, histogram, twinPeaks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .waveform: return "Waveform"
        case .vectorscope: return "Vectorscope"
        case .satLum: return "Sat / Lum"
        case .histogram: return "Histogram"
        case .twinPeaks: return "Twin Peaks"
        }
    }

    var modes: [String] {
        switch self {
        case .waveform: return ["Luma", "RGB", "RGB Parade", "YRGB Parade"]
        case .vectorscope: return ["YUV", "HSL"]
        case .satLum: return ["Chroma", "HSL Saturation"]
        case .histogram: return ["RGB", "Luma", "Saturation", "Hue"]
        case .twinPeaks: return ["RGB"]
        }
    }

    /// Width / height the plot should keep, if any.
    var aspect: CGFloat? {
        switch self {
        case .vectorscope: return 1
        case .twinPeaks: return 0.8
        default: return nil
        }
    }

    fileprivate var accumulateFunction: String {
        switch self {
        case .waveform: return "waveformAccumulate"
        case .vectorscope: return "vectorscopeAccumulate"
        case .satLum: return "satLumAccumulate"
        case .histogram: return "histogramAccumulate"
        case .twinPeaks: return "twinPeaksAccumulate"
        }
    }

    fileprivate var fragmentFunction: String {
        switch self {
        case .waveform: return "waveformFragment"
        case .vectorscope: return "vectorscopeFragment"
        case .satLum: return "satLumFragment"
        case .histogram: return "histogramFragment"
        case .twinPeaks: return "twinPeaksFragment"
        }
    }
}

struct ScopePaneConfig: Codable, Equatable {
    var kind: ScopeKind
    var mode: Int
    /// Trace brightness multiplier (2-D scopes).
    var brightness: Float = 1
    /// Vectorscope magnification (1×, 2×, 5×).
    var zoom: Float = 1
    /// Histogram y axis.
    var logScale = false

    var modeName: String { kind.modes[min(max(mode, 0), kind.modes.count - 1)] }

    static let defaults: [ScopePaneConfig] = [
        ScopePaneConfig(kind: .waveform, mode: 3),
        ScopePaneConfig(kind: .vectorscope, mode: 0),
    ]
}

/// Share of samples in the first / last histogram bin (clipped shadows / highlights).
struct ClipStats: Equatable {
    var low: Float
    var high: Float
}

// MARK: - Shared GPU state

/// Compiled pipelines for every measurement scope, shared by all panes.
final class ScopePipelines {
    let analysis: MTLComputePipelineState
    let satLumCurve: MTLComputePipelineState
    let histogramStats: MTLComputePipelineState
    private let accumulate: [ScopeKind: MTLComputePipelineState]
    private let display: [ScopeKind: MTLRenderPipelineState]

    init(gpu: GPUContext) throws {
        let device = gpu.device
        analysis = try device.makeComputePipelineState(function: gpu.function("analyze"))
        satLumCurve = try device.makeComputePipelineState(function: gpu.function("satLumCurve"))
        histogramStats = try device.makeComputePipelineState(function: gpu.function("histogramStats"))
        var acc: [ScopeKind: MTLComputePipelineState] = [:]
        var disp: [ScopeKind: MTLRenderPipelineState] = [:]
        for kind in ScopeKind.allCases {
            acc[kind] = try device.makeComputePipelineState(function: gpu.function(kind.accumulateFunction))
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = try gpu.function("scopeVertex")
            desc.fragmentFunction = try gpu.function(kind.fragmentFunction)
            desc.colorAttachments[0].pixelFormat = scopePixelFormat
            disp[kind] = try device.makeRenderPipelineState(descriptor: desc)
        }
        accumulate = acc
        display = disp
    }

    func accumulate(_ kind: ScopeKind) -> MTLComputePipelineState { accumulate[kind]! }
    func display(_ kind: ScopeKind) -> MTLRenderPipelineState { display[kind]! }
}

/// Once-per-frame colour analysis shared by every scope: point-samples the frame on a grid
/// of at most ~1080p, dithers by one code value, applies legal range, and writes
/// A = (R′, G′, B′, Y′) and B = (Cb, Cr, hue/360, HSL saturation) as half floats.
/// Main thread only (all scope views draw on the main thread, in queue order).
final class AnalysisPass {
    struct Result {
        let a: MTLTexture
        let b: MTLTexture
        let width: Int
        let height: Int
    }

    struct Params {
        var size: SIMD2<UInt32>
        var legalRange: UInt32
        var ditherStep: Float
    }

    static let maxSamples = 1920 * 1080

    private let gpu: GPUContext
    private let pipelines: ScopePipelines
    private var textures: (a: MTLTexture, b: MTLTexture)?
    private var lastKey: (frame: UInt64, legal: Bool)?
    private var last: Result?

    init(gpu: GPUContext, pipelines: ScopePipelines) {
        self.gpu = gpu
        self.pipelines = pipelines
    }

    static func sampleSize(width: Int, height: Int) -> (Int, Int) {
        let k = min(1, (Double(maxSamples) / Double(width * height)).squareRoot())
        return (max(1, Int(Double(width) * k)), max(1, Int(Double(height) * k)))
    }

    /// Returns the analysis for `frame`, encoding the pass into `cmd` the first time a frame
    /// (or legal-range setting) is seen. Later command buffers on the same queue reuse it.
    func prepare(frame: FrameSource.Frame, legalRange: Bool, cmd: MTLCommandBuffer) -> Result? {
        if let lastKey, lastKey.frame == frame.id, lastKey.legal == legalRange, let last { return last }
        let (w, h) = Self.sampleSize(width: frame.texture.width, height: frame.texture.height)
        if textures == nil || textures!.a.width != w || textures!.a.height != h {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            guard let a = gpu.device.makeTexture(descriptor: desc), let b = gpu.device.makeTexture(descriptor: desc) else { return nil }
            textures = (a, b)
        }
        guard let (a, b) = textures, let enc = cmd.makeComputeCommandEncoder() else { return nil }
        var p = Params(size: [UInt32(w), UInt32(h)], legalRange: legalRange ? 1 : 0, ditherStep: frame.quantizationStep)
        enc.setComputePipelineState(pipelines.analysis)
        enc.setTexture(frame.texture, index: 0)
        enc.setTexture(a, index: 1)
        enc.setTexture(b, index: 2)
        enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        let result = Result(a: a, b: b, width: w, height: h)
        lastKey = (frame.id, legalRange)
        last = result
        return result
    }
}

// MARK: - Renderer

/// Draws one measurement scope pane: accumulate the analysis samples into bins with GPU
/// atomics, then tone-map the bins and draw the graticule in a fragment shader.
final class ScopeRenderer: NSObject, MTKViewDelegate {
    /// Must match `ScopeUniforms` in the shader.
    struct Uniforms {
        var binSize: SIMD2<UInt32>
        var sampleSize: SIMD2<UInt32>
        var planes: UInt32
        var mode: UInt32
        var reference: Float
        var brightness: Float
        var params: SIMD4<Float>
        var viewSize: SIMD2<Float>
    }

    private let gpu: GPUContext
    private let source: FrameSource
    private let analysis: AnalysisPass
    private let pipelines: ScopePipelines
    private var bins: MTLBuffer?
    private var aux: MTLBuffer?

    weak var view: MTKView?

    var config: ScopePaneConfig {
        didSet { if config != oldValue { view?.needsDisplay = true } }
    }

    var legalRange = false {
        didSet { if legalRange != oldValue { view?.needsDisplay = true } }
    }

    /// Histogram clipping readout (RGB / Luma), on the main thread.
    var onClipStats: ((ClipStats) -> Void)?

    init(gpu: GPUContext, source: FrameSource, analysis: AnalysisPass, pipelines: ScopePipelines,
         config: ScopePaneConfig) {
        self.gpu = gpu
        self.source = source
        self.analysis = analysis
        self.pipelines = pipelines
        self.config = config
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        let w = Int(view.drawableSize.width), h = Int(view.drawableSize.height)
        guard w > 0, h > 0,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = gpu.queue.makeCommandBuffer() else { return }
        let frame = source.current
        guard let statsBuffer = encode(into: cmd, pass: pass, frame: frame, width: w, height: h) else { return }
        let wantsClip = config.kind == .histogram && (config.mode == 0 || config.mode == 1)
        cmd.addCompletedHandler { [weak self] _ in
            withExtendedLifetime(frame) {}
            guard wantsClip, let stats = statsBuffer.stats, let self else { return }
            let clip = Self.clipStats(stats, planes: statsBuffer.planes, samples: statsBuffer.samples)
            DispatchQueue.main.async { self.onClipStats?(clip) }
        }
        cmd.present(drawable)
        cmd.commit()
    }

    private struct Encoded {
        let stats: MTLBuffer?
        let planes: Int
        let samples: Int
    }

    private func layout(width w: Int, height h: Int) -> (planes: Int, binW: Int, binH: Int) {
        switch config.kind {
        case .waveform:
            let planes = [1, 3, 3, 4][min(max(config.mode, 0), 3)]
            let parade = config.mode >= 2
            return (planes, max(1, parade ? w / planes : w), h)
        case .histogram:
            return (config.mode == 0 ? 3 : 1, config.mode == 3 ? 360 : 256, 1)
        case .vectorscope, .satLum, .twinPeaks:
            return (1, w, h)
        }
    }

    private func params() -> SIMD4<Float> {
        switch config.kind {
        case .waveform:
            return legalRange ? [-0.07, 1.09, 0, 0] : [-0.04, 1.04, 0, 0]
        case .vectorscope:
            return [VectorscopeGeometry.extent(zoom: config.zoom), Float(VectorscopeGeometry.hslRedAngleDegrees),
                    Float(VectorscopeGeometry.skinLineDegrees), 0]
        case .histogram:
            return [0.10, config.logScale ? 1 : 0, 0, 0]
        case .satLum, .twinPeaks:
            return .zero
        }
    }

    @discardableResult
    private func encode(into cmd: MTLCommandBuffer, pass: MTLRenderPassDescriptor, frame: FrameSource.Frame?,
                        width w: Int, height h: Int) -> Encoded? {
        let kind = config.kind
        let (planes, binW, binH) = layout(width: w, height: h)
        let length = planes * binW * binH * MemoryLayout<UInt32>.stride
        if bins == nil || bins!.length < length {
            bins = gpu.device.makeBuffer(length: length, options: .storageModePrivate)
        }
        let auxLength = kind == .satLum ? binW * MemoryLayout<Float>.stride : 16 * MemoryLayout<UInt32>.stride
        if aux == nil || aux!.length < auxLength {
            aux = gpu.device.makeBuffer(length: max(auxLength, 64), options: .storageModeShared)
        }
        guard let bins, let aux, let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.fill(buffer: bins, range: 0..<length, value: 0)
        if kind == .histogram { blit.fill(buffer: aux, range: 0..<aux.length, value: 0) }
        blit.endEncoding()

        var u = Uniforms(binSize: [UInt32(binW), UInt32(binH)], sampleSize: [0, 0], planes: UInt32(planes),
                         mode: UInt32(config.mode), reference: 8, brightness: config.brightness,
                         params: params(), viewSize: [Float(w), Float(h)])

        var samples = 0
        if let frame, let an = analysis.prepare(frame: frame, legalRange: legalRange, cmd: cmd) {
            samples = an.width * an.height
            u.sampleSize = [UInt32(an.width), UInt32(an.height)]
            let s = Float(samples)
            switch kind {
            case .waveform: u.reference = max(4, s / Float(binW) / Float(binH) * 22)
            case .vectorscope, .satLum: u.reference = max(8, s / Float(binW * binH) * 40)
            case .twinPeaks: u.reference = max(8, s * 2 / Float(binW * binH) * 48)
            case .histogram: break
            }
            guard let enc = cmd.makeComputeCommandEncoder() else { return nil }
            enc.setComputePipelineState(pipelines.accumulate(kind))
            enc.setTexture(an.a, index: 0)
            enc.setTexture(an.b, index: 1)
            enc.setBuffer(bins, offset: 0, index: 0)
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.dispatchThreads(MTLSize(width: an.width, height: an.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.endEncoding()
        }

        if kind == .satLum || kind == .histogram, let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(kind == .satLum ? pipelines.satLumCurve : pipelines.histogramStats)
            enc.setBuffer(bins, offset: 0, index: 0)
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setBuffer(aux, offset: 0, index: 2)
            let threads = kind == .satLum ? binW : 1
            enc.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(threads, 64), height: 1, depth: 1))
            enc.endEncoding()
        }

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setRenderPipelineState(pipelines.display(kind))
        enc.setFragmentBuffer(bins, offset: 0, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        if kind == .satLum || kind == .histogram { enc.setFragmentBuffer(aux, offset: 0, index: 2) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        return Encoded(stats: kind == .histogram ? aux : nil, planes: planes, samples: samples)
    }

    private static func clipStats(_ buffer: MTLBuffer, planes: Int, samples: Int) -> ClipStats {
        guard samples > 0 else { return ClipStats(low: 0, high: 0) }
        let p = buffer.contents().bindMemory(to: UInt32.self, capacity: 16)
        var low: UInt32 = 0, high: UInt32 = 0
        for i in 0..<planes {
            low = max(low, p[1 + 2 * i])
            high = max(high, p[2 + 2 * i])
        }
        return ClipStats(low: Float(low) / Float(samples), high: Float(high) / Float(samples))
    }

    // MARK: Headless

    /// Renders the scope for the source's current frame into a `width`×`height` image
    /// (BGRA8 bytes). Waits for the GPU.
    func renderOffscreen(width: Int, height: Int) throws -> [UInt8] {
        let target = try gpu.makeRenderTarget(width: width, height: height)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let cmd = gpu.queue.makeCommandBuffer(),
              encode(into: cmd, pass: pass, frame: source.current, width: width, height: height) != nil else {
            throw RendererError.setup("scope encode")
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        if let error = cmd.error { throw error }
        return try gpu.readback(target)
    }

    /// GPU time (seconds) to analyse + draw one frame at `width`×`height`; for benchmarking.
    func gpuTime(width: Int, height: Int, freshAnalysis: Bool) throws -> Double {
        let target = try gpu.makeRenderTarget(width: width, height: height)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let cmd = gpu.queue.makeCommandBuffer() else { throw RendererError.setup("bench") }
        if freshAnalysis, let frame = source.current { source.setTexture(frame.texture) } // new frame id
        encode(into: cmd, pass: pass, frame: source.current, width: width, height: height)
        cmd.commit()
        cmd.waitUntilCompleted()
        return cmd.gpuEndTime - cmd.gpuStartTime
    }
}
