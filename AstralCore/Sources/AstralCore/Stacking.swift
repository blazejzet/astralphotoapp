import Foundation
import simd

// MARK: - Noise model

/// Affine (shot + read) noise model σ²(μ) = λ_s·μ + λ_r, as in HDR+ (Hasinoff et al. 2016) and
/// Wronski et al. 2019. A relative model-error term (ε·μ)² protects bright star cores, whose
/// pixel values fluctuate with sub-pixel registration and seeing.
public struct NoiseModel: Sendable, Equatable {
    public var lambdaS: Double
    public var lambdaR: Double
    public var relativeModelError: Double

    public init(lambdaS: Double, lambdaR: Double, relativeModelError: Double = 0.1) {
        self.lambdaS = lambdaS
        self.lambdaR = lambdaR
        self.relativeModelError = relativeModelError
    }

    @inlinable
    public func variance(at mean: Double) -> Double {
        let m = max(mean, 0)
        return max(lambdaS * m + lambdaR + (relativeModelError * m) * (relativeModelError * m), 1e-14)
    }
}

/// Estimates (λ_s, λ_r) from two consecutive, unregistered frames: per tile, var(J_k − J_{k−1})/2
/// against the tile mean. Sky motion between 1 s frames is a fraction of a pixel, and tiles with
/// stars/edges are suppressed by fitting a line through per-quantile medians.
public struct NoiseModelEstimator: Sendable {
    public var tileSize = 32
    public var bins = 8

    public init() {}

    public func estimate(current: PlanarImage, previous: PlanarImage) -> NoiseModel? {
        guard current.width == previous.width, current.height == previous.height else { return nil }
        let w = current.width, h = current.height, t = tileSize
        var points: [(mean: Double, variance: Double)] = []
        var ty = 0
        while ty + t <= h {
            var tx = 0
            while tx + t <= w {
                var s = 0.0, d = 0.0, d2 = 0.0
                for y in ty..<(ty + t) {
                    let row = y * w
                    for x in tx..<(tx + t) {
                        let a = Double(current.pixels[row + x]), b = Double(previous.pixels[row + x])
                        s += a + b
                        d += a - b
                        d2 += (a - b) * (a - b)
                    }
                }
                let n = Double(t * t)
                let varDiff = d2 / n - (d / n) * (d / n)
                points.append((s / (2 * n), varDiff / 2))
                tx += t
            }
            ty += t
        }
        guard points.count >= bins * 2 else { return nil }
        points.sort { $0.mean < $1.mean }
        var xs: [Double] = [], ys: [Double] = []
        let perBin = points.count / bins
        for b in 0..<bins {
            let slice = points[(b * perBin)..<(b == bins - 1 ? points.count : (b + 1) * perBin)]
            xs.append(median(slice.map(\.mean)))
            ys.append(median(slice.map(\.variance)))
        }
        // Least-squares line through bin medians.
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for i in 0..<xs.count { sxx += (xs[i] - mx) * (xs[i] - mx); sxy += (xs[i] - mx) * (ys[i] - my) }
        var slope = sxx > 1e-20 ? sxy / sxx : 0
        var intercept = my - slope * mx
        let minVariance = ys.min() ?? my
        if slope < 0 { slope = 0; intercept = my }
        if intercept <= 0 { intercept = max(minVariance * 0.5, 1e-12) }
        return NoiseModel(lambdaS: slope, lambdaR: intercept)
    }
}

/// Robustness weight in the spirit of Wronski et al. 2019: w = clamp(s·exp(−z²/κ²) − t, 0, 1),
/// z = (x − μ)/σ(μ). Satellites, planes, hot pixels and cosmic rays get w ≈ 0.
public struct RobustWeighting: Sendable, Equatable {
    public var s: Double = 1.05
    public var t: Double = 0.05
    public var kappa: Double = 4.0
    /// Consecutive rejections after which a pixel's accumulator is reset (the mean itself was wrong).
    public var resetAfter: Int = 8
    /// …but only while the pixel holds little weight, i.e. a bad seed. Later, a static light or roof
    /// edge drifting slowly through the registered stack would be followed and drawn as a streak
    /// (fourth night: light pillars rising from the city lights).
    public var resetMaxWeight: Double = 6

    public init() {}

    @inlinable
    public func weight(value: Double, mean: Double, noise: NoiseModel) -> Double {
        let d = value - mean
        let z2 = d * d / noise.variance(at: mean)
        return min(max(s * exp(-z2 / (kappa * kappa)) - t, 0), 1)
    }
}

// MARK: - Stack result

public struct StackResult: Sendable {
    /// Registered (sky-tracking) weighted mean, reference-epoch raw grid.
    public var sky: RGBImage
    /// Σ weights per pixel (coverage map).
    public var skyWeight: PlanarImage
    /// Weighted temporal variance of luma in the registered stack.
    public var skyVariance: PlanarImage
    /// Unregistered mean (static foreground).
    public var foreground: RGBImage
    /// Temporal variance of luma without registration.
    public var foregroundVariance: PlanarImage
    public var frameCount: Int
    /// Registered luma mean and variance *without* robust weights or occlusion – the evidence for the
    /// sky mask (robust weights hide exactly the moving scenery the mask must find). NaN = no samples.
    public var skyPlainMean: PlanarImage?
    public var skyPlainVariance: PlanarImage?

    public init(sky: RGBImage, skyWeight: PlanarImage, skyVariance: PlanarImage, foreground: RGBImage,
                foregroundVariance: PlanarImage, frameCount: Int,
                skyPlainMean: PlanarImage? = nil, skyPlainVariance: PlanarImage? = nil) {
        self.sky = sky
        self.skyWeight = skyWeight
        self.skyVariance = skyVariance
        self.foreground = foreground
        self.foregroundVariance = foregroundVariance
        self.frameCount = frameCount
        self.skyPlainMean = skyPlainMean
        self.skyPlainVariance = skyPlainVariance
    }
}

// MARK: - CPU reference stacker (mirrors Shaders.metal)

/// Streaming two-layer stacker for J = M_sky·I_sky + I_ground:
/// * sky layer: frames are inverse-warped with u_k = D(G_k·D⁻¹(u)) and merged with robust weights
///   (weighted Welford mean/variance, O(1) memory in N); the first 3 frames seed the mean by their median;
/// * foreground layer: plain running mean/variance without warping.
public final class CPUStacker {
    public let width: Int
    public let height: Int
    public var weighting: RobustWeighting

    private var skyR: [Float], skyG: [Float], skyB: [Float], skyW: [Float]
    private var skyMean: [Float], skyM2: [Float], skyRejections: [Float]
    private var fgR: [Float], fgG: [Float], fgB: [Float]
    private var fgMean: [Float], fgM2: [Float]
    private var plainSum: [Float], plainSq: [Float], plainCount: [Float]
    private var warmup: [(RGBImage, PlanarImage, Float)] = []
    private var lastNoise = NoiseModel(lambdaS: 0, lambdaR: 1e-6)
    public private(set) var frameCount = 0

    public static let warmupFrames = 3
    /// Sky drift (px) up to which frames feed the unweighted mask statistics.
    public static let plainWindowPixels = 15.0

    /// Largest displacement of the frame corners and centre under a warp (undistorted pixels).
    public static func maxDisplacement(_ h: Homography, width: Int, height: Int) -> Double {
        let points = [SIMD2<Double>(0, 0), SIMD2(Double(width - 1), 0), SIMD2(0, Double(height - 1)),
                      SIMD2(Double(width - 1), Double(height - 1)), SIMD2(Double(width - 1) / 2, Double(height - 1) / 2)]
        return points.map { p in h.apply(p).map { simd_distance($0, p) } ?? .infinity }.max() ?? 0
    }

    public init(width: Int, height: Int, weighting: RobustWeighting = .init()) {
        self.width = width
        self.height = height
        self.weighting = weighting
        let zero = [Float](repeating: 0, count: width * height)
        skyR = zero; skyG = zero; skyB = zero; skyW = zero
        skyMean = zero; skyM2 = zero; skyRejections = zero
        fgR = zero; fgG = zero; fgB = zero; fgMean = zero; fgM2 = zero
        plainSum = zero; plainSq = zero; plainCount = zero
    }

    /// Inverse warp of a frame onto the reference grid; invalid pixels get NaN luma.
    /// `occlusion` (ground probability on the static sensor grid) drops sky samples that fall behind
    /// the horizon in this frame — the sky keeps rotating "into" the landscape during long sessions.
    /// `plain` is the warped luma ignoring occlusion (for the mask evidence).
    public static func warp(_ frame: RGBImage, mapper: WarpMapper, occlusion: PlanarImage? = nil)
        -> (RGBImage, PlanarImage, plain: PlanarImage) {
        let w = frame.width, h = frame.height
        let r = frame.channel(0), g = frame.channel(1), b = frame.channel(2)
        var out = RGBImage(width: w, height: h)
        var luma = PlanarImage(width: w, height: h, repeating: .nan)
        var plain = PlanarImage(width: w, height: h, repeating: .nan)
        for y in 0..<h {
            for x in 0..<w {
                guard let src = mapper.sourcePosition(forOutput: SIMD2(Double(x), Double(y))),
                      let vr = r.bilinear(src), let vg = g.bilinear(src), let vb = b.bilinear(src) else { continue }
                let i = y * w + x
                let l = (vr + 2 * vg + vb) * 0.25
                plain.pixels[i] = l
                if let occlusion, (occlusion.bilinear(src) ?? 1) > 0.5 { continue }
                out.r[i] = vr; out.g[i] = vg; out.b[i] = vb
                luma.pixels[i] = l
            }
        }
        return (out, luma, plain)
    }

    /// `accumulatePlain`: feed the unweighted registered statistics only while the sky has moved a little
    /// (see `plainWindowPixels`); later, sky rotating behind the horizon would read as ground evidence.
    public func add(frame: RGBImage, mapper: WarpMapper, noise: NoiseModel, frameWeight: Float = 1,
                    occlusion: PlanarImage? = nil, accumulatePlain: Bool = true) {
        precondition(frame.width == width && frame.height == height)
        lastNoise = noise
        accumulateForeground(frame)
        let (warped, luma, plain) = Self.warp(frame, mapper: mapper, occlusion: occlusion)
        for i in 0..<(width * height) where accumulatePlain && plain.pixels[i].isFinite {
            let l = plain.pixels[i]
            plainSum[i] += l; plainSq[i] += l * l; plainCount[i] += 1
        }
        frameCount += 1
        if frameCount <= Self.warmupFrames {
            warmup.append((warped, luma, frameWeight))
            if frameCount == Self.warmupFrames { seedFromWarmup(noise: noise) }
            return
        }
        for i in 0..<(width * height) {
            let l = luma.pixels[i]
            guard l.isFinite else { continue }
            var w = frameWeight
            if skyW[i] > 0 {
                let wr = Float(weighting.weight(value: Double(l), mean: Double(skyMean[i]), noise: noise))
                if wr < 0.05 {
                    skyRejections[i] += 1
                    if skyRejections[i] >= Float(weighting.resetAfter), Double(skyW[i]) < weighting.resetMaxWeight {
                        skyR[i] = warped.r[i] * frameWeight; skyG[i] = warped.g[i] * frameWeight
                        skyB[i] = warped.b[i] * frameWeight; skyW[i] = frameWeight
                        skyMean[i] = l; skyM2[i] = 0; skyRejections[i] = 0
                    }
                    continue
                }
                skyRejections[i] = 0
                w *= wr
            }
            accumulateSky(i, warped.r[i], warped.g[i], warped.b[i], l, w)
        }
    }

    @inline(__always)
    private func accumulateSky(_ i: Int, _ r: Float, _ g: Float, _ b: Float, _ l: Float, _ w: Float) {
        let wNew = skyW[i] + w
        guard wNew > 0 else { return }
        let delta = l - skyMean[i]
        let mean = skyMean[i] + (w / wNew) * delta
        skyM2[i] += w * delta * (l - mean)
        skyMean[i] = mean
        skyR[i] += w * r; skyG[i] += w * g; skyB[i] += w * b
        skyW[i] = wNew
    }

    private func seedFromWarmup(noise: NoiseModel) {
        for i in 0..<(width * height) {
            let valid = warmup.filter { $0.1.pixels[i].isFinite }
            guard !valid.isEmpty else { continue }
            if valid.count < 3 {
                for f in valid { accumulateSky(i, f.0.r[i], f.0.g[i], f.0.b[i], f.1.pixels[i], f.2) }
                continue
            }
            let lumas = valid.map { $0.1.pixels[i] }.sorted()
            let med = Double(lumas[1])
            for f in valid {
                let l = f.1.pixels[i]
                let w = f.2 * Float(weighting.weight(value: Double(l), mean: med, noise: noise))
                accumulateSky(i, f.0.r[i], f.0.g[i], f.0.b[i], l, w)
            }
        }
        warmup.removeAll()
    }

    private func accumulateForeground(_ frame: RGBImage) {
        let n = Float(frameCount + 1)
        for i in 0..<(width * height) {
            let l = (frame.r[i] + 2 * frame.g[i] + frame.b[i]) * 0.25
            let delta = l - fgMean[i]
            fgMean[i] += delta / n
            fgM2[i] += delta * (l - fgMean[i])
            fgR[i] += frame.r[i]; fgG[i] += frame.g[i]; fgB[i] += frame.b[i]
        }
    }

    public func result() -> StackResult {
        if !warmup.isEmpty { seedFromWarmup(noise: lastNoise) }
        let count = width * height
        var sky = RGBImage(width: width, height: height)
        var skyVar = PlanarImage(width: width, height: height, repeating: .greatestFiniteMagnitude)
        for i in 0..<count where skyW[i] > 0 {
            sky.r[i] = skyR[i] / skyW[i]; sky.g[i] = skyG[i] / skyW[i]; sky.b[i] = skyB[i] / skyW[i]
            skyVar.pixels[i] = skyM2[i] / skyW[i]
        }
        let n = Float(max(frameCount, 1))
        var fg = RGBImage(width: width, height: height)
        var fgVar = PlanarImage(width: width, height: height)
        for i in 0..<count {
            fg.r[i] = fgR[i] / n; fg.g[i] = fgG[i] / n; fg.b[i] = fgB[i] / n
            fgVar.pixels[i] = fgM2[i] / n
        }
        var plainMean = PlanarImage(width: width, height: height, repeating: .nan)
        var plainVar = PlanarImage(width: width, height: height, repeating: .nan)
        for i in 0..<count where plainCount[i] > 0 {
            let m = plainSum[i] / plainCount[i]
            plainMean.pixels[i] = m
            plainVar.pixels[i] = max(plainSq[i] / plainCount[i] - m * m, 0)
        }
        return StackResult(sky: sky, skyWeight: PlanarImage(width: width, height: height, pixels: skyW),
                           skyVariance: skyVar, foreground: fg, foregroundVariance: fgVar, frameCount: frameCount,
                           skyPlainMean: plainMean, skyPlainVariance: plainVar)
    }
}
