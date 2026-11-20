import Foundation
import Metal
import MetalKit

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
    }

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

    private func encode(_ enc: MTLRenderCommandEncoder, input: MTLTexture, targetSize: CGSize, fit: Bool) {
        var scale = SIMD2<Float>(1, 1)
        if fit, targetSize.width > 0, targetSize.height > 0 {
            let viewAspect = Float(targetSize.width / targetSize.height)
            let texAspect = Float(input.width) / Float(input.height)
            scale = texAspect > viewAspect ? [1, viewAspect / texAspect] : [texAspect / viewAspect, 1]
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
                         tintNeutralsOnly: s.tintNeutralsOnly ? 1 : 0)
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
