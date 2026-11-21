import Foundation

/// Geometry shared between the vectorscope shader and its SwiftUI label overlay.
enum VectorscopeGeometry {
    /// Rec.709 (Cb, Cr) of a gamma-encoded RGB colour; 100% saturation sits at radius 0.5.
    static func cbcr(_ r: Double, _ g: Double, _ b: Double) -> (cb: Double, cr: Double) {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return ((b - y) / 1.8556, (r - y) / 1.5748)
    }

    /// HSL mode puts hue 0 (red) at the same angle red has in YUV mode, so both read alike.
    static let hslRedAngleDegrees: Double = {
        let p = cbcr(1, 0, 0)
        return atan2(p.cr, p.cb) * 180 / .pi
    }()

    /// Vectorscope skin (I) line, shared with the Skintone scope.
    static let skinLineDegrees: Double = 123

    /// Plot half-extent in Cb/Cr units for a zoom factor (1× shows a little past 100%).
    static func extent(zoom: Float) -> Float { 0.55 / max(zoom, 0.1) }
}

/// Plot range shared by the Sat/Lum shader and its labels (both axes, 0–1 signal).
enum SatLumGeometry {
    static let lo: Float = -0.02
    static let hi: Float = 1.02
}

/// GPU code for the measurement scopes: a shared per-frame analysis pass, then
/// accumulate (compute, atomics into bins) + display (fragment, tone-mapped bins and
/// graticule) for each of Waveform, Vectorscope, Sat/Lum, Histogram and Twin Peaks.
/// Appended to `scopeShaderSource`, so it can use that file's helpers (luma709, cbcr709,
/// toLegal, hslHue, quadVertex, VOut).
let measurementShaderSource = """

// =====================================================================
// Shared helpers
// =====================================================================

// Cheap per-sample hash -> [0,1)^3, used to dither quantized inputs so plots don't alias
// into stripes where code-value steps and bin size beat against each other.
static float3 hash3(uint2 p) {
    uint3 v = uint3(p.x * 1664525u + 1013904223u, p.y * 22695477u + 1u, (p.x ^ p.y) * 747796405u + 2891336453u);
    v = (v ^ (v >> 16u)) * 0x45d9f3bu;
    v = (v ^ (v >> 16u)) * 0x45d9f3bu;
    v ^= v >> 16u;
    return float3(v & 0xFFFFu) / 65536.0;
}

// Antialiased coverage of the zero set of f (width in pixels).
static float lineCoverage(float f, float width) {
    return 1.0 - saturate(abs(f) / max(fwidth(f), 1e-6) - (width - 1.0) * 0.5);
}

// Antialiased coverage of the lines at integer values of t (t must be continuous, so its
// screen-space derivative is meaningful; measuring t - round(t) directly would also draw
// spurious lines where that difference jumps between +0.5 and -0.5).
static float gridCoverage(float t, float width) {
    return 1.0 - saturate(abs(t - round(t)) / max(fwidth(t), 1e-6) - (width - 1.0) * 0.5);
}

static float3 hueColor(float h01) {
    float3 k = fmod(float3(5.0, 3.0, 1.0) + h01 * 6.0, 6.0);
    return 1.0 - max(min(min(k, 4.0 - k), 1.0), 0.0);
}

// =====================================================================
// Analysis pass: once per frame, shared by every scope
// =====================================================================

struct AnalysisParams {
    uint2 size;          // sample grid
    uint  legalRange;
    float ditherStep;    // one code value of the source bit depth
};

// A = (R', G', B', Y')   B = (Cb, Cr, HSL hue / 360, HSL saturation)
kernel void analyze(texture2d<float> src [[texture(0)]],
                    texture2d<float, access::write> outA [[texture(1)]],
                    texture2d<float, access::write> outB [[texture(2)]],
                    constant AnalysisParams &p [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.size.x || gid.y >= p.size.y) return;
    // Point-sample: interpolating would invent colours that aren't in the image.
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float3 c = src.sample(s, (float2(gid) + 0.5) / float2(p.size), level(0)).rgb;
    c += (hash3(gid) - 0.5) * p.ditherStep;
    if (p.legalRange != 0) c = toLegal(c);
    float y = luma709(c);
    float2 cc = cbcr709(c, y);
    float sat;
    float hue = hslHue(saturate(c), sat);
    outA.write(float4(c, y), gid);
    outB.write(float4(cc, hue / 360.0, sat), gid);
}

// =====================================================================
// Common scope plumbing
// =====================================================================

struct ScopeUniforms {
    uint2  binSize;      // per plane: columns × rows (histograms: bins × 1)
    uint2  sampleSize;   // analysis grid
    uint   planes;
    uint   mode;
    float  reference;    // bin count that reads as full brightness (log scale)
    float  brightness;
    float4 params;       // scope specific
    float2 viewSize;     // drawable pixels
};

static void plot2D(device atomic_uint *bins, uint2 size, uint plane, float2 uv) {
    if (uv.x < 0.0 || uv.x >= 1.0 || uv.y < 0.0 || uv.y >= 1.0) return;
    uint2 b = uint2(uv * float2(size));
    atomic_fetch_add_explicit(&bins[(plane * size.y + b.y) * size.x + b.x], 1u, memory_order_relaxed);
}

static float traceLevel(uint c, constant ScopeUniforms &u) {
    if (c == 0) return 0.0;
    return saturate((0.18 + 0.82 * log(1.0 + float(c)) / log(1.0 + u.reference)) * u.brightness);
}

static uint bin2D(device const uint *bins, constant ScopeUniforms &u, uint plane, float2 uv) {
    uint2 b = min(uint2(uv * float2(u.binSize)), u.binSize - 1);
    return bins[(plane * u.binSize.y + b.y) * u.binSize.x + b.x];
}

vertex VOut scopeVertex(uint vid [[vertex_id]]) {
    return quadVertex(vid, float2(1.0));
}

// Trace over graticule: the graticule shows through where the trace is dim.
static float4 composite(float3 grat, float3 trace) {
    float t = saturate(max3(trace.r, trace.g, trace.b));
    return float4(grat * (1.0 - t) + trace, 1.0);
}

// =====================================================================
// Waveform: modes 0 Luma, 1 RGB overlay, 2 RGB parade, 3 YRGB parade
// params: x = lowest level shown, y = highest level shown
// =====================================================================

kernel void waveformAccumulate(texture2d<float> A [[texture(0)]],
                               texture2d<float> B [[texture(1)]],
                               device atomic_uint *bins [[buffer(0)]],
                               constant ScopeUniforms &u [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= u.sampleSize.x || gid.y >= u.sampleSize.y) return;
    float4 a = A.read(gid);
    float x = (float(gid.x) + 0.5) / float(u.sampleSize.x);
    float lo = u.params.x, hi = u.params.y;
    float range = hi - lo;
    if (u.mode == 0) {
        plot2D(bins, u.binSize, 0, float2(x, (hi - a.w) / range));
    } else if (u.mode == 3) {
        plot2D(bins, u.binSize, 0, float2(x, (hi - a.w) / range));
        plot2D(bins, u.binSize, 1, float2(x, (hi - a.r) / range));
        plot2D(bins, u.binSize, 2, float2(x, (hi - a.g) / range));
        plot2D(bins, u.binSize, 3, float2(x, (hi - a.b) / range));
    } else {
        plot2D(bins, u.binSize, 0, float2(x, (hi - a.r) / range));
        plot2D(bins, u.binSize, 1, float2(x, (hi - a.g) / range));
        plot2D(bins, u.binSize, 2, float2(x, (hi - a.b) / range));
    }
}

static float3 waveformPlaneColor(uint mode, uint plane) {
    const float3 luma = float3(0.88, 0.95, 0.88);
    const float3 r = float3(1.0, 0.16, 0.14), g = float3(0.18, 1.0, 0.22), b = float3(0.25, 0.42, 1.0);
    if (mode == 0) return luma;
    if (mode == 3) plane = plane == 0 ? 3 : plane - 1;
    return plane == 0 ? r : plane == 1 ? g : plane == 2 ? b : luma;
}

fragment float4 waveformFragment(VOut in [[stage_in]],
                                 device const uint *bins [[buffer(0)]],
                                 constant ScopeUniforms &u [[buffer(1)]]) {
    float lo = u.params.x, hi = u.params.y;
    bool parade = u.mode >= 2;
    uint sections = parade ? u.planes : 1;
    float sx = in.uv.x * float(sections);
    uint sec = min(uint(sx), sections - 1);
    float2 local = float2(sx - float(sec), in.uv.y);

    float3 trace = float3(0.0);
    for (uint p = 0; p < u.planes; ++p) {
        if (parade && p != sec) continue;
        float t = traceLevel(bin2D(bins, u, p, local), u);
        trace += waveformPlaneColor(u.mode, p) * t;
    }

    // Graticule: a line every 10%, brighter at 0 / 50 / 100%.
    float v = mix(hi, lo, in.uv.y);
    float t10 = v * 10.0;
    float nearest = round(t10);
    float inRange = step(-0.5, nearest) * step(nearest, 10.5);
    bool major = nearest == 0.0 || nearest == 5.0 || nearest == 10.0;
    float3 grat = (major ? float3(0.34, 0.30, 0.22) : float3(0.16, 0.15, 0.12))
        * gridCoverage(t10, 1.0) * inRange;
    if (parade) {
        grat = max(grat, float3(0.28) * gridCoverage(sx, 1.0)
                         * step(0.5, round(sx)) * step(round(sx), float(sections) - 0.5));
    }
    return composite(grat, saturate(trace));
}

// =====================================================================
// Vectorscope: modes 0 YUV (Cb, Cr), 1 HSL (hue angle, HSL saturation radius)
// params: x = plot half-extent, y = HSL red angle (degrees), z = skin line angle (degrees)
// =====================================================================

static float2 hslVectorPoint(float hue01, float sat, float redAngle) {
    float a = (redAngle + hue01 * 360.0) * (M_PI_F / 180.0);
    return float2(cos(a), sin(a)) * sat * 0.5;
}

kernel void vectorscopeAccumulate(texture2d<float> A [[texture(0)]],
                                  texture2d<float> B [[texture(1)]],
                                  device atomic_uint *bins [[buffer(0)]],
                                  constant ScopeUniforms &u [[buffer(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= u.sampleSize.x || gid.y >= u.sampleSize.y) return;
    float4 b = B.read(gid);
    float2 p = u.mode == 0 ? b.xy : hslVectorPoint(b.z, b.w, u.params.y);
    float e = u.params.x;
    plot2D(bins, u.binSize, 0, float2((p.x + e) / (2.0 * e), (e - p.y) / (2.0 * e)));
}

// Square target box outline around t with half-size h.
static float targetBox(float2 p, float2 t, float h) {
    float2 d = abs(p - t);
    return lineCoverage(max(d.x, d.y) - h, 1.2);
}

fragment float4 vectorscopeFragment(VOut in [[stage_in]],
                                    device const uint *bins [[buffer(0)]],
                                    constant ScopeUniforms &u [[buffer(1)]]) {
    float tr = traceLevel(bin2D(bins, u, 0, in.uv), u);
    float e = u.params.x;
    float2 p = float2(mix(-e, e, in.uv.x), mix(e, -e, in.uv.y));
    float r = length(p);

    float3 grat = float3(0.0);
    grat = max(grat, float3(0.36) * lineCoverage(r - 0.5, 1.3));                       // 100% ring
    grat = max(grat, float3(0.16) * lineCoverage(r - 0.25, 1.0));                      // 50% ring
    grat = max(grat, float3(0.15) * lineCoverage(p.x, 1.0) * step(abs(p.y), 0.5));   // crosshair
    grat = max(grat, float3(0.15) * lineCoverage(p.y, 1.0) * step(abs(p.x), 0.5));

    // Skin line.
    float sa = u.params.z * (M_PI_F / 180.0);
    float2 sd = float2(cos(sa), sin(sa));
    float along = dot(p, sd);
    grat = max(grat, float3(0.62, 0.46, 0.32) * lineCoverage(p.x * sd.y - p.y * sd.x, 1.3)
                     * step(0.0, along) * step(along, 0.5));

    if (u.mode == 0) {
        // 75% and 100% colour-bar targets: R, Yl, G, Cy, B, Mg.
        const float3 bars[6] = { float3(1, 0, 0), float3(1, 1, 0), float3(0, 1, 0),
                                 float3(0, 1, 1), float3(0, 0, 1), float3(1, 0, 1) };
        for (uint i = 0; i < 6; ++i) {
            float3 tint = bars[i] * 0.65 + 0.2;
            for (uint l = 0; l < 2; ++l) {
                float3 c = bars[i] * (l == 0 ? 0.75 : 1.0);
                float2 t = cbcr709(c, luma709(c));
                grat = max(grat, tint * targetBox(p, t, l == 0 ? 0.03 : 0.018) * (l == 0 ? 0.55 : 0.9));
            }
        }
    } else {
        // HSL: saturation rings every 25% and hue spokes every 30°.
        grat = max(grat, float3(0.11) * lineCoverage(r - 0.125, 1.0));
        grat = max(grat, float3(0.11) * lineCoverage(r - 0.375, 1.0));
        // Spokes: distance to the nearest 30° ray, measured perpendicular to it.
        float ang = atan2(p.y, p.x) * (180.0 / M_PI_F) - u.params.y;
        float k = round(ang / 30.0);
        float ra = (u.params.y + k * 30.0) * (M_PI_F / 180.0);
        float2 rd = float2(cos(ra), sin(ra));
        float spoke = p.x * rd.y - p.y * rd.x;
        grat = max(grat, float3(0.12) * lineCoverage(spoke, 1.0) * step(r, 0.5) * step(0.0, dot(p, rd)));
        // Hue ring just outside 100%.
        float hue01 = fract((atan2(p.y, p.x) * (180.0 / M_PI_F) - u.params.y) / 360.0);
        float ring = step(0.505, r) * step(r, 0.525);
        grat = max(grat, hueColor(hue01) * 0.55 * ring);
    }
    return composite(grat, float3(0.82, 1.0, 0.86) * tr);
}

// =====================================================================
// Sat / Lum: x = Y', y = saturation. Mode 0 chroma (vectorscope radius), 1 HSL saturation.
// A 95th-percentile saturation curve is computed per luma column.
// =====================================================================

constant float SL_LO = \(SatLumGeometry.lo);
constant float SL_HI = \(SatLumGeometry.hi);

kernel void satLumAccumulate(texture2d<float> A [[texture(0)]],
                             texture2d<float> B [[texture(1)]],
                             device atomic_uint *bins [[buffer(0)]],
                             constant ScopeUniforms &u [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= u.sampleSize.x || gid.y >= u.sampleSize.y) return;
    float y = A.read(gid).w;
    float4 b = B.read(gid);
    float sat = u.mode == 0 ? saturate(length(b.xy) * 2.0) : b.w;
    float range = SL_HI - SL_LO;
    plot2D(bins, u.binSize, 0, float2((y - SL_LO) / range, (SL_HI - sat) / range));
}

kernel void satLumCurve(device const uint *bins [[buffer(0)]],
                        constant ScopeUniforms &u [[buffer(1)]],
                        device float *curve [[buffer(2)]],
                        uint x [[thread_position_in_grid]]) {
    uint w = u.binSize.x, h = u.binSize.y;
    if (x >= w) return;
    uint total = 0;
    for (uint y = 0; y < h; ++y) total += bins[y * w + x];
    if (total < 12) { curve[x] = -1.0; return; }
    uint target = uint(ceil(0.95 * float(total)));
    uint acc = 0;
    for (int y = int(h) - 1; y >= 0; --y) {          // bottom row = no saturation
        acc += bins[uint(y) * w + x];
        if (acc >= target) { curve[x] = float(y) + 0.5; return; }
    }
    curve[x] = 0.5;
}

fragment float4 satLumFragment(VOut in [[stage_in]],
                               device const uint *bins [[buffer(0)]],
                               constant ScopeUniforms &u [[buffer(1)]],
                               device const float *curve [[buffer(2)]]) {
    float tr = traceLevel(bin2D(bins, u, 0, in.uv), u);
    float range = SL_HI - SL_LO;
    float lum = SL_LO + in.uv.x * range;
    float sat = SL_HI - in.uv.y * range;

    float3 grat = float3(0.0);
    for (uint i = 0; i <= 4; ++i) {
        float g = float(i) * 0.25;
        float w = (i == 0 || i == 4) ? 0.3 : 0.15;
        grat = max(grat, float3(w) * lineCoverage(lum - g, 1.0) * step(-0.001, sat) * step(sat, 1.001));
        grat = max(grat, float3(w) * lineCoverage(sat - g, 1.0) * step(-0.001, lum) * step(lum, 1.001));
    }

    // 95th-percentile curve, joined to its neighbours so it reads as a line.
    uint w = u.binSize.x;
    int x = min(int(in.uv.x * float(w)), int(w) - 1);
    float row = in.uv.y * float(u.binSize.y);
    float c0 = curve[x];
    float3 line = float3(0.0);
    if (c0 >= 0.0) {
        float lo = c0, hi = c0;
        if (x > 0 && curve[x - 1] >= 0.0) { lo = min(lo, (c0 + curve[x - 1]) * 0.5); hi = max(hi, (c0 + curve[x - 1]) * 0.5); }
        if (x + 1 < int(w) && curve[x + 1] >= 0.0) { lo = min(lo, (c0 + curve[x + 1]) * 0.5); hi = max(hi, (c0 + curve[x + 1]) * 0.5); }
        if (row >= lo - 1.0 && row <= hi + 1.0) line = float3(1.0, 0.68, 0.18);
    }
    float4 out = composite(grat, float3(0.82, 1.0, 0.86) * tr);
    return float4(max(out.rgb, line), 1.0);
}

// =====================================================================
// Histogram: modes 0 RGB, 1 Luma, 2 Saturation (chroma), 3 Hue (360 bins)
// params: x = hue saturation threshold, y = log scale (1) / linear (0)
// Bins are counted per threadgroup first, then merged: few bins + millions of samples
// would otherwise serialize on global atomics.
// =====================================================================

kernel void histogramAccumulate(texture2d<float> A [[texture(0)]],
                                texture2d<float> B [[texture(1)]],
                                device atomic_uint *bins [[buffer(0)]],
                                constant ScopeUniforms &u [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]],
                                uint lid [[thread_index_in_threadgroup]],
                                uint2 tgSize [[threads_per_threadgroup]]) {
    threadgroup atomic_uint local[1024];
    uint n = u.binSize.x;
    uint total = min(u.planes * n, 1024u);
    uint threads = tgSize.x * tgSize.y;
    for (uint i = lid; i < total; i += threads) atomic_store_explicit(&local[i], 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (gid.x < u.sampleSize.x && gid.y < u.sampleSize.y) {
        float4 a = A.read(gid);
        float4 b = B.read(gid);
        float fn = float(n);
        if (u.mode == 0) {
            for (uint c = 0; c < 3; ++c) {
                uint i = uint(clamp(a[c] * fn, 0.0, fn - 1.0));
                atomic_fetch_add_explicit(&local[c * n + i], 1u, memory_order_relaxed);
            }
        } else if (u.mode == 1) {
            atomic_fetch_add_explicit(&local[uint(clamp(a.w * fn, 0.0, fn - 1.0))], 1u, memory_order_relaxed);
        } else if (u.mode == 2) {
            float s = length(b.xy) * 2.0;
            atomic_fetch_add_explicit(&local[uint(clamp(s * fn, 0.0, fn - 1.0))], 1u, memory_order_relaxed);
        } else if (length(b.xy) * 2.0 >= u.params.x) {
            atomic_fetch_add_explicit(&local[uint(clamp(b.z * fn, 0.0, fn - 1.0))], 1u, memory_order_relaxed);
        }
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint i = lid; i < total; i += threads) {
        uint v = atomic_load_explicit(&local[i], memory_order_relaxed);
        if (v != 0) atomic_fetch_add_explicit(&bins[i], v, memory_order_relaxed);
    }
}

// stats[0] = vertical scale: tallest bin (ignoring the end bins for RGB/Luma/Sat, which
// collect clipping), capped so isolated spikes don't squash the rest;
// stats[1 + 2p] / stats[2 + 2p] = first / last bin of plane p.
kernel void histogramStats(device const uint *bins [[buffer(0)]],
                           constant ScopeUniforms &u [[buffer(1)]],
                           device uint *stats [[buffer(2)]],
                           uint tid [[thread_position_in_grid]]) {
    if (tid != 0) return;
    uint n = u.binSize.x;
    uint peak = 1;
    float sum = 0.0, nonzero = 0.0;
    bool skipEnds = u.mode != 3;
    for (uint p = 0; p < u.planes; ++p) {
        stats[1 + 2 * p] = bins[p * n];
        stats[2 + 2 * p] = bins[p * n + n - 1];
        for (uint i = skipEnds ? 1 : 0; i < (skipEnds ? n - 1 : n); ++i) {
            uint v = bins[p * n + i];
            peak = max(peak, v);
            if (v > 0) { sum += float(v); nonzero += 1.0; }
        }
    }
    // A few huge spikes (a flat background, a solid graphic) would flatten everything else;
    // cap the scale at 8× the average occupied bin and let spikes run off the top.
    float cap = nonzero > 0.0 ? 8.0 * sum / nonzero : 1.0;
    stats[0] = max(1u, min(peak, uint(cap)));
}

fragment float4 histogramFragment(VOut in [[stage_in]],
                                  device const uint *bins [[buffer(0)]],
                                  constant ScopeUniforms &u [[buffer(1)]],
                                  device const uint *stats [[buffer(2)]]) {
    uint n = u.binSize.x;
    uint bin = min(uint(in.uv.x * float(n)), n - 1);
    float level = 1.0 - in.uv.y;
    float px = fwidth(level);
    float peak = float(max(stats[0], 1u));
    bool logScale = u.params.y > 0.5;

    float3 col = float3(0.0);
    for (uint p = 0; p < u.planes; ++p) {
        float c = float(bins[p * n + bin]);
        float h = logScale ? log(1.0 + c) / log(1.0 + peak) : c / peak;
        h = min(h, 1.0) * 0.94;
        float3 pc;
        if (u.mode == 0) pc = p == 0 ? float3(1.0, 0.2, 0.18) : p == 1 ? float3(0.2, 1.0, 0.25) : float3(0.3, 0.45, 1.0);
        else if (u.mode == 3) pc = hueColor((float(bin) + 0.5) / float(n));
        else pc = float3(0.86);
        if (c > 0.0 && level <= h) col += pc * (u.mode == 0 ? 0.5 : 0.62);
        if (c > 0.0 && abs(level - h) < px * 1.5) col += pc * 0.55;
    }

    // Graticule: quarters (hue: every 60°), and a baseline.
    float x = in.uv.x;
    float3 grat = float3(0.0);
    float steps = u.mode == 3 ? 6.0 : 4.0;
    grat = max(grat, float3(0.14) * gridCoverage(x * steps, 1.0));
    grat = max(grat, float3(0.14) * lineCoverage(level - 0.47, 1.0));
    grat = max(grat, float3(0.3) * lineCoverage(level, 1.0));
    return composite(grat, saturate(col));
}

// =====================================================================
// Twin Peaks (diamond display): upper diamond B−G vs B+G, lower R−G vs −(R+G)
// =====================================================================

constant float TP_XMAX = \(TwinPeaksGeometry.xMax);
constant float TP_YMAX = \(TwinPeaksGeometry.yMax);

static float2 tpUV(float2 p) {
    return float2((p.x + TP_XMAX) / (2.0 * TP_XMAX), (TP_YMAX - p.y) / (2.0 * TP_YMAX));
}

kernel void twinPeaksAccumulate(texture2d<float> A [[texture(0)]],
                                texture2d<float> B [[texture(1)]],
                                device atomic_uint *bins [[buffer(0)]],
                                constant ScopeUniforms &u [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= u.sampleSize.x || gid.y >= u.sampleSize.y) return;
    float3 c = A.read(gid).rgb;
    plot2D(bins, u.binSize, 0, tpUV(float2(c.b - c.g, c.b + c.g)));
    plot2D(bins, u.binSize, 0, tpUV(float2(c.r - c.g, -(c.r + c.g))));
}

fragment float4 twinPeaksFragment(VOut in [[stage_in]],
                                  device const uint *bins [[buffer(0)]],
                                  constant ScopeUniforms &u [[buffer(1)]]) {
    float tr = traceLevel(bin2D(bins, u, 0, in.uv), u);
    float x = mix(-TP_XMAX, TP_XMAX, in.uv.x);
    float y = mix(TP_YMAX, -TP_YMAX, in.uv.y);
    const float3 gCol = float3(0.20, 0.75, 0.25);
    const float3 bCol = float3(0.25, 0.40, 1.00);
    const float3 rCol = float3(0.90, 0.20, 0.20);
    bool upper = y >= 0.0;
    float edge = upper ? abs(x) + abs(y - 1.0) - 1.0 : abs(x) + abs(y + 1.0) - 1.0;
    float3 edgeCol = x < 0.0 ? gCol : (upper ? bCol : rCol);
    float3 grat = edgeCol * 0.8 * lineCoverage(edge, 1.5);
    grat = max(grat, float3(0.22) * lineCoverage(x, 1.0) * step(abs(y), 2.0));
    return composite(grat, float3(tr));
}
"""
