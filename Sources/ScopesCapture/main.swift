import AppKit
import CoreVideo
import Foundation
import ImageIO
import Metal
import SwiftUI
import simd
import UniformTypeIdentifiers

struct ScopesCaptureApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("False Color") {
            ContentView()
                .environment(model)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts  (?)") { model.showShortcuts.toggle() }
            }
        }
    }
}

// Headless mode for testing the GPU path without a window or capture permission:
//   ScopesCapture --render <input.png|ramp|huesweep> <output.png> [mode]
// mode: a false color preset name (e.g. ARRI, Saturation), skin-ycbcr, skin-hsl, or twinpeaks.
let args = CommandLine.arguments
if args.count >= 2, args[1] == "--bench" {
    do {
        try Headless.bench()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
} else if args.count >= 4, args[1] == "--render" {
    do {
        try Headless.render(input: args[2], output: args[3], mode: args.count > 4 ? args[4] : "ARRI")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
} else {
    NSApplication.shared.setActivationPolicy(.regular)
    ScopesCaptureApp.main()
}

enum Headless {
    static func render(input: String, output: String, mode: String) throws {
        let gpu = try GPUContext()
        let frames = FrameSource(gpu: gpu)
        switch input {
        case "ramp": frames.setTexture(try makeTexture(gpu.device, width: 1024, height: 128) { x, _ in SIMD3(repeating: x) })
        case "wbchart": frames.setTexture(try makeTexture(gpu.device, width: 900, height: 600, pixel: wbChart))
        case "huesweep": frames.setTexture(try makeTexture(gpu.device, width: 1024, height: 512, pixel: hueSweep))
        case "bars": frames.setTexture(try makeTexture(gpu.device, width: 1400, height: 600, pixel: colorBars))
        case "l10r-bars":
            // Exercises the 10-bit capture path: an IOSurface-backed 'l10r' pixel buffer.
            frames.setPixelBuffer(try makeL10RBuffer(width: 1400, height: 600, pixel: colorBars))
        default: frames.setTexture(try gpu.loadImageTexture(url: URL(fileURLWithPath: input)))
        }
        guard let texture = frames.current?.texture else { throw RendererError.setup("input") }

        let bytes: [UInt8], w: Int, h: Int
        // Measurement modes take an optional zoom suffix, e.g. "vector-yuv@2".
        let parts = mode.split(separator: "@", maxSplits: 1).map(String.init)
        if let (kind, scopeMode) = measurementModes[parts[0]] {
            let pipelines = try ScopePipelines(gpu: gpu)
            var config = ScopePaneConfig(kind: kind, mode: scopeMode)
            if parts.count > 1, let zoom = Float(parts[1]) { config.zoom = zoom }
            let renderer = ScopeRenderer(gpu: gpu, source: frames, analysis: AnalysisPass(gpu: gpu, pipelines: pipelines),
                                         pipelines: pipelines, config: config)
            (w, h) = kind == .vectorscope ? (600, 600) : kind == .twinPeaks ? (640, 800) : (900, 500)
            bytes = try renderer.renderOffscreen(width: w, height: h)
        } else {
            let scope = try ImageScopeRenderer(gpu: gpu, source: frames)
            var settings = ScopeSettings()
            switch mode {
            case "skin-ycbcr": settings.imageMode = .skintone; settings.skintoneMode = .ycbcr
            case "skin-hsl": settings.imageMode = .skintone; settings.skintoneMode = .hsl
            case "tint": settings.imageMode = .tint
            case "neutrals": settings.imageMode = .neutrals
            default:
                guard let preset = FalseColorPreset.builtIn.first(where: { $0.name.caseInsensitiveCompare(mode) == .orderedSame }) else {
                    throw NSError(domain: "ScopesCapture", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "Unknown mode \(mode). Presets: \(FalseColorPreset.builtIn.map(\.name).joined(separator: ", "))"])
                }
                settings.preset = preset
            }
            scope.settings = settings
            (w, h) = (texture.width, texture.height)
            let result = try scope.renderOffscreen(texture)
            bytes = result.bytes
            if let st = result.stats {
                print(String(format: "all pixels: a* %+.2f  b* %+.2f | neutrals (%.1f%%): a* %+.2f  b* %+.2f | samples %d",
                             st.meanA, st.meanB, st.neutralFraction * 100, st.neutralMeanA, st.neutralMeanB, st.sampleCount))
            }
        }
        try writePNG(bgra: bytes, width: w, height: h, to: URL(fileURLWithPath: output))
    }

    static let measurementModes: [String: (ScopeKind, Int)] = [
        "waveform-luma": (.waveform, 0), "waveform-rgb": (.waveform, 1),
        "parade-rgb": (.waveform, 2), "parade-yrgb": (.waveform, 3),
        "vector-yuv": (.vectorscope, 0), "vector-hsl": (.vectorscope, 1),
        "satlum": (.satLum, 0), "satlum-hsl": (.satLum, 1),
        "hist-rgb": (.histogram, 0), "hist-luma": (.histogram, 1),
        "hist-sat": (.histogram, 2), "hist-hue": (.histogram, 3),
        "twinpeaks": (.twinPeaks, 0),
    ]

    /// GPU time per frame for every scope on a 4K source (analysis included).
    static func bench() throws {
        let gpu = try GPUContext()
        let frames = FrameSource(gpu: gpu)
        frames.setTexture(try makeTexture(gpu.device, width: 3840, height: 2160, pixel: hueSweep))
        let pipelines = try ScopePipelines(gpu: gpu)
        let analysis = AnalysisPass(gpu: gpu, pipelines: pipelines)
        var total = 0.0
        for (name, (kind, mode)) in measurementModes.sorted(by: { $0.key < $1.key }) {
            let r = ScopeRenderer(gpu: gpu, source: frames, analysis: analysis, pipelines: pipelines,
                                  config: ScopePaneConfig(kind: kind, mode: mode))
            _ = try r.gpuTime(width: 900, height: 500, freshAnalysis: true) // warm up
            var times: [Double] = []
            for _ in 0..<40 { times.append(try r.gpuTime(width: 900, height: 500, freshAnalysis: true)) }
            let median = times.sorted()[times.count / 2]
            total += median
            print(name.padding(toLength: 15, withPad: " ", startingAt: 0)
                  + String(format: "%6.2f ms", median * 1000))
        }
        print(String(format: "sum of all %d scope modes: %.2f ms (each includes its own analysis pass)",
                     measurementModes.count, total * 1000))
    }

    /// 75% bars across the top half, 100% bars across the bottom: white, yellow, cyan,
    /// green, magenta, red, blue.
    private static func colorBars(_ x: Double, _ y: Double) -> SIMD3<Double> {
        let bars: [SIMD3<Double>] = [[1, 1, 1], [1, 1, 0], [0, 1, 1], [0, 1, 0], [1, 0, 1], [1, 0, 0], [0, 0, 1]]
        return bars[min(Int(x * 7), 6)] * (y < 0.5 ? 0.75 : 1.0)
    }

    /// IOSurface-backed 10-bit 'l10r' (ARGB2101010 little-endian) pixel buffer.
    private static func makeL10RBuffer(width: Int, height: Int, pixel: (Double, Double) -> SIMD3<Double>) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                    kCVPixelBufferMetalCompatibilityKey as String: true]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_ARGB2101010LEPacked, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { throw RendererError.setup("l10r buffer") }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!
        let stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            let row = (base + y * stride).bindMemory(to: UInt32.self, capacity: width)
            for x in 0..<width {
                let c = pixel(Double(x) / Double(width - 1), Double(y) / Double(height - 1))
                let r = UInt32((c.x * 1023).rounded()), g = UInt32((c.y * 1023).rounded()), b = UInt32((c.z * 1023).rounded())
                row[x] = (3 << 30) | (r << 20) | (g << 10) | b
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// Gray patches with a temperature cast across x (blue → yellow) and a tint cast down y
    /// (green → magenta); the bottom strip is saturated color that should never count as neutral.
    private static func wbChart(_ x: Double, _ y: Double) -> SIMD3<Double> {
        if y > 0.85 { return hueSweep(x, 0.1) }
        let col = Double(min(Int(x * 9), 8)) - 4     // -4…4: blue … yellow
        let row = Double(min(Int(y / 0.85 * 5), 4)) - 2 // -2…2: green … magenta
        let gray = 0.5
        let temp = SIMD3<Double>(0.012, 0.004, -0.016) * col
        let tint = SIMD3<Double>(0.012, -0.016, 0.012) * row
        return simd_clamp(SIMD3(repeating: gray) + temp + tint, .zero, .one)
    }

    /// Hue across x (0–360°), saturation down y (1 → 0), value fixed at 0.85.
    private static func hueSweep(_ x: Double, _ y: Double) -> SIMD3<Double> {
        let h = x * 6, s = 1 - y, v = 0.85
        let c = v * s, xx = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let rgb: SIMD3<Double>
        switch Int(h) % 6 {
        case 0: rgb = [c, xx, 0]
        case 1: rgb = [xx, c, 0]
        case 2: rgb = [0, c, xx]
        case 3: rgb = [0, xx, c]
        case 4: rgb = [xx, 0, c]
        default: rgb = [c, 0, xx]
        }
        return rgb + m
    }

    /// Builds a BGRA test texture from a function of normalized (x, y) → RGB.
    private static func makeTexture(_ device: MTLDevice, width: Int, height: Int,
                                    pixel: (Double, Double) -> SIMD3<Double>) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { throw RendererError.setup("test texture") }
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = pixel(Double(x) / Double(width - 1), Double(y) / Double(height - 1))
                let i = (y * width + x) * 4
                data[i] = UInt8((c.z * 255).rounded())
                data[i + 1] = UInt8((c.y * 255).rounded())
                data[i + 2] = UInt8((c.x * 255).rounded())
            }
        }
        data.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        return tex
    }

    private static func writePNG(bgra: [UInt8], width: Int, height: Int, to url: URL) throws {
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: info, provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw RendererError.setup("PNG writer") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RendererError.setup("PNG write") }
    }
}
