import AppKit
import CoreVideo
import Foundation
import Metal
import MetalKit

/// Shared Metal objects: one device, queue and compiled shader library for every scope.
final class GPUContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let textureCache: CVMetalTextureCache

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw RendererError.noDevice }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.setup("command queue") }
        self.queue = queue
        library = try device.makeLibrary(source: scopeShaderSource + measurementShaderSource, options: nil)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache else { throw RendererError.setup("texture cache") }
        textureCache = cache
    }

    func function(_ name: String) throws -> MTLFunction {
        guard let f = library.makeFunction(name: name) else { throw RendererError.setup("shader \(name)") }
        return f
    }

    /// Loads an image file as a non-sRGB texture so shaders see the encoded values.
    func loadImageTexture(url: URL) throws -> MTLTexture {
        let loader = MTKTextureLoader(device: device)
        return try loader.newTexture(URL: url, options: [
            .SRGB: false,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .origin: MTKTextureLoader.Origin.topLeft,
        ])
    }

    /// Creates a private BGRA render target for headless rendering.
    func makeRenderTarget(width: Int, height: Int) throws -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: scopePixelFormat, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget]
        td.storageMode = .private
        guard let tex = device.makeTexture(descriptor: td) else { throw RendererError.setup("render target") }
        return tex
    }

    /// Copies a BGRA texture back to the CPU (tightly packed rows). Waits for the GPU.
    func readback(_ texture: MTLTexture) throws -> [UInt8] {
        let w = texture.width, h = texture.height
        guard let buffer = device.makeBuffer(length: w * h * 4, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { throw RendererError.setup("readback") }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let err = cmd.error { throw err }
        let ptr = buffer.contents().bindMemory(to: UInt8.self, capacity: w * h * 4)
        return Array(UnsafeBufferPointer(start: ptr, count: w * h * 4))
    }
}

let scopePixelFormat: MTLPixelFormat = .bgra8Unorm

/// Latest input frame, shared by all scopes. Frames arrive on any thread; every attached
/// MTKView is asked to redraw when a new one lands.
final class FrameSource {
    /// Keeps the CoreVideo objects alive for as long as the GPU may read the texture.
    struct Frame {
        /// Increments with every new frame; lets per-frame GPU work be shared between scopes.
        let id: UInt64
        let texture: MTLTexture
        let cvTexture: CVMetalTexture?
        let pixelBuffer: CVPixelBuffer?

        /// One code value of the source's bit depth, used to dither before binning.
        var quantizationStep: Float {
            switch texture.pixelFormat {
            case .bgr10a2Unorm, .rgb10a2Unorm: return 1 / 1023
            case .rgba16Unorm, .rgba16Float, .rgba32Float: return 1 / 65535
            default: return 1 / 255
            }
        }
    }

    private var nextID: UInt64 = 0

    private let gpu: GPUContext
    private let lock = NSLock()
    private var frame: Frame?
    private let views = NSHashTable<MTKView>.weakObjects() // main thread only
    private var lastSize: CGSize?

    /// Called on the main thread when the frame size changes or the source is cleared.
    var onSizeChange: ((CGSize?) -> Void)?

    init(gpu: GPUContext) {
        self.gpu = gpu
    }

    var current: Frame? { lock.withLock { frame } }

    func attach(_ view: MTKView) {
        views.add(view)
    }

    /// Zero-copy wrap of a BGRA IOSurface-backed pixel buffer (e.g. from ScreenCaptureKit).
    func setPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let format: MTLPixelFormat
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_ARGB2101010LEPacked: format = .bgr10a2Unorm // 'l10r', 10-bit capture
        case kCVPixelFormatType_32BGRA: format = .bgra8Unorm
        default: return
        }
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, gpu.textureCache, pixelBuffer, nil, format, w, h, 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return }
        replace(texture: tex, cvTexture: cvTex, pixelBuffer: pixelBuffer)
    }

    func setTexture(_ texture: MTLTexture) {
        replace(texture: texture, cvTexture: nil, pixelBuffer: nil)
    }

    func clear() {
        lock.withLock { frame = nil }
        publish(size: nil)
    }

    private func replace(texture: MTLTexture, cvTexture: CVMetalTexture?, pixelBuffer: CVPixelBuffer?) {
        let new = lock.withLock { () -> Frame in
            nextID &+= 1
            let f = Frame(id: nextID, texture: texture, cvTexture: cvTexture, pixelBuffer: pixelBuffer)
            frame = f
            return f
        }
        publish(size: CGSize(width: new.texture.width, height: new.texture.height))
    }

    private func publish(size: CGSize?) {
        DispatchQueue.main.async { [self] in
            if lastSize != size {
                lastSize = size
                onSizeChange?(size)
            }
            redrawAll()
        }
    }

    /// Main thread.
    func redrawAll() {
        for view in views.allObjects { view.needsDisplay = true }
    }
}

enum RendererError: LocalizedError {
    case noDevice
    case setup(String)

    var errorDescription: String? {
        switch self {
        case .noDevice: return "No Metal device available."
        case .setup(let what): return "Metal setup failed: \(what)."
        }
    }
}
