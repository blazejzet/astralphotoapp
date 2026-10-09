#include <metal_stdlib>
using namespace metal;

// Layouts mirror the Swift structs in MetalStacker.swift.

struct BinParams {
    float4 black;          // black level per CFA position (0,0) (1,0) (0,1) (1,1)
    uint4 colorIndex;      // colour at each CFA position: 0 R, 1 G, 2 B
    uint rawWidth;
    uint rawHeight;
    uint rawRowElements;
    uint outWidth;
    uint outHeight;
    float invRange;        // 1 / (white − black)
    uint useDark;
    float hotRatio;        // 0 disables the single-pixel hot filter
    uint rawOriginX;       // active (image) area inside the sensor buffer; rawWidth/rawHeight are its size
    uint rawOriginY;
    uint pad0;
    uint pad1;
};

struct WarpParams {
    float3x3 G;            // undistorted reference pixels → undistorted frame pixels
    float2 lutCenter;
    float lutMaxRadius;
    uint lutCount;
    uint width;
    uint height;
    uint useLUT;
    float frameWeight;
    float lambdaS;
    float lambdaR;
    float modelError2;
    float kappa2;
    float rejectS;
    float rejectT;
    uint robust;
    uint resetAfter;
    uint useOcclusion;
    uint warmupCount;
    float resetMaxWeight;  // resets only while a pixel holds little weight (bad seed)
    uint plainEnabled;     // feed the unweighted mask statistics (early drift window)
};

struct PreviewParams {
    uint srcWidth;
    uint srcHeight;
    uint outWidth;
    uint outHeight;
    uint originX;
    uint originY;
    uint step;
    uint source;           // 0 sky stack (fallback foreground), 1 current frame
};

// MARK: - RAW → 2×2 super-pixel

inline float rawAt(device const ushort *raw, constant BinParams &p, int x, int y) {
    // Clamp inside the active area, then address the full buffer (CFA parity from absolute coordinates).
    uint ax = uint(clamp(x, 0, int(p.rawWidth) - 1)) + p.rawOriginX;
    uint ay = uint(clamp(y, 0, int(p.rawHeight) - 1)) + p.rawOriginY;
    uint pos = (ay & 1u) * 2u + (ax & 1u);
    return (float(raw[ay * p.rawRowElements + ax]) - p.black[pos]) * p.invRange;
}

// Single-pixel spikes (hot pixels, cosmic rays): far above all 4 adjacent samples → replaced by
// the mean of the same-colour neighbours. Stars have a PSF wider than one pixel and survive.
inline float hotFiltered(device const ushort *raw, constant BinParams &p, int x, int y) {
    float v = rawAt(raw, p, x, y);
    if (p.hotRatio <= 0.0f) { return v; }
    float m = max(max(rawAt(raw, p, x - 1, y), rawAt(raw, p, x + 1, y)),
                  max(rawAt(raw, p, x, y - 1), rawAt(raw, p, x, y + 1)));
    if (v > p.hotRatio * max(m, 0.0f) + 0.01f) {
        return 0.25f * (rawAt(raw, p, x - 2, y) + rawAt(raw, p, x + 2, y) +
                        rawAt(raw, p, x, y - 2) + rawAt(raw, p, x, y + 2));
    }
    return v;
}

kernel void binBayer(device const ushort *raw [[buffer(0)]],
                     device float4 *frame [[buffer(1)]],
                     device const float4 *dark [[buffer(2)]],
                     constant BinParams &p [[buffer(3)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.outWidth || gid.y >= p.outHeight) { return; }
    int x = int(gid.x) * 2, y = int(gid.y) * 2;
    float s[4] = { hotFiltered(raw, p, x, y), hotFiltered(raw, p, x + 1, y),
                   hotFiltered(raw, p, x, y + 1), hotFiltered(raw, p, x + 1, y + 1) };
    float3 rgb = float3(0.0f);
    float3 count = float3(0.0f);
    for (uint k = 0; k < 4; k++) {
        // Colour of sample k at its absolute sensor position (odd crop origins shift the pattern).
        uint kx = (uint(x) + (k & 1u) + p.rawOriginX) & 1u, ky = (uint(y) + (k >> 1) + p.rawOriginY) & 1u;
        uint c = p.colorIndex[ky * 2u + kx];
        rgb[c] += s[k];
        count[c] += 1.0f;
    }
    rgb /= max(count, float3(1.0f));
    uint i = gid.y * p.outWidth + gid.x;
    if (p.useDark != 0) { rgb -= dark[i].xyz; }
    frame[i] = float4(rgb, (rgb.x + 2.0f * rgb.y + rgb.z) * 0.25f);
}

// Fallback path: demosaiced linear RGB rendered by CIRAWFilter.
kernel void packRGB(texture2d<float, access::read> src [[texture(0)]],
                    device float4 *frame [[buffer(0)]],
                    device const float4 *dark [[buffer(1)]],
                    constant uint4 &dims [[buffer(2)]],   // width, height, useDark
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }
    float3 rgb = src.read(gid).rgb;
    uint i = gid.y * dims.x + gid.x;
    if (dims.z != 0) { rgb -= dark[i].xyz; }
    frame[i] = float4(rgb, (rgb.x + 2.0f * rgb.y + rgb.z) * 0.25f);
}

// MARK: - Geometry helpers

inline float2 lutMap(float2 p, constant float *lut, constant WarpParams &w) {
    float2 v = p - w.lutCenter;
    float pos = length(v) * float(w.lutCount - 1) / w.lutMaxRadius;
    uint idx = uint(pos);
    float mag = idx >= w.lutCount - 1 ? lut[w.lutCount - 1] : mix(lut[idx], lut[idx + 1], pos - float(idx));
    return w.lutCenter + v * (1.0f + mag);
}

// Output pixel u (reference epoch, raw grid) → source pixel in frame k: D(G · D⁻¹(u)).
inline bool sourcePosition(uint2 gid, constant WarpParams &w, constant float *lutForward,
                           constant float *lutInverse, thread float2 &out) {
    float2 u = float2(gid);
    if (w.useLUT != 0) { u = lutMap(u, lutInverse, w); }
    float3 h = w.G * float3(u, 1.0f);
    if (h.z <= 1e-6f) { return false; }
    float2 v = h.xy / h.z;
    if (w.useLUT != 0) { v = lutMap(v, lutForward, w); }
    out = v;
    return true;
}

inline bool sampleFrame(device const float4 *frame, uint w, uint h, float2 p, thread float4 &out) {
    if (p.x < 0.0f || p.y < 0.0f || p.x > float(w - 1) || p.y > float(h - 1)) { return false; }
    uint x0 = min(uint(p.x), w - 2), y0 = min(uint(p.y), h - 2);
    float fx = p.x - float(x0), fy = p.y - float(y0);
    uint i = y0 * w + x0;
    out = mix(mix(frame[i], frame[i + 1], fx), mix(frame[i + w], frame[i + w + 1], fx), fy);
    return true;
}

inline bool occluded(device const float *mask, constant WarpParams &w, float2 p) {
    if (w.useOcclusion == 0) { return false; }
    // Bilinear, like PlanarImage.bilinear in the CPU reference (p is already inside the frame).
    uint x0 = min(uint(p.x), w.width - 2), y0 = min(uint(p.y), w.height - 2);
    float fx = p.x - float(x0), fy = p.y - float(y0);
    uint i = y0 * w.width + x0;
    float m = mix(mix(mask[i], mask[i + 1], fx), mix(mask[i + w.width], mask[i + w.width + 1], fx), fy);
    return m > 0.5f;
}

inline float robustWeight(float value, float mean, constant WarpParams &w) {
    float m = max(mean, 0.0f);
    float variance = max(w.lambdaS * m + w.lambdaR + w.modelError2 * m * m, 1e-14f);
    float d = value - mean;
    return clamp(w.rejectS * exp(-(d * d / variance) / w.kappa2) - w.rejectT, 0.0f, 1.0f);
}

// Weighted Welford update of luma mean/M2 plus weighted RGB sums.
inline void accumulate(device float4 *acc, device float4 *stats, uint i, float4 x, float w) {
    float4 a = acc[i];
    float4 s = stats[i];
    float wNew = a.w + w;
    if (wNew <= 0.0f) { return; }
    float delta = x.w - s.x;
    float mean = s.x + (w / wNew) * delta;
    s.y += w * delta * (x.w - mean);
    s.x = mean;
    a.xyz += w * x.xyz;
    a.w = wNew;
    acc[i] = a;
    stats[i] = s;
}

// MARK: - Sky stack (registered)

// Unweighted registered luma statistics (sum, sum², count) – ignore robust weights and occlusion.
inline void accumulatePlain(device float4 *plain, uint i, float luma, constant WarpParams &w) {
    if (w.plainEnabled == 0) { return; }
    float4 p = plain[i];
    plain[i] = float4(p.x + luma, p.y + luma * luma, p.z + 1.0f, 0.0f);
}

kernel void warpToWarmup(device const float4 *frame [[buffer(0)]],
                         device half4 *warm [[buffer(1)]],
                         constant WarpParams &w [[buffer(2)]],
                         constant float *lutForward [[buffer(3)]],
                         constant float *lutInverse [[buffer(4)]],
                         device const float *occlusion [[buffer(5)]],
                         device float4 *plain [[buffer(6)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= w.width || gid.y >= w.height) { return; }
    uint i = gid.y * w.width + gid.x;
    float2 src;
    float4 x;
    if (!sourcePosition(gid, w, lutForward, lutInverse, src) || !sampleFrame(frame, w.width, w.height, src, x)) {
        warm[i] = half4(0.0h, 0.0h, 0.0h, -60000.0h);
        return;
    }
    accumulatePlain(plain, i, x.w, w);
    if (occluded(occlusion, w, src)) {
        warm[i] = half4(0.0h, 0.0h, 0.0h, -60000.0h);
        return;
    }
    warm[i] = half4(x);
}

// Seeds the robust mean with the per-pixel median of the first frames (Night Sight / HDR+ style
// reference), then merges those frames with weights relative to it.
kernel void seedFromWarmup(device const half4 *warm0 [[buffer(0)]],
                           device const half4 *warm1 [[buffer(1)]],
                           device const half4 *warm2 [[buffer(2)]],
                           device float4 *acc [[buffer(3)]],
                           device float4 *stats [[buffer(4)]],
                           constant WarpParams &w [[buffer(5)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= w.width || gid.y >= w.height) { return; }
    uint i = gid.y * w.width + gid.x;
    float4 v[3] = { float4(warm0[i]), float4(warm1[i]), float4(warm2[i]) };
    float4 valid[3];
    uint n = 0;
    for (uint k = 0; k < min(w.warmupCount, 3u); k++) {
        if (v[k].w > -50000.0f) { valid[n++] = v[k]; }
    }
    if (n == 0) { return; }
    if (n < 3) {
        for (uint k = 0; k < n; k++) { accumulate(acc, stats, i, valid[k], w.frameWeight); }
        return;
    }
    float a = valid[0].w, b = valid[1].w, c = valid[2].w;
    float med = max(min(a, b), min(max(a, b), c));
    for (uint k = 0; k < 3; k++) {
        accumulate(acc, stats, i, valid[k], w.frameWeight * robustWeight(valid[k].w, med, w));
    }
}

kernel void accumulateSky(device const float4 *frame [[buffer(0)]],
                          device float4 *acc [[buffer(1)]],
                          device float4 *stats [[buffer(2)]],
                          constant WarpParams &w [[buffer(3)]],
                          constant float *lutForward [[buffer(4)]],
                          constant float *lutInverse [[buffer(5)]],
                          device const float *occlusion [[buffer(6)]],
                          device float4 *plain [[buffer(7)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= w.width || gid.y >= w.height) { return; }
    uint i = gid.y * w.width + gid.x;
    float2 src;
    float4 x;
    if (!sourcePosition(gid, w, lutForward, lutInverse, src) || !sampleFrame(frame, w.width, w.height, src, x)) { return; }
    accumulatePlain(plain, i, x.w, w);
    if (occluded(occlusion, w, src)) { return; }
    float weight = w.frameWeight;
    if (w.robust != 0 && acc[i].w > 0.0f) {
        float4 s = stats[i];
        float wr = robustWeight(x.w, s.x, w);
        if (wr < 0.05f) {
            s.z += 1.0f;
            if (s.z >= float(w.resetAfter) && acc[i].w < w.resetMaxWeight) {
                // The running mean itself was wrong (e.g. contaminated seed): restart this pixel.
                acc[i] = float4(x.xyz * w.frameWeight, w.frameWeight);
                stats[i] = float4(x.w, 0.0f, 0.0f, 0.0f);
            } else {
                stats[i] = s;
            }
            return;
        }
        s.z = 0.0f;
        stats[i] = s;
        weight *= wr;
    }
    accumulate(acc, stats, i, x, weight);
}

// MARK: - Foreground (static) stack and darks

kernel void accumulateForeground(device const float4 *frame [[buffer(0)]],
                                 device float4 *acc [[buffer(1)]],
                                 device float4 *stats [[buffer(2)]],
                                 constant uint2 &dims [[buffer(3)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }
    accumulate(acc, stats, gid.y * dims.x + gid.x, frame[gid.y * dims.x + gid.x], 1.0f);
}

kernel void accumulateDark(device const float4 *frame [[buffer(0)]],
                           device float4 *acc [[buffer(1)]],
                           constant uint2 &dims [[buffer(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }
    uint i = gid.y * dims.x + gid.x;
    acc[i] += float4(frame[i].xyz, 1.0f);
}

// MARK: - Preview (box-downsampled linear RGB; stretched on the CPU)

kernel void previewDownsample(device const float4 *skyAcc [[buffer(0)]],
                              device const float4 *fgAcc [[buffer(1)]],
                              device const float4 *frame [[buffer(2)]],
                              device float4 *out [[buffer(3)]],
                              constant PreviewParams &p [[buffer(4)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.outWidth || gid.y >= p.outHeight) { return; }
    float3 sum = float3(0.0f);
    float n = 0.0f;
    for (uint dy = 0; dy < p.step; dy++) {
        for (uint dx = 0; dx < p.step; dx++) {
            uint x = p.originX + gid.x * p.step + dx, y = p.originY + gid.y * p.step + dy;
            if (x >= p.srcWidth || y >= p.srcHeight) { continue; }
            uint i = y * p.srcWidth + x;
            float3 v;
            if (p.source == 1) {
                v = frame[i].xyz;
            } else {
                float4 s = skyAcc[i];
                float4 f = fgAcc[i];
                if (s.w > 0.0f) { v = s.xyz / s.w; }
                else if (f.w > 0.0f) { v = f.xyz / f.w; }
                else { continue; }
            }
            sum += v;
            n += 1.0f;
        }
    }
    out[gid.y * p.outWidth + gid.x] = n > 0.0f ? float4(sum / n, 1.0f) : float4(0.0f);
}
