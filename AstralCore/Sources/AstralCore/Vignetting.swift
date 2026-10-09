import Foundation

/// Radial lens falloff V(r) = 1 + a·r² + b·r⁴ + c·r⁶ per colour channel, r normalised by the half
/// diagonal around the image centre. Bayer RAW from the iPhone carries no lens-shading correction
/// (the DNG holds it as an opcode that only Apple's renderer applies), so stacks are vignetted.
public struct VignettingModel: Sendable {
    public var center: SIMD2<Double>
    public var normalisingRadius: Double
    /// (a, b, c) for R, G, B; nil = channel left uncorrected.
    public var coefficients: [SIMD3<Double>?]
    /// Largest radius with data; V is held constant beyond it (no polynomial blow-up in corners).
    public var maxDataRadius: Double

    public func falloff(channel: Int, x: Double, y: Double) -> Double {
        guard let k = coefficients[channel] else { return 1 }
        let dx = (x - center.x) / normalisingRadius, dy = (y - center.y) / normalisingRadius
        let r2 = min(dx * dx + dy * dy, maxDataRadius * maxDataRadius)
        return min(max(1 + k.x * r2 + k.y * r2 * r2 + k.z * r2 * r2 * r2, 0.15), 1.05)
    }

    /// Relative brightness at the frame corner (for the session log).
    public func cornerFalloff(channel: Int) -> Double {
        falloff(channel: channel, x: 0, y: 0)
    }
}

/// Post-filter for vignetting: the sky background is modelled as B(x, y) = P(x, y) · V(r), a plane P
/// (linear light-pollution gradient) times the radial falloff, fitted by alternating least squares to
/// κσ-clipped cell medians inside the sky mask, with outlier cells (Milky Way, light domes) rejected.
/// Dividing by V restores both the background and the brightness of stars near the edges.
public enum VignettingCorrection {
    public static func fit(_ image: RGBImage, mask: PlanarImage, gridX: Int = 32, gridY: Int = 24) -> VignettingModel? {
        let w = image.width, h = image.height
        let center = SIMD2(Double(w - 1) / 2, Double(h - 1) / 2)
        let norm = (center.x * center.x + center.y * center.y).squareRoot()
        func falloff(_ k: SIMD3<Double>, _ r: Double) -> Double {
            let r2 = r * r
            return 1 + k.x * r2 + k.y * r2 * r2 + k.z * r2 * r2 * r2
        }
        // The lens shape comes from luma (best S/N); a colour channel may only deviate a little from it
        // (lens colour shading). Independent per-channel fits gave 100 % / 17 % / 100 % on a noisy tele stack.
        guard let luma = fitPlane(image.luminance, mask: mask, center: center, norm: norm, gridX: gridX, gridY: gridY) else { return nil }
        var coefficients: [SIMD3<Double>?] = []
        for c in 0..<3 {
            if let ch = fitPlane(image.channel(c), mask: mask, center: center, norm: norm, gridX: gridX, gridY: gridY),
               abs(falloff(ch.k, luma.rMax) - falloff(luma.k, luma.rMax)) <= 0.12 {
                coefficients.append(ch.k)
            } else {
                coefficients.append(luma.k)
            }
        }
        return VignettingModel(center: center, normalisingRadius: norm, coefficients: coefficients, maxDataRadius: luma.rMax)
    }

    /// One plane: cell medians inside the mask → alternating fit with outlier-cell rejection.
    static func fitPlane(_ plane: PlanarImage, mask: PlanarImage, center: SIMD2<Double>, norm: Double,
                         gridX: Int, gridY: Int) -> (k: SIMD3<Double>, rMax: Double)? {
        let w = plane.width, h = plane.height
        let cw = max(2, w / gridX), ch = max(2, h / gridY)
        var xs: [Double] = [], ys: [Double] = [], vs: [Double] = []
        for gy in 0..<gridY {
            for gx in 0..<gridX {
                var values: [Float] = []
                var total = 0
                var y = gy * ch
                while y < min(h, (gy + 1) * ch) {
                    var x = gx * cw
                    while x < min(w, (gx + 1) * cw) {
                        total += 1
                        let i = y * w + x
                        if mask.pixels[i] >= 0.9, plane.pixels[i].isFinite { values.append(plane.pixels[i]) }
                        x += 2
                    }
                    y += 2
                }
                guard total > 0, values.count * 2 >= total else { continue }
                let st = Statistics.sigmaClipped(values, kappa: 2, iterations: 5)
                guard st.median > 0 else { continue }
                xs.append(((Double(gx) + 0.5) * Double(cw) - center.x) / norm)
                ys.append(((Double(gy) + 0.5) * Double(ch) - center.y) / norm)
                vs.append(Double(st.median))
            }
        }
        guard vs.count >= 30 else { return nil }
        let radii = zip(xs, ys).map { ($0 * $0 + $1 * $1).squareRoot() }
        guard let rMax = radii.max(), rMax >= 0.6 else { return nil }
        var keep = Array(vs.indices)
        var k = SIMD3<Double>(0, 0, 0)
        var p = [Double](repeating: 0, count: 3)
        for round in 0..<3 {
            (p, k) = alternatingFit(xs: keep.map { xs[$0] }, ys: keep.map { ys[$0] }, vs: keep.map { vs[$0] })
            guard round < 2 else { break }
            let residuals = vs.indices.map { i -> Double in
                let r2 = xs[i] * xs[i] + ys[i] * ys[i]
                let model = (p[0] + p[1] * xs[i] + p[2] * ys[i]) * (1 + k.x * r2 + k.y * r2 * r2 + k.z * r2 * r2 * r2)
                return vs[i] / max(model, 1e-12) - 1
            }
            let mad = median(residuals.map(abs)) * 1.4826
            let next = vs.indices.filter { abs(residuals[$0]) <= max(3 * mad, 0.01) }
            if next.count < 30 { break }
            keep = next
        }
        // Physical sanity: a lens only darkens towards the edge.
        let edge = 1 + k.x * rMax * rMax + k.y * pow(rMax, 4) + k.z * pow(rMax, 6)
        guard edge < 1.02, edge > 0.15 else { return nil }
        return (k, rMax)
    }

    /// Alternating least squares for v = (p0 + p1·x + p2·y) · (1 + a·r² + b·r⁴ + c·r⁶).
    static func alternatingFit(xs: [Double], ys: [Double], vs: [Double]) -> ([Double], SIMD3<Double>) {
        var k = SIMD3<Double>(0, 0, 0)
        var p: [Double] = [median(vs), 0, 0]
        for _ in 0..<25 {
            // Plane given V.
            var a = [[Double]](repeating: [0, 0, 0], count: 3), b = [Double](repeating: 0, count: 3)
            for i in vs.indices {
                let r2 = xs[i] * xs[i] + ys[i] * ys[i]
                let v = 1 + k.x * r2 + k.y * r2 * r2 + k.z * r2 * r2 * r2
                let f = [v, v * xs[i], v * ys[i]]
                for m in 0..<3 { b[m] += f[m] * vs[i]; for n in 0..<3 { a[m][n] += f[m] * f[n] } }
            }
            if let s = solveLinearSystem(a, b) { p = s }
            // Radial terms given the plane:  v − P = P·(a r² + b r⁴ + c r⁶).
            var a2 = [[Double]](repeating: [0, 0, 0], count: 3), b2 = [Double](repeating: 0, count: 3)
            for i in vs.indices {
                let r2 = xs[i] * xs[i] + ys[i] * ys[i]
                let pl = p[0] + p[1] * xs[i] + p[2] * ys[i]
                let f = [pl * r2, pl * r2 * r2, pl * r2 * r2 * r2]
                for m in 0..<3 { b2[m] += f[m] * (vs[i] - pl); for n in 0..<3 { a2[m][n] += f[m] * f[n] } }
            }
            for m in 0..<3 { a2[m][m] += 1e-9 }
            if let s = solveLinearSystem(a2, b2) { k = SIMD3(s[0], s[1], s[2]) }
        }
        return (p, k)
    }

    public static func apply(_ model: VignettingModel, to image: inout RGBImage) {
        let w = image.width, h = image.height
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                image.r[i] /= Float(model.falloff(channel: 0, x: Double(x), y: Double(y)))
                image.g[i] /= Float(model.falloff(channel: 1, x: Double(x), y: Double(y)))
                image.b[i] /= Float(model.falloff(channel: 2, x: Double(x), y: Double(y)))
            }
        }
    }
}
