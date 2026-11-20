import Foundation
import Metal
import MetalKit

/// Twin Peaks (diamond) scope. A compute pass scatters every sampled pixel into a
/// histogram with one bin per output pixel; a render pass tone-maps it and draws the
/// gamut diamonds.
final class TwinPeaksRenderer: NSObject, MTKViewDelegate {
    /// Must match `TPUniforms` in the shader.
    struct Uniforms {
        var histSize: SIMD2<UInt32>
        var sampleSize: SIMD2<UInt32>
        var legalRange: UInt32
        var reference: Float
    }

    /// Cap on source samples per frame (≈ 1080p); larger sources are point-sampled on a grid.
    static let maxSamples = 1920 * 1080

    private let gpu: GPUContext
    private let source: FrameSource
    private let accumulate: MTLComputePipelineState
    private let display: MTLRenderPipelineState
    private var histogram: MTLBuffer?

    weak var view: MTKView?

    var legalRange = false {
        didSet { if legalRange != oldValue { view?.needsDisplay = true } }
    }

    init(gpu: GPUContext, source: FrameSource) throws {
        self.gpu = gpu
        self.source = source
        accumulate = try gpu.device.makeComputePipelineState(function: gpu.function("tpAccumulate"))
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = try gpu.function("tpVertex")
        desc.fragmentFunction = try gpu.function("tpFragment")
        desc.colorAttachments[0].pixelFormat = scopePixelFormat
        display = try gpu.device.makeRenderPipelineState(descriptor: desc)
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
        guard encode(into: cmd, pass: pass, input: frame?.texture, width: w, height: h) else { return }
        cmd.addCompletedHandler { _ in withExtendedLifetime(frame) {} }
        cmd.present(drawable)
        cmd.commit()
    }

    @discardableResult
    private func encode(into cmd: MTLCommandBuffer, pass: MTLRenderPassDescriptor,
                        input: MTLTexture?, width w: Int, height h: Int) -> Bool {
        let length = w * h * MemoryLayout<UInt32>.stride
        if histogram == nil || histogram!.length < length {
            histogram = gpu.device.makeBuffer(length: length, options: .storageModePrivate)
        }
        guard let hist = histogram else { return false }

        var u = Uniforms(histSize: [UInt32(w), UInt32(h)], sampleSize: [0, 0],
                         legalRange: legalRange ? 1 : 0, reference: 1)

        guard let blit = cmd.makeBlitCommandEncoder() else { return false }
        blit.fill(buffer: hist, range: 0..<length, value: 0)
        blit.endEncoding()

        if let input {
            let pixels = Double(input.width * input.height)
            let k = min(1, (Double(Self.maxSamples) / pixels).squareRoot())
            let sw = max(1, Int(Double(input.width) * k)), sh = max(1, Int(Double(input.height) * k))
            u.sampleSize = [UInt32(sw), UInt32(sh)]
            // Brightness reference: a bin this full reads as white (log scale).
            u.reference = max(8, Float(sw * sh) * 2 / Float(w * h) * 48)

            guard let enc = cmd.makeComputeCommandEncoder() else { return false }
            enc.setComputePipelineState(accumulate)
            enc.setTexture(input, index: 0)
            enc.setBuffer(hist, offset: 0, index: 0)
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.dispatchThreads(MTLSize(width: sw, height: sh, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.endEncoding()
        }

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return false }
        enc.setRenderPipelineState(display)
        enc.setFragmentBuffer(hist, offset: 0, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        return true
    }

    /// Renders the scope for `input` into a `width`×`height` image; returns BGRA8 bytes.
    func renderOffscreen(_ input: MTLTexture, width: Int, height: Int) throws -> [UInt8] {
        let target = try gpu.makeRenderTarget(width: width, height: height)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let cmd = gpu.queue.makeCommandBuffer(),
              encode(into: cmd, pass: pass, input: input, width: width, height: height) else {
            throw RendererError.setup("twin peaks encode")
        }
        cmd.commit()
        return try gpu.readback(target)
    }
}
