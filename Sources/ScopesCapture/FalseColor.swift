import Foundation
import simd

/// A data-driven false color scale. Presets are plain JSON so they can be saved/loaded.
struct FalseColorPreset: Codable, Hashable, Identifiable {
    enum Channel: String, Codable, CaseIterable {
        /// Rec.709 Y′, 0–100 %.
        case luma
        /// Chroma magnitude (vectorscope radius), 0–100 % ≈ fully saturated primary.
        case saturation
        /// CIE L* perceptual lightness, 0–100. Perceptually even steps; what photographers' zones use.
        case lightness
        /// Not a scale: flags pixels where any individual R/G/B channel clips. Bands are ignored.
        case rgbClipping

        /// Short axis label for the legend.
        var axisLabel: String {
            switch self {
            case .luma: return "Y′ %"
            case .saturation: return "SAT %"
            case .lightness: return "L*"
            case .rgbClipping: return ""
            }
        }
    }

    struct Band: Codable, Hashable {
        var lower: Float
        var upper: Float
        /// sRGB hex, e.g. "#FF0000".
        var color: String
        /// If set, the band is a gradient from `color` (at `lower`) to `endColor` (at `upper`).
        var endColor: String?
        var label: String
    }

    var name: String
    var channel: Channel = .luma
    var bands: [Band]
    /// Free-form provenance note (e.g. where the scale comes from).
    var note: String?

    var id: String { name }

    static let lutSize = 1024

    /// RGBA8 lookup table indexed by the channel value (0…1 → 0…lutSize-1).
    /// Alpha is 255 where a band applies, 0 where the pixel passes through (grayscale or original).
    func makeLUT() -> [UInt8] {
        let n = Self.lutSize
        var data = [UInt8](repeating: 0, count: n * 4)
        let parsed = bands.map { band in
            (band, Self.rgb(hex: band.color), band.endColor.map(Self.rgb(hex:)))
        }
        for i in 0..<n {
            let pct = Float(i) / Float(n - 1) * 100
            // The last band reaching 100 includes 100 itself.
            guard let (band, c0, c1) = parsed.first(where: {
                pct >= $0.0.lower && (pct < $0.0.upper || ($0.0.upper >= 100 && pct <= 100))
            }) else { continue }
            var c = c0
            if let c1, band.upper > band.lower {
                c = simd_mix(c0, c1, SIMD3(repeating: (pct - band.lower) / (band.upper - band.lower)))
            }
            c = simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1)) * 255
            data[i * 4 + 0] = UInt8(c.x.rounded())
            data[i * 4 + 1] = UInt8(c.y.rounded())
            data[i * 4 + 2] = UInt8(c.z.rounded())
            data[i * 4 + 3] = 255
        }
        return data
    }

    static func rgb(hex: String) -> SIMD3<Float> {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return [1, 0, 1] }
        return [Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255]
    }
}

// MARK: - Built-in presets

extension FalseColorPreset {
    static let builtIn: [FalseColorPreset] = exposure + retouching
    static let exposure: [FalseColorPreset] = [arri, redVideo, greyscale5, greyscale10, heatmap]
    static let retouching: [FalseColorPreset] = [solarCurve, contourLines, zoneSystem, printClipping, channelClipping]

    /// ARRI ALEXA false color on the Rec.709 monitor output. Image is grayscale outside the zones.
    static let arri = FalseColorPreset(name: "ARRI", bands: [
        .init(lower: 0,   upper: 2.5, color: "#AE00DD", label: "Black clip (noise floor)"),
        .init(lower: 2.5, upper: 4,   color: "#0000DD", label: "Just above black clip"),
        .init(lower: 38,  upper: 42,  color: "#00DF00", label: "18% middle gray"),
        .init(lower: 52,  upper: 56,  color: "#FF80C0", label: "One stop over gray / skin"),
        .init(lower: 97,  upper: 99,  color: "#DDDD00", label: "Just below white clip"),
        .init(lower: 99,  upper: 100, color: "#E40000", label: "White clip"),
    ], note: "ARRI ALEXA/AMIRA false color, Rec.709 video %. Source: ARRI dynamic range white paper; SmallHD's ARRI table.")

    /// RED "False Color: Video" mode (identical across EPIC/SCARLET, DSMC2, KOMODO, V-RAPTOR guides).
    /// RED's integer IRE ranges are inclusive, so 41–48 is stored as 41..<49.
    static let redVideo = FalseColorPreset(name: "RED Video", bands: [
        .init(lower: 0,  upper: 5,   color: "#4A0E4C", label: "Purple: crushed black"),
        .init(lower: 5,  upper: 6,   color: "#0F3B68", label: "Blue: verge of untextured black"),
        .init(lower: 10, upper: 13,  color: "#0C8784", label: "Teal: deep shadows"),
        .init(lower: 41, upper: 49,  color: "#10C20F", label: "Green: 18% gray"),
        .init(lower: 61, upper: 71,  color: "#FF8787", label: "Pink: skin"),
        .init(lower: 92, upper: 94,  color: "#CACA10", label: "Straw: strong highlight"),
        .init(lower: 94, upper: 96,  color: "#FDFF0E", label: "Yellow: strong highlight"),
        .init(lower: 96, upper: 99,  color: "#FD7814", label: "Orange: near white"),
        .init(lower: 99, upper: 100, color: "#FF0000", label: "Red: clipping"),
    ], note: "RED False Color Video mode. Source: docs.red.com monitor tools.")

    static let greyscale5 = steppedGreyscale(bands: 5)
    static let greyscale10 = steppedGreyscale(bands: 10)

    /// Posterizes luma into equal-width steps, each shown at its mid-point gray.
    static func steppedGreyscale(bands n: Int) -> FalseColorPreset {
        let width = 100 / Float(n)
        let bands = (0..<n).map { i -> Band in
            let lo = Float(i) * width, hi = lo + width
            let v = UInt8(((lo + hi) / 2 / 100 * 255).rounded())
            return Band(lower: lo, upper: hi, color: String(format: "#%02X%02X%02X", v, v, v),
                        label: "\(Int(lo))–\(Int(hi))%")
        }
        return FalseColorPreset(name: "\(n)-Band Greyscale", bands: bands,
                                note: "Luma posterized into \(n) equal steps.")
    }

    /// Continuous thermal-style gradient over the full range.
    static let heatmap: FalseColorPreset = {
        let stops: [(Float, String)] = [
            (0, "#0B0420"), (8, "#3A0CA3"), (22, "#1F6FFF"), (38, "#00C2C2"), (50, "#22C55E"),
            (62, "#D4E21A"), (75, "#FFC300"), (88, "#FF5A00"), (97, "#FF0000"), (100, "#FFFFFF"),
        ]
        let bands = zip(stops, stops.dropFirst()).map { a, b in
            Band(lower: a.0, upper: b.0, color: a.1, endColor: b.1, label: "\(Int(a.0))–\(Int(b.0))%")
        }
        return FalseColorPreset(name: "Heatmap", bands: bands, note: "Continuous gradient, dark violet (0%) to white (100%).")
    }()

    // MARK: Retouching

    /// Photoshop-style "solar curve" helper: lightness zig-zags black↔white five times, so subtle
    /// tonal changes become hard edges and reveal blotches, banding, dust and dodge/burn halos.
    static let solarCurve: FalseColorPreset = {
        let segments = 10
        let bands = (0..<segments).map { i -> Band in
            let lo = Float(i) * 10
            let up = i % 2 == 0
            return Band(lower: lo, upper: lo + 10, color: up ? "#000000" : "#FFFFFF",
                        endColor: up ? "#FFFFFF" : "#000000", label: "\(Int(lo))–\(Int(lo) + 10) L*")
        }
        return FalseColorPreset(name: "Solar Curve", channel: .lightness, bands: bands,
                                note: "Five black→white cycles over L*. Smooth skin shows smooth, evenly spaced bands.")
    }()

    /// Iso-lightness lines over the grayscale image, like a topographic map, for dodge & burn.
    /// Minor lines every 2.5 L*, major (magenta) every 10 L*.
    static let contourLines: FalseColorPreset = {
        var bands: [Band] = []
        var v: Float = 2.5
        while v < 100 {
            let major = v.truncatingRemainder(dividingBy: 10) == 0
            bands.append(Band(lower: v - 0.3, upper: v + 0.3, color: major ? "#FF2BD6" : "#00E5FF",
                              label: "L* \(String(format: "%g", v))"))
            v += 2.5
        }
        return FalseColorPreset(name: "Contour Lines", channel: .lightness, bands: bands,
                                note: "Iso-lightness contours every 2.5 L* (major every 10). Lumps and dips break the pattern.")
    }()

    /// Ansel Adams' 11 zones on the digital L* scale (≈10 L* per zone, Zone V = middle grey = L* 50).
    static let zoneSystem: FalseColorPreset = {
        let roman = ["0", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
        let colors = ["#14002E", "#3B0F70", "#2C3E9E", "#1F78B4", "#21A6A6", "#2DBE4E",
                      "#B5D334", "#F2D51E", "#F59D1E", "#E8541E", "#FFFFFF"]
        let meaning = ["pure black", "near black", "first texture in shadow", "dark detail", "dark midtone",
                       "middle grey", "light midtone / skin", "light skin, bright detail", "last texture in highlight",
                       "near white", "paper white"]
        let bands = (0...10).map { n -> Band in
            Band(lower: max(0, Float(n) * 10 - 5), upper: min(100, Float(n) * 10 + 5), color: colors[n],
                 label: "Zone \(roman[n]): \(meaning[n])")
        }
        return FalseColorPreset(name: "Zone System", channel: .lightness, bands: bands,
                                note: "Zone n spans L* 10n ± 5.")
    }()

    /// Tones that will block up or blow out on paper.
    static let printClipping = FalseColorPreset(name: "Print Clipping", channel: .lightness, bands: [
        .init(lower: 0,  upper: 4,   color: "#1530FF", label: "Blocked shadow (no detail in print)"),
        .init(lower: 4,  upper: 8,   color: "#4FB3FF", label: "Shadow at risk"),
        .init(lower: 92, upper: 96,  color: "#FFD21A", label: "Highlight at risk"),
        .init(lower: 96, upper: 100, color: "#FF1E1E", label: "Blown highlight (paper white)"),
    ], note: "Approximate printable tonal range on L*; tighten for matte/uncoated stock.")

    /// Shader special case (see `Channel.rgbClipping`).
    static let channelClipping = FalseColorPreset(name: "Channel Clipping", channel: .rgbClipping, bands: [],
                                                  note: "Any single R/G/B channel at 0 or 255.")
}
