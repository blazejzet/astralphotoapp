import Accelerate
import Foundation
import simd

// MARK: - Sky / foreground mask

/// Direction of gravity in the sensor-native buffer (from the EXIF orientation of the session).
public enum ImageDirection: Sendable, Equatable {
    case down    // +y
    case up      // −y
    case right   // +x
    case left    // −x

    public init?(exifOrientation: UInt32) {
        switch exifOrientation {
        case 1: self = .down
        case 3: self = .up
        case 6: self = .right
        case 8: self = .left
        default: return nil
        }
    }
}

/// Apple exposes no third-party sky matte, so the mask comes from the physics of the two stacks:
/// sky pixels are temporally stable when registered (var_sky < var_fg), static scenery when not.
/// Evidence (positive = sky, negative = ground, ≈ 0 in featureless regions):
/// * temporal: log(var_fg / var_sky) – weakened in practice because robust weights keep outliers
///   (moving scenery in the registered stack) out of the variance;
/// * spatial: log(HF_sky / HF_fg), local high-frequency energy of the two *means* – stars are points in
///   the registered stack and trails in the static one, scenery is sharp only in the static one.
///   This is what found the treeline in the iPhone 17 Pro field data where the variance cue did not.
///
/// With a known gravity direction each column u is a sky band [t, h) between optional foreground at
/// the top (eaves, branches – a balcony on the third night) and the landscape at the bottom:
///     argmin_{t≤h}  Σ_{v∉[t,h)} max(s − τ, 0) + Σ_{v∈[t,h)} max(−s − τ, 0) + γ·(t + V − h)
/// solved in O(V) per column with a running minimum, then median-filtered along the horizon.
/// This fills dark, featureless landscape under a textured skyline; without a direction a smoothed
/// majority vote of sign(s) is used.
public struct SkyMaskBuilder: Sendable {
    /// Radii in pixels; nil → scaled with the image (≈ 0.4 % / 0.15 % of the short side).
    public var smoothingRadius: Int?
    public var featherRadius: Int?
    /// Ties (featureless regions) lean towards sky in the direction-free fallback.
    public var bias: Float = 0.05
    /// Dead zone for the horizon evidence (log variance ratio).
    public var evidenceThreshold: Float = 0.25
    /// Cost per pixel labelled ground: featureless areas stay sky unless edges argue otherwise.
    public var groundPenalty: Float = 0.02
    public var groundDirection: ImageDirection?
    /// Ground already identified during capture (sticky provisional mask, 1 = ground). Needed because
    /// once occluded sky samples are skipped, the ground region stops producing fresh evidence.
    public var groundPrior: PlanarImage?

    public init(groundDirection: ImageDirection? = nil, groundPrior: PlanarImage? = nil) {
        self.groundDirection = groundDirection
        self.groundPrior = groundPrior
    }

    /// Local high-frequency energy: box-averaged squared difference from a 3×3 mean.
    static func highFrequencyEnergy(_ image: PlanarImage, radius: Int) -> PlanarImage {
        let smooth = boxBlur(image, radius: 1)
        var detail = image
        for i in 0..<detail.pixels.count {
            let d = image.pixels[i] - smooth.pixels[i]
            detail.pixels[i] = d.isFinite ? d * d : 0
        }
        return boxBlur(detail, radius: radius)
    }

    public func build(from stack: StackResult) -> PlanarImage {
        let w = stack.sky.width, h = stack.sky.height
        guard stack.frameCount >= 4 else {
            return stack.skyWeight.map { $0 > 0 ? 1 : 0 }
        }
        let shortSide = min(w, h)
        let smoothingRadius = self.smoothingRadius ?? max(3, shortSide / 250)
        let featherRadius = self.featherRadius ?? max(1, shortSide / 700)
        let eps: Float = 1e-12
        let uncoveredScore: Float = groundDirection == nil ? -4 : 0
        let radiusHF = max(2, smoothingRadius / 2)
        let hfFg = Self.highFrequencyEnergy(stack.foreground.luminance, radius: radiusHF)
        // Noise floor: half the typical static-stack detail energy, so pure noise compares as a tie.
        let hfFloor = max(Statistics.median(Statistics.sample(hfFg, stride: 7)) * 0.5, 1e-14)
        func evidence(skyLuma: PlanarImage, skyVariance: PlanarImage) -> PlanarImage {
            let hfSky = Self.highFrequencyEnergy(skyLuma, radius: radiusHF)
            var e = PlanarImage(width: w, height: h)
            for i in 0..<(w * h) {
                let temporal = max(-4, min(4, log((stack.foregroundVariance.pixels[i] + eps) / (skyVariance.pixels[i] + eps))))
                let spatial = max(-4, min(4, log((hfSky.pixels[i] + hfFloor) / (hfFg.pixels[i] + hfFloor))))
                e.pixels[i] = max(-4, min(4, temporal + spatial))
            }
            return e
        }
        // Two sources: the robust stack (sees fast-moving scenery) and the unweighted early-window stack
        // (sees slowly drifting scenery that robust weights reject). Strong ground evidence from either
        // wins; otherwise the stronger sky evidence counts.
        let robust = evidence(skyLuma: stack.sky.luminance, skyVariance: stack.skyVariance)
        var plain: PlanarImage?
        if let pm = stack.skyPlainMean, let pv = stack.skyPlainVariance {
            plain = evidence(skyLuma: pm.map { $0.isFinite ? $0 : 0 }, skyVariance: pv.map { $0.isFinite ? $0 : 1 })
        }
        var score = PlanarImage(width: w, height: h)
        for i in 0..<(w * h) {
            if stack.skyWeight.pixels[i] <= 0 {
                score.pixels[i] = uncoveredScore
            } else {
                let a = robust.pixels[i]
                if let p = plain, stack.skyPlainMean?.pixels[i].isFinite == true {
                    let b = p.pixels[i]
                    score.pixels[i] = min(a, b) < -0.5 ? min(a, b) : max(a, b)
                } else {
                    score.pixels[i] = a
                }
            }
            if let prior = groundPrior, prior.pixels[i] >= 0.5 { score.pixels[i] = min(score.pixels[i], 0) - 0.3 }
        }
        let smoothed = boxBlur(score, radius: smoothingRadius)
        var alpha: PlanarImage
        if let groundDirection {
            alpha = horizonMask(smoothed, direction: groundDirection, feather: Float(max(featherRadius, 1)))
        } else {
            let binary = smoothed.map { $0 > -bias ? 1 : 0 }
            let majority = boxBlur(binary, radius: smoothingRadius).map { $0 >= 0.5 ? 1 : 0 }
            alpha = boxBlur(majority, radius: featherRadius)
        }
        for i in 0..<(w * h) where stack.skyWeight.pixels[i] <= 0 { alpha.pixels[i] = 0 }
        return alpha
    }

    func horizonMask(_ score: PlanarImage, direction: ImageDirection, feather: Float) -> PlanarImage {
        let w = score.width, h = score.height
        let vertical = direction == .down || direction == .up
        let lengthU = vertical ? w : h, lengthV = vertical ? h : w
        // (u along the horizon, v along gravity) → buffer index.
        func index(_ u: Int, _ v: Int) -> Int {
            switch direction {
            case .down: v * w + u
            case .up: (h - 1 - v) * w + u
            case .right: u * w + v
            case .left: u * w + (w - 1 - v)
            }
        }
        let tau = evidenceThreshold, gamma = groundPenalty
        var top = [Int](repeating: 0, count: lengthU)
        var bottom = [Int](repeating: lengthV, count: lengthU)
        var pos = [Float](repeating: 0, count: lengthV + 1)   // Σ sky evidence above v
        var neg = [Float](repeating: 0, count: lengthV + 1)   // Σ ground evidence above v
        for u in 0..<lengthU {
            for v in 0..<lengthV {
                let s = score.pixels[index(u, v)]
                pos[v + 1] = pos[v] + max(s - tau, 0)
                neg[v + 1] = neg[v] + max(-s - tau, 0)
            }
            // Sky band [t, h): cost = P(t) + (N(h) − N(t)) + (P(V) − P(h)) + γ·(t + V − h)
            //                       = B(t) − B(h) + const,  B(x) = P(x) − N(x) + γ·x.
            var minB = Float.greatestFiniteMagnitude, minT = 0
            var bestCost = Float.greatestFiniteMagnitude, bestT = 0, bestH = lengthV
            for v in 0...lengthV {
                let b = pos[v] - neg[v] + gamma * Float(v)
                if b < minB { minB = b; minT = v }          // ties → smaller t (more sky)
                let cost = minB - b
                if cost <= bestCost { bestCost = cost; bestT = minT; bestH = v }   // ties → larger h
            }
            top[u] = bestT
            bottom[u] = bestH
        }
        // Median filter along the horizon removes single-column spikes (a star, a hot column).
        let half = max(1, lengthU / 120)
        func medianFiltered(_ a: [Int]) -> [Int] {
            (0..<lengthU).map { u in
                let window = a[max(0, u - half)...min(lengthU - 1, u + half)].sorted()
                return window[window.count / 2]
            }
        }
        let t = medianFiltered(top), hz = medianFiltered(bottom)
        var alpha = PlanarImage(width: w, height: h)
        for u in 0..<lengthU {
            let tv = Float(t[u]), hv = Float(hz[u])
            for v in 0..<lengthV {
                let fv = Float(v) + 0.5
                let below = min(max((hv - fv) / feather + 0.5, 0), 1)
                let above = t[u] == 0 ? 1 : min(max((fv - tv) / feather + 0.5, 0), 1)
                alpha.pixels[index(u, v)] = min(below, above)
            }
        }
        return alpha
    }

    /// Provisional ground mask (1 = ground, transition counted as ground) used during capture to keep
    /// occluded samples out of the sky stack. nil until there are enough frames for a stable decision.
    public func occlusionMask(from stack: StackResult, minimumFrames: Int = 10) -> PlanarImage? {
        guard stack.frameCount >= minimumFrames else { return nil }
        let alpha = build(from: stack)
        let coveredSky = zip(alpha.pixels, stack.skyWeight.pixels).filter { $0.1 > 0 }.map(\.0)
        guard coveredSky.contains(where: { $0 < 0.9 }) else { return nil }
        var mask = alpha
        for i in 0..<mask.pixels.count {
            // Uncovered pixels are not evidence of ground.
            mask.pixels[i] = stack.skyWeight.pixels[i] <= 0 ? 0 : (alpha.pixels[i] < 0.9 ? 1 : 0)
        }
        return mask
    }
}

// MARK: - Background (light pollution) gradient

public enum GradientRemoval {
    /// Fits a smooth background (quadratic surface + radial r⁴/r⁶ terms) through κσ-clipped cell medians
    /// inside the mask, rejecting outlier cells, and returns the model.
    public static func fitBackground(_ plane: PlanarImage, mask: PlanarImage, gridX: Int = 16, gridY: Int = 12) -> PlanarImage? {
        let w = plane.width, h = plane.height
        var xs: [Double] = [], ys: [Double] = [], vs: [Double] = []
        let cw = max(1, w / gridX), ch = max(1, h / gridY)
        for gy in 0..<gridY {
            for gx in 0..<gridX {
                var values: [Float] = []
                var y = gy * ch
                while y < min(h, (gy + 1) * ch) {
                    var x = gx * cw
                    while x < min(w, (gx + 1) * cw) {
                        let i = y * w + x
                        if mask.pixels[i] >= 0.9 { values.append(plane.pixels[i]) }
                        x += 2
                    }
                    y += 2
                }
                guard values.count >= max(16, cw * ch / 16) else { continue }
                let st = Statistics.sigmaClipped(values, kappa: 2, iterations: 5)
                xs.append((Double(gx) + 0.5) / Double(gridX) * 2 - 1)
                ys.append((Double(gy) + 0.5) / Double(gridY) * 2 - 1)
                vs.append(Double(st.median))
            }
        }
        // Quadratic surface (light pollution) + radial r⁴, r⁶ about the optical centre (what is left of
        // lens falloff – a parabola alone leaves a bright centre and a dark ring, seen on the 17 Pro).
        let diag = (Double(w * w + h * h)).squareRoot()
        let ax = Double(w) / diag, ay = Double(h) / diag
        func terms(_ x: Double, _ y: Double) -> [Double] {
            let r2 = (x * ax) * (x * ax) + (y * ay) * (y * ay)
            return [1, x, y, x * x, x * y, y * y, r2 * r2, r2 * r2 * r2]
        }
        let n = 8
        guard vs.count >= 3 * n else { return nil }
        func solve(_ idx: [Int]) -> [Double]? {
            var a = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var b = [Double](repeating: 0, count: n)
            for k in idx {
                let t = terms(xs[k], ys[k])
                for p in 0..<n {
                    b[p] += t[p] * vs[k]
                    for q in 0..<n { a[p][q] += t[p] * t[q] }
                }
            }
            for p in 0..<n { a[p][p] += 1e-12 }
            return solveLinearSystem(a, b)
        }
        func evaluate(_ c: [Double], _ x: Double, _ y: Double) -> Double {
            zip(c, terms(x, y)).reduce(0) { $0 + $1.0 * $1.1 }
        }
        guard var c = solve(Array(vs.indices)) else { return nil }
        // Cells off the smooth model (Milky Way, nebulae, lit clouds) must not shape the background.
        let residuals = vs.indices.map { vs[$0] - evaluate(c, xs[$0], ys[$0]) }
        let mad = median(residuals.map(abs)) * 1.4826
        let keep = vs.indices.filter { abs(residuals[$0]) <= max(3 * mad, 1e-9) }
        if keep.count >= 3 * n, let refined = solve(keep) { c = refined }
        var model = PlanarImage(width: w, height: h)
        for y in 0..<h {
            let ny = (Double(y) + 0.5) / Double(h) * 2 - 1
            for x in 0..<w {
                let nx = (Double(x) + 0.5) / Double(w) * 2 - 1
                model.pixels[y * w + x] = Float(evaluate(c, nx, ny))
            }
        }
        return model
    }

    /// Per-channel additive correction, pedestal − model (the pedestal is the model's median), fitted inside
    /// the mask. Outside it the correction is clamped to the range it takes inside, so the foreground can get
    /// the same smooth shift (no step at the mask edge) without the extrapolated polynomial running away.
    public static func correction(for image: RGBImage, mask: PlanarImage) -> [PlanarImage?] {
        (0..<3).map { c in
            guard let model = fitBackground(image.channel(c), mask: mask) else { return nil }
            let pedestal = Statistics.median(Statistics.sample(model, stride: 8, mask: mask))
            var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
            for i in 0..<model.pixels.count where mask.pixels[i] >= 0.9 {
                lo = min(lo, model.pixels[i]); hi = max(hi, model.pixels[i])
            }
            guard lo <= hi else { return nil }
            return model.map { pedestal - min(max($0, lo), hi) }
        }
    }

    public static func apply(_ correction: [PlanarImage?], to image: inout RGBImage) {
        for (c, field) in correction.enumerated() {
            guard let field else { continue }
            var plane = image.channel(c)
            for i in 0..<plane.pixels.count { plane.pixels[i] += field.pixels[i] }
            image.setChannel(c, plane)
        }
    }

    /// Subtracts the per-channel model and restores a flat pedestal.
    public static func apply(_ image: inout RGBImage, mask: PlanarImage) {
        apply(correction(for: image, mask: mask), to: &image)
    }
}

// MARK: - PSF and deconvolution (inverting J = M ⊛ I)

public enum PSFEstimator {
    /// Median-combined, sub-pixel-centred stamps of isolated, unsaturated stars.
    public static func estimate(luma: PlanarImage, stars: [Star], background: Float,
                                saturation: Float = 0.8, maxStars: Int = 60) -> PlanarImage? {
        let usable = stars.filter { $0.peak > 0 && Float($0.peak) + background < saturation && $0.fwhm > 0.3 }
        guard usable.count >= 5 else { return nil }
        let fwhm = median(usable.map(\.fwhm))
        let radius = min(max(Int((2 * fwhm).rounded(.up)), 3), 7)
        let size = 2 * radius + 1
        var stamps: [[Float]] = []
        for (idx, s) in usable.enumerated() where stamps.count < maxStars {
            // Isolation: no other detected star inside 2R.
            let isolated = usable.enumerated().allSatisfy { j, o in
                j == idx || simd_distance(o.position, s.position) > Double(2 * radius)
            }
            guard isolated else { continue }
            var stamp = [Float](repeating: 0, count: size * size)
            var sum: Float = 0
            var ok = true
            for dy in -radius...radius {
                for dx in -radius...radius {
                    guard let v = luma.bilinear(s.position + SIMD2(Double(dx), Double(dy))) else { ok = false; break }
                    let val = max(v - background, 0)
                    stamp[(dy + radius) * size + dx + radius] = val
                    sum += val
                }
                if !ok { break }
            }
            guard ok, sum > 0 else { continue }
            stamps.append(stamp.map { $0 / sum })
        }
        guard stamps.count >= 5 else { return nil }
        var psf = [Float](repeating: 0, count: size * size)
        for k in 0..<psf.count { psf[k] = Statistics.median(stamps.map { $0[k] }) }
        let total = psf.reduce(0, +)
        guard total > 0 else { return nil }
        return PlanarImage(width: size, height: size, pixels: psf.map { $0 / total })
    }
}

public enum Deconvolution {
    static func convolve(_ image: PlanarImage, _ kernel: PlanarImage) -> PlanarImage {
        var src = image.pixels
        var dst = [Float](repeating: 0, count: src.count)
        src.withUnsafeMutableBufferPointer { sp in
            dst.withUnsafeMutableBufferPointer { dp in
                kernel.pixels.withUnsafeBufferPointer { kp in
                    var s = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(image.height),
                                          width: vImagePixelCount(image.width), rowBytes: image.width * 4)
                    var d = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(image.height),
                                          width: vImagePixelCount(image.width), rowBytes: image.width * 4)
                    _ = vImageConvolve_PlanarF(&s, &d, nil, 0, 0, kp.baseAddress!,
                                               UInt32(kernel.height), UInt32(kernel.width), 0,
                                               vImage_Flags(kvImageEdgeExtend))
                }
            }
        }
        return PlanarImage(width: image.width, height: image.height, pixels: dst)
    }

    static func flipped(_ k: PlanarImage) -> PlanarImage {
        PlanarImage(width: k.width, height: k.height, pixels: Array(k.pixels.reversed()))
    }

    /// Richardson–Lucy (Richardson 1972; Lucy 1974) for J = a ⊛ I + b with Poisson noise:
    ///     I ← I ⊙ ( ã ⊛ ( J ⊘ (a ⊛ I + b) ) )
    /// Noise protection: the update is only kept where the signal exceeds the background by a few σ
    /// (soft mask), which plays the role of damping and avoids amplifying sky noise.
    public static func richardsonLucy(_ observed: PlanarImage, psf: PlanarImage, background: Float, noise: Float,
                                      iterations: Int = 15) -> PlanarImage {
        let eps: Float = 1e-9
        let flippedPSF = flipped(psf)
        var estimate = observed.map { max($0 - background, eps) }
        for _ in 0..<iterations {
            let blurred = convolve(estimate, psf)
            var ratio = PlanarImage(width: observed.width, height: observed.height)
            for i in 0..<ratio.pixels.count {
                let model = blurred.pixels[i] + background
                ratio.pixels[i] = min(max(observed.pixels[i] / max(model, eps), 0.2), 5)
            }
            let correction = convolve(ratio, flippedPSF)
            for i in 0..<estimate.pixels.count { estimate.pixels[i] *= correction.pixels[i] }
        }
        var out = observed
        let lo = 3 * noise, hi = 10 * noise
        for i in 0..<out.pixels.count {
            let signal = observed.pixels[i] - background
            let m = min(max((signal - lo) / max(hi - lo, eps), 0), 1)
            out.pixels[i] = m * (estimate.pixels[i] + background) + (1 - m) * observed.pixels[i]
        }
        return out
    }
}

// MARK: - Colour

public enum ColorCalibration {
    /// Per-channel offsets that equalise the sky background (light-pollution colour cast) to the luma background.
    public static func backgroundOffsets(_ image: RGBImage, mask: PlanarImage) -> SIMD3<Float> {
        let target = Statistics.backgroundAndNoise(image.luminance, mask: mask).background
        let bg = (0..<3).map { Statistics.backgroundAndNoise(image.channel($0), mask: mask).background }
        return SIMD3(target - bg[0], target - bg[1], target - bg[2])
    }

    public static func apply(offsets: SIMD3<Float>, to image: inout RGBImage) {
        for i in 0..<image.r.count {
            image.r[i] += offsets.x; image.g[i] += offsets.y; image.b[i] += offsets.z
        }
    }

    /// White balance so that the average star is neutral (aperture photometry on detected stars).
    public static func starGains(_ image: RGBImage, stars: [Star], background: Float) -> SIMD3<Float> {
        var flux = SIMD3<Double>(0, 0, 0)
        for s in stars.prefix(100) {
            let radius = max(2, Int((1.5 * s.fwhm).rounded(.up)))
            let cx = Int(s.position.x.rounded()), cy = Int(s.position.y.rounded())
            guard cx - radius >= 0, cy - radius >= 0, cx + radius < image.width, cy + radius < image.height else { continue }
            var f = SIMD3<Double>(0, 0, 0)
            for y in (cy - radius)...(cy + radius) {
                for x in (cx - radius)...(cx + radius) {
                    let i = y * image.width + x
                    f += SIMD3(Double(image.r[i] - background), Double(image.g[i] - background), Double(image.b[i] - background))
                }
            }
            if f.x > 0, f.y > 0, f.z > 0 { flux += f }
        }
        guard flux.x > 0, flux.y > 0, flux.z > 0 else { return SIMD3(1, 1, 1) }
        let clamp: (Double) -> Float = { Float(min(max($0, 0.25), 4)) }
        return SIMD3(clamp(flux.y / flux.x), 1, clamp(flux.y / flux.z))
    }

    public static func apply(gains: SIMD3<Float>, to image: inout RGBImage, background: Float) {
        for i in 0..<image.r.count {
            image.r[i] = (image.r[i] - background) * gains.x + background
            image.g[i] = (image.g[i] - background) * gains.y + background
            image.b[i] = (image.b[i] - background) * gains.z + background
        }
    }
}

// MARK: - Clipped highlights

public enum Highlights {
    /// Soft clipping weight from the *unprocessed* stack (1.0 = sensor white level): 0 below `start`,
    /// 1 at `full` and above, on the brightest channel.
    public static func clipping(_ raw: RGBImage, start: Float = 0.85, full: Float = 0.97) -> PlanarImage {
        var out = PlanarImage(width: raw.width, height: raw.height)
        for i in 0..<raw.r.count {
            let m = max(raw.r[i], max(raw.g[i], raw.b[i]))
            out.pixels[i] = min(max((m - start) / (full - start), 0), 1)
        }
        return out
    }

    /// Clipped pixels have lost their colour; channel gains (vignetting, white balance) would turn them
    /// magenta or green. Blends them towards neutral at their brightest channel.
    public static func neutralize(_ image: inout RGBImage, clipping: PlanarImage) {
        for i in 0..<image.r.count {
            let w = clipping.pixels[i]
            guard w > 0 else { continue }
            let m = max(image.r[i], max(image.g[i], image.b[i]))
            image.r[i] += w * (m - image.r[i]); image.g[i] += w * (m - image.g[i]); image.b[i] += w * (m - image.b[i])
        }
    }
}

// MARK: - Display stretch

/// Colour-preserving arcsinh stretch (Lupton et al. 2004, PASP 116, 133):
/// (R, G, B) ← (R, G, B) · F(I)/I,  I = (R + G + B)/3,  F(I) = asinh(I/β)/asinh(W/β).
public struct AsinhStretch: Sendable {
    public var black: Float
    public var white: Float
    public var beta: Float

    public init(black: Float, white: Float, beta: Float) {
        self.black = black
        self.white = max(white, black + 1e-6)
        self.beta = max(beta, 1e-9)
    }

    /// Chooses β so that the sky background lands at `backgroundLevel` of the output range.
    public static func automatic(luma: PlanarImage, mask: PlanarImage?, backgroundLevel: Float = 0.12,
                                 blackSigmas: Float = 2) -> AsinhStretch {
        let (bg, sigma) = Statistics.backgroundAndNoise(luma, mask: mask)
        let noise = max(sigma, 1e-7)
        let black = bg - blackSigmas * noise
        let stride = max(1, Int((Double(luma.pixels.count) / 300_000).squareRoot()))
        let white = max(Statistics.percentile(Statistics.sample(luma, stride: stride), 0.9995), bg + 20 * noise)
        let range = white - black
        let x = bg - black
        // F decreases monotonically in β; bisection in log-space.
        var lo: Float = 1e-9, hi: Float = range * 100
        for _ in 0..<60 {
            let mid = (lo * hi).squareRoot()
            let f = asinh(x / mid) / asinh(range / mid)
            if f > backgroundLevel { lo = mid } else { hi = mid }
        }
        return AsinhStretch(black: black, white: white, beta: (lo * hi).squareRoot())
    }

    public func apply(_ image: RGBImage) -> RGBImage {
        var out = RGBImage(width: image.width, height: image.height)
        let norm = asinh((white - black) / beta)
        for i in 0..<image.r.count {
            let r = max(image.r[i] - black, 0), g = max(image.g[i] - black, 0), b = max(image.b[i] - black, 0)
            let intensity = (r + g + b) / 3
            guard intensity > 0 else { continue }
            let scale = asinh(intensity / beta) / norm / intensity
            var o = SIMD3(r * scale, g * scale, b * scale)
            let m = max(o.x, max(o.y, o.z))
            if m > 1 { o /= m }
            out.r[i] = o.x; out.g[i] = o.y; out.b[i] = o.z
        }
        return out
    }
}
