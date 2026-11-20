import Foundation

enum ImageScopeMode: String, CaseIterable, Identifiable {
    case falseColor = "False Color"
    case skintone = "Skintone"
    case tint = "Tint"
    case neutrals = "Neutrals"
    var id: String { rawValue }

    /// Modes that analyze white balance in CIE L*a*b*.
    var isWhiteBalance: Bool { self == .tint || self == .neutrals }
}

enum SkintoneMode: String, CaseIterable, Identifiable {
    case ycbcr = "YCbCr"
    case hsl = "HSL"
    var id: String { rawValue }

    /// Where the skin tone line sits in each color model.
    /// YCbCr: angle of the vectorscope skin (I) line, measured from +Cb toward +Cr.
    /// HSL: hue angle of typical skin.
    var centerDegrees: Float {
        switch self {
        case .ycbcr: return 123
        case .hsl: return 20
        }
    }
}

struct ScopeSettings: Equatable {
    var imageMode: ImageScopeMode = .falseColor

    // False color
    var preset: FalseColorPreset = .arri
    /// Show original color (instead of grayscale) where no band applies.
    var colorInGaps = false

    // Skintone
    var skintoneMode: SkintoneMode = .ycbcr
    /// Max hue deviation (degrees) from the skin line still counted as skin.
    var skinTolerance: Float = 15
    /// Minimum saturation (0–1) for a pixel to count as skin; filters out grays.
    var skinMinSaturation: Float = 0.08
    /// Darken everything that isn't skin.
    var dimNonSkin = false

    // White balance (Tint / Neutrals), in CIE L*a*b* units
    /// a*/b* distance from neutral that shows as full color.
    var wbRange: Float = 8
    /// Max chroma (C*) for a pixel to count as near-neutral.
    var neutralChroma: Float = 12
    /// Tint mode: only colorize near-neutral pixels.
    var tintNeutralsOnly = false

    // Shared
    /// 0 = original image, 1 = full overlay.
    var opacity: Float = 1
    /// Interpret the input as legal/video range (16–235) instead of full range (0–255).
    var legalRange = false
}

/// Mean L*a*b* chroma offsets measured on the GPU (a*: −green / +magenta, b*: −blue / +yellow).
struct WhiteBalanceStats: Equatable {
    var meanA: Float = 0
    var meanB: Float = 0
    var neutralMeanA: Float = 0
    var neutralMeanB: Float = 0
    /// Fraction of usable pixels that are near-neutral.
    var neutralFraction: Float = 0
    var sampleCount = 0

    init() {}

    /// Decodes the six fixed-point accumulators written by the `wbStats` kernel.
    init(accumulators a: [Int32]) {
        let all = Float(a[0]), neutral = Float(a[3])
        sampleCount = Int(a[0])
        if all > 0 {
            meanA = Float(a[1]) / 16 / all
            meanB = Float(a[2]) / 16 / all
            neutralFraction = neutral / all
        }
        if neutral > 0 {
            neutralMeanA = Float(a[4]) / 16 / neutral
            neutralMeanB = Float(a[5]) / 16 / neutral
        }
    }
}
