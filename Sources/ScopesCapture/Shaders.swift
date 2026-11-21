/// Twin Peaks plot geometry, shared by the shader and the SwiftUI label overlay.
/// Plot space: x = B−G (upper) / R−G (lower), y = B+G (upper) / −(R+G) (lower).
/// Each diamond is the RGB unit square rotated 45°: x ∈ [−1, 1], |y| ∈ [0, 2].
enum TwinPeaksGeometry {
    static let xMax: Float = 1.2
    static let yMax: Float = 2.15

    /// Plot-space point → normalized view coordinates (0…1, origin top-left).
    static func uv(x: Float, y: Float) -> (u: Float, v: Float) {
        ((x + xMax) / (2 * xMax), (yMax - y) / (2 * yMax))
    }
}

/// Metal shader source, compiled at runtime so the project builds with SwiftPM alone
/// (no Xcode `metal` toolchain step needed).
let scopeShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 position [[position]];
    float2 uv;
};

static VOut quadVertex(uint vid, float2 scale) {
    const float2 pos[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    const float2 uv[4]  = { float2(0, 1),   float2(1, 1),  float2(0, 0),  float2(1, 0) };
    VOut o;
    o.position = float4(pos[vid] * scale, 0, 1);
    o.uv = uv[vid];
    return o;
}

static float luma709(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// Rec.709 color difference, scaled so ±0.5 is the full range.
static float2 cbcr709(float3 c, float y) { return float2((c.b - y) / 1.8556, (c.r - y) / 1.5748); }

static float3 toLegal(float3 c) { return (c - 16.0 / 255.0) / (219.0 / 255.0); }

// =====================================================================
// Image scopes: false color, skintone, tint, neutrals
// =====================================================================

struct ImageUniforms {
    float2 scale;         // aspect-fit scale in NDC
    float  opacity;       // 0 = original, 1 = full overlay
    uint   legalRange;    // 1 = treat input as 16-235
    uint   colorInGaps;   // false color: show original color where no band applies
    uint   mode;          // 0 = false color, 1 = skintone, 2 = tint, 3 = neutrals
    uint   channel;       // false color input: 0 = luma, 1 = saturation, 2 = L*, 3 = per-channel clipping
    uint   skinMode;      // 0 = YCbCr, 1 = HSL
    float  skinCenter;    // degrees
    float  skinTolerance; // degrees
    float  skinMinSat;    // 0-1
    uint   dimOthers;     // skintone: darken non-skin pixels
    float  wbRange;       // tint/neutrals: a*/b* distance that shows as full color
    float  neutralChroma; // max Lab chroma (C*) counted as neutral
    uint   tintNeutralsOnly; // tint: only colorize near-neutral pixels
    float2 offset;        // pan in NDC (zoom is folded into scale)
};

vertex VOut imageVertex(uint vid [[vertex_id]], constant ImageUniforms &u [[buffer(0)]]) {
    VOut o = quadVertex(vid, u.scale);
    o.position.xy += u.offset;
    return o;
}

// CIE L*a*b* (D65) from gamma-encoded sRGB. a*: green(-) / magenta(+), b*: blue(-) / yellow(+).
static float3 srgbToLab(float3 c) {
    c = saturate(c);
    float3 lin = select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    float3 xyz = float3(dot(lin, float3(0.4124564, 0.3575761, 0.1804375)),
                        dot(lin, float3(0.2126729, 0.7151522, 0.0721750)),
                        dot(lin, float3(0.0193339, 0.1191920, 0.9503041)));
    xyz /= float3(0.95047, 1.0, 1.08883);
    float3 f = select(7.787 * xyz + 16.0 / 116.0, pow(xyz, 1.0 / 3.0), xyz > 0.008856);
    return float3(116.0 * f.y - 16.0, 500.0 * (f.x - f.y), 200.0 * (f.y - f.z));
}

// Pixels near black or white are neutral by construction, so they're left out of WB analysis.
static bool wbUsable(float L) { return L > 5.0 && L < 97.0; }

// Diverging overlay: grayscale where v≈0, blending to negColor / posColor as |v| -> range.
// The color keeps some of the pixel's lightness so image structure stays readable.
static float3 divergingOverlay(float v, float range, float yc, float3 negColor, float3 posColor) {
    float d = clamp(v / max(range, 0.1), -1.0, 1.0);
    float3 hue = d < 0.0 ? negColor : posColor;
    float3 tinted = saturate(hue * (0.35 + 0.85 * yc));
    return mix(float3(yc), tinted, smoothstep(0.0, 1.0, abs(d)));
}

constant float3 WB_GREEN   = float3(0.10, 0.95, 0.25);
constant float3 WB_MAGENTA = float3(1.00, 0.15, 0.85);
constant float3 WB_BLUE    = float3(0.15, 0.45, 1.00);
constant float3 WB_YELLOW  = float3(1.00, 0.85, 0.00);

static float wrapDegrees(float a) { return a - 360.0 * floor((a + 180.0) / 360.0); } // -> [-180, 180)

static float hslHue(float3 c, thread float &sat) {
    float mx = max3(c.r, c.g, c.b);
    float mn = min3(c.r, c.g, c.b);
    float d = mx - mn;
    if (d < 1e-5) { sat = 0; return 0; }
    float l = (mx + mn) * 0.5;
    sat = saturate(d / (1.0 - abs(2.0 * l - 1.0)));
    float h;
    if (mx == c.r)      h = fmod((c.g - c.b) / d + 6.0, 6.0);
    else if (mx == c.g) h = (c.b - c.r) / d + 2.0;
    else                h = (c.r - c.g) / d + 4.0;
    return h * 60.0;
}

// Green on the skin line -> yellow -> red at the tolerance edge.
static float3 skinHeat(float d) {
    const float3 green  = float3(0.15, 0.95, 0.15);
    const float3 yellow = float3(1.0, 0.92, 0.0);
    const float3 red    = float3(1.0, 0.12, 0.0);
    return d < 0.5 ? mix(green, yellow, d * 2.0) : mix(yellow, red, (d - 0.5) * 2.0);
}

fragment float4 imageFragment(VOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> lut [[texture(1)]],
                              constant ImageUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // Zoomed past 1:1, show crisp source pixels instead of interpolating between them.
    float2 texSize = float2(src.get_width(), src.get_height());
    float2 px = in.uv * texSize;
    float3 rgb = fwidth(px.x) < 0.5
        ? src.read(uint2(clamp(px, float2(0.0), texSize - 1.0))).rgb
        : src.sample(s, in.uv).rgb;
    float3 sig = u.legalRange != 0 ? toLegal(rgb) : rgb;

    // Rec.709 luma on the gamma-encoded signal (Y', as broadcast scopes measure it).
    float y = luma709(sig);
    float yc = saturate(y);

    if (u.mode == 0) {
        if (u.channel == 3) {
            // Per-channel clipping: highlights show the clipped channels' color (all three = white),
            // shadows show the complement (all three = blue). Everything else is dimmed grayscale.
            float3 hi = step(0.995, sig);
            float3 lo = step(sig, 0.005);
            float3 out = float3(yc * 0.35);
            if (any(lo > 0.5)) out = all(lo > 0.5) ? float3(0.15, 0.35, 1.0) : 1.0 - lo;
            if (any(hi > 0.5)) out = hi;
            return float4(mix(rgb, out, u.opacity), 1.0);
        }
        float value = yc;
        if (u.channel == 1) {
            value = saturate(length(cbcr709(sig, y)) * 2.0);
        } else if (u.channel == 2) {
            value = saturate(srgbToLab(sig).x / 100.0);
        }
        uint width = lut.get_width();
        uint idx = min(uint(value * float(width - 1) + 0.5), width - 1);
        float4 band = lut.read(uint2(idx, 0));
        float3 gap = (u.colorInGaps != 0) ? rgb : float3(yc);
        float3 fc = band.a > 0.5 ? band.rgb : gap;
        return float4(mix(rgb, fc, u.opacity), 1.0);
    }

    if (u.mode == 2 || u.mode == 3) {
        float3 lab = srgbToLab(sig);
        float chroma = length(lab.yz);
        bool neutral = wbUsable(lab.x) && chroma < u.neutralChroma;
        float3 out;
        if (u.mode == 2) {
            // Tint: green <-> magenta (a*).
            bool show = u.tintNeutralsOnly == 0 || neutral;
            out = show ? divergingOverlay(lab.y, u.wbRange, yc, WB_GREEN, WB_MAGENTA) : float3(yc * 0.25);
        } else {
            // Neutrals: near-neutral pixels colored by yellow <-> blue (b*); the rest dimmed.
            out = neutral ? divergingOverlay(lab.z, u.wbRange, yc, WB_BLUE, WB_YELLOW) : float3(yc * 0.25);
        }
        return float4(mix(rgb, out, u.opacity), 1.0);
    }

    // Skintone: distance of the pixel's hue from the skin line.
    float angle, sat;
    if (u.skinMode == 0) {
        float2 cc = cbcr709(sig, y);
        angle = atan2(cc.y, cc.x) * 57.2957795;
        sat = saturate(length(cc) * 2.0);
    } else {
        angle = hslHue(saturate(sig), sat);
    }
    float dev = abs(wrapDegrees(angle - u.skinCenter));
    bool hit = sat >= u.skinMinSat && yc > 0.04 && yc < 0.97 && dev <= u.skinTolerance;
    if (hit) {
        return float4(mix(rgb, skinHeat(dev / u.skinTolerance), u.opacity), 1.0);
    }
    return float4(u.dimOthers != 0 ? float3(yc * 0.3) : rgb, 1.0);
}

// White balance statistics: mean a*/b* over all usable pixels and over near-neutrals.
// Accumulated with a SIMD-group reduction, then one atomic per SIMD group (fixed point x16).
struct WBParams {
    uint2 sampleSize;
    uint  legalRange;
    float neutralChroma;
};

kernel void wbStats(texture2d<float> src [[texture(0)]],
                    device atomic_int *acc [[buffer(0)]],
                    constant WBParams &p [[buffer(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
    float all = 0, aAll = 0, bAll = 0, neu = 0, aNeu = 0, bNeu = 0;
    if (gid.x < p.sampleSize.x && gid.y < p.sampleSize.y) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        float3 c = src.sample(s, (float2(gid) + 0.5) / float2(p.sampleSize), level(0)).rgb;
        if (p.legalRange != 0) c = toLegal(c);
        float3 lab = srgbToLab(c);
        if (wbUsable(lab.x)) {
            all = 1; aAll = lab.y; bAll = lab.z;
            if (length(lab.yz) < p.neutralChroma) { neu = 1; aNeu = lab.y; bNeu = lab.z; }
        }
    }
    all = simd_sum(all); aAll = simd_sum(aAll); bAll = simd_sum(bAll);
    neu = simd_sum(neu); aNeu = simd_sum(aNeu); bNeu = simd_sum(bNeu);
    if (simd_is_first()) {
        atomic_fetch_add_explicit(&acc[0], int(all), memory_order_relaxed);
        atomic_fetch_add_explicit(&acc[1], int(round(aAll * 16.0)), memory_order_relaxed);
        atomic_fetch_add_explicit(&acc[2], int(round(bAll * 16.0)), memory_order_relaxed);
        atomic_fetch_add_explicit(&acc[3], int(neu), memory_order_relaxed);
        atomic_fetch_add_explicit(&acc[4], int(round(aNeu * 16.0)), memory_order_relaxed);
        atomic_fetch_add_explicit(&acc[5], int(round(bNeu * 16.0)), memory_order_relaxed);
    }
}

"""
