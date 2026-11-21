import Foundation
import Metal
import MetalKit
import simd

/// Per-pixel image scopes drawn over the picture: false color, skintone, tint and neutrals.
final class ImageScopeRenderer: NSObject, MTKViewDelegate {
    /// Must match `ImageUniforms` in the shader.
    struct Uniforms {
        var scale: SIMD2<Float>
        var opacity: Float
        var legalRange: UInt32
        var colorInGaps: UInt32
        var mode: UInt32
        var channel: UInt32
        var skinMode: UInt32
        var skinCenter: Float
        var skinTolerance: Float
        var skinMinSat: Float
        var dimOthers: UInt32
        var wbRange: Float
        var neutralChroma: Float
        var tintNeutralsOnly: UInt32
        var offset: SIMD2<Float>
    }

    // MARK: Zoom / pan (main thread)

    static let maxZoom: Float = 64
    /// 1 = fit to view.
    private(set) var zoom: Float = 1
    /// Pan of the picture's centre in NDC.
    private var offset = SIMD2<Float>(0, 0)
    /// Called with the new zoom factor after a zoom gesture.
    var onZoomChange: ((Float) -> Void)?

    /// Must match `WBParams` in the shader.
    struct WBParams {
        var sampleSize: SIMD2<UInt32>
        var legalRange: UInt32
        var neutralChroma: Float
    }

    /// Stats are computed on a grid of at most this many samples (int32 accumulators stay safe).
    static let maxStatSamples = 480 * 270

    private let gpu: GPUContext
    private let source: FrameSource
    private let pipeline: MTLRenderPipelineState
    private let statsPipeline: MTLComputePipelineState
    private var lutTexture: MTLTexture

    weak var view: MTKView?

    /// White balance stats for each drawn frame in Tint/Neutrals mode (called on the main thread).
    var onWhiteBalanceStats: ((WhiteBalanceStats) -> Void)?

    var settings = ScopeSettings() {
        didSet {
            if settings.preset != oldValue.preset {
                lutTexture = Self.makeLUTTexture(device: gpu.device, preset: settings.preset)
            }
            view?.needsDisplay = true
        }
    }

    init(gpu: GPUContext, source: FrameSource) throws {
        self.gpu = gpu
        self.source = source
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = try gpu.function("imageVertex")
        desc.fragmentFunction = try gpu.function("imageFragment")
        desc.colorAttachments[0].pixelFormat = scopePixelFormat
        pipeline = try gpu.device.makeRenderPipelineState(descriptor: desc)
        statsPipeline = try gpu.device.makeComputePipelineState(function: gpu.function("wbStats"))
        lutTexture = Self.makeLUTTexture(device: gpu.device, preset: settings.preset)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = gpu.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let frame = source.current
        if let frame {
            encode(enc, input: frame.texture, targetSize: view.drawableSize, fit: true)
        }
        enc.endEncoding()
        let stats = frame.flatMap { encodeStats(into: cmd, input: $0.texture) }
        cmd.addCompletedHandler { [weak self] _ in
            withExtendedLifetime(frame) {}
            guard let stats else { return }
            let result = Self.decodeStats(stats)
            DispatchQueue.main.async { self?.onWhiteBalanceStats?(result) }
        }
        cmd.present(drawable)
        cmd.commit()
    }

    /// NDC half-extent of the picture when fitted (aspect-preserving) into a view of `size`.
    private static func fitScale(texture: MTLTexture, viewSize size: CGSize) -> SIMD2<Float> {
        guard size.width > 0, size.height > 0 else { return [1, 1] }
        let viewAspect = Float(size.width / size.height)
        let texAspect = Float(texture.width) / Float(texture.height)
        return texAspect > viewAspect ? [1, viewAspect / texAspect] : [texAspect / viewAspect, 1]
    }

    /// Keeps the zoomed picture covering the view (no panning past its edges); centres any
    /// axis on which the picture is smaller than the view.
    private func clampOffset(fitScale: SIMD2<Float>) {
        let half = fitScale * zoom
        let limit = simd_max(half - 1, .zero)
        offset = simd_clamp(offset, -limit, limit)
    }

    private var currentFitScale: SIMD2<Float>? {
        guard let tex = source.current?.texture, let view else { return nil }
        return Self.fitScale(texture: tex, viewSize: view.drawableSize)
    }

    /// Zooms by `factor`, keeping the point under `anchor` (NDC) fixed.
    func zoom(by factor: Float, anchor: SIMD2<Float>) {
        guard let fit = currentFitScale else { return }
        let old = zoom
        zoom = min(max(old * factor, 1), Self.maxZoom)
        guard zoom != old else { return }
        offset = anchor - (anchor - offset) * (zoom / old)
        clampOffset(fitScale: fit)
        view?.needsDisplay = true
        onZoomChange?(zoom)
    }

    /// Pans by a delta in NDC.
    func pan(by delta: SIMD2<Float>) {
        guard zoom > 1, let fit = currentFitScale else { return }
        offset += delta
        clampOffset(fitScale: fit)
        view?.needsDisplay = true
    }

    func resetZoom(notify: Bool = true) {
        guard zoom != 1 || offset != .zero else { return }
        zoom = 1
        offset = .zero
        view?.needsDisplay = true
        if notify { onZoomChange?(zoom) }
    }

    private func encode(_ enc: MTLRenderCommandEncoder, input: MTLTexture, targetSize: CGSize, fit: Bool) {
        var scale = SIMD2<Float>(1, 1)
        var pan = SIMD2<Float>(0, 0)
        if fit {
            let fitScale = Self.fitScale(texture: input, viewSize: targetSize)
            clampOffset(fitScale: fitScale)
            scale = fitScale * zoom
            pan = offset
        }
        let s = settings
        var u = Uniforms(scale: scale,
                         opacity: s.opacity,
                         legalRange: s.legalRange ? 1 : 0,
                         colorInGaps: s.colorInGaps ? 1 : 0,
                         mode: Self.modeIndex(s.imageMode),
                         channel: Self.channelIndex(s.preset.channel),
                         skinMode: s.skintoneMode == .ycbcr ? 0 : 1,
                         skinCenter: s.skintoneMode.centerDegrees,
                         skinTolerance: max(s.skinTolerance, 0.5),
                         skinMinSat: s.skinMinSaturation,
                         dimOthers: s.dimNonSkin ? 1 : 0,
                         wbRange: s.wbRange,
                         neutralChroma: s.neutralChroma,
                         tintNeutralsOnly: s.tintNeutralsOnly ? 1 : 0,
                         offset: pan)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(input, index: 0)
        enc.setFragmentTexture(lutTexture, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private static func channelIndex(_ channel: FalseColorPreset.Channel) -> UInt32 {
        switch channel {
        case .luma: return 0
        case .saturation: return 1
        case .lightness: return 2
        case .rgbClipping: return 3
        }
    }

    private static func modeIndex(_ mode: ImageScopeMode) -> UInt32 {
        switch mode {
        case .falseColor: return 0
        case .skintone: return 1
        case .tint: return 2
        case .neutrals: return 3
        }
    }

    /// Adds the white balance reduction to `cmd` when a WB mode is active; returns its result buffer.
    private func encodeStats(into cmd: MTLCommandBuffer, input: MTLTexture) -> MTLBuffer? {
        guard settings.imageMode.isWhiteBalance else { return nil }
        let zeros = [Int32](repeating: 0, count: 6)
        guard let acc = gpu.device.makeBuffer(bytes: zeros, length: 6 * 4, options: .storageModeShared),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }
        let k = min(1, (Double(Self.maxStatSamples) / Double(input.width * input.height)).squareRoot())
        let sw = max(1, Int(Double(input.width) * k)), sh = max(1, Int(Double(input.height) * k))
        var p = WBParams(sampleSize: [UInt32(sw), UInt32(sh)],
                         legalRange: settings.legalRange ? 1 : 0,
                         neutralChroma: settings.neutralChroma)
        enc.setComputePipelineState(statsPipeline)
        enc.setTexture(input, index: 0)
        enc.setBuffer(acc, offset: 0, index: 0)
        enc.setBytes(&p, length: MemoryLayout<WBParams>.stride, index: 1)
        enc.dispatchThreads(MTLSize(width: sw, height: sh, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        return acc
    }

    private static func decodeStats(_ buffer: MTLBuffer) -> WhiteBalanceStats {
        let ptr = buffer.contents().bindMemory(to: Int32.self, capacity: 6)
        return WhiteBalanceStats(accumulators: Array(UnsafeBufferPointer(start: ptr, count: 6)))
    }

    /// Renders `input` at its native size; returns BGRA8 bytes (and WB stats in Tint/Neutrals mode).
    func renderOffscreen(_ input: MTLTexture) throws -> (bytes: [UInt8], stats: WhiteBalanceStats?) {
        let target = try gpu.makeRenderTarget(width: input.width, height: input.height)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let cmd = gpu.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { throw RendererError.setup("encoder") }
        encode(enc, input: input, targetSize: CGSize(width: input.width, height: input.height), fit: false)
        enc.endEncoding()
        let stats = encodeStats(into: cmd, input: input)
        cmd.commit()
        cmd.waitUntilCompleted()
        return (try gpu.readback(target), stats.map(Self.decodeStats))
    }

    private static func makeLUTTexture(device: MTLDevice, preset: FalseColorPreset) -> MTLTexture {
        let n = FalseColorPreset.lutSize
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: n, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        let tex = device.makeTexture(descriptor: desc)!
        let data = preset.makeLUT()
        data.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, n, 1), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: n * 4)
        }
        return tex
    }
}
