import AstralCore
import Foundation
import simd

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func gaussian() -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &self), 1e-300)
        let u2 = Double.random(in: 0..<1, using: &self)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// Renders frames of a fixed camera watching a rotating sky over a static foreground.
struct SyntheticSky {
    var intrinsics: CameraIntrinsics
    var pole: SIMD3<Double>
    var angularRate: Double
    var stars: [(direction: SIMD3<Double>, flux: Double)] = []
    var psfSigma = 1.0
    var skyBackground = 0.02
    var horizonY: Int?
    var groundLevel = 0.012
    var groundLights: [(position: SIMD2<Double>, flux: Double)] = []
    var noise = NoiseModel(lambdaS: 1e-5, lambdaR: 4e-6, relativeModelError: 0)

    static func random(intrinsics: CameraIntrinsics, pole: SIMD3<Double>, angularRate: Double,
                       count: Int, seed: UInt64) -> SyntheticSky {
        var rng = SplitMix64(seed: seed)
        var sky = SyntheticSky(intrinsics: intrinsics, pole: simd_normalize(pole), angularRate: angularRate)
        let w = Double(intrinsics.width), h = Double(intrinsics.height)
        for _ in 0..<count {
            let p = SIMD2(Double.random(in: -0.6 * w...1.6 * w, using: &rng), Double.random(in: -0.6 * h...1.6 * h, using: &rng))
            let flux = exp(Double.random(in: log(0.12)...log(3.0), using: &rng))
            sky.stars.append((intrinsics.ray(through: p), flux))
        }
        return sky
    }

    /// Ground-truth image position of star `index` at time `t`.
    func position(of index: Int, at t: Double) -> SIMD2<Double>? {
        intrinsics.project(rotationMatrix(axis: pole, angle: -angularRate * t) * stars[index].direction)
    }

    func render(time: Double, exposure: Double, rng: inout SplitMix64,
                satellite: (SIMD2<Double>, SIMD2<Double>)? = nil, addNoise: Bool = true) -> RGBImage {
        let w = intrinsics.width, h = intrinsics.height
        var plane = [Double](repeating: skyBackground, count: w * h)
        let substeps = 5
        let radius = Int((4 * psfSigma).rounded(.up))
        func stamp(_ p: SIMD2<Double>, _ flux: Double) {
            let cx = Int(p.x.rounded()), cy = Int(p.y.rounded())
            let norm = flux / (2 * .pi * psfSigma * psfSigma)
            let y0 = max(0, cy - radius), y1 = min(h - 1, cy + radius)
            let x0 = max(0, cx - radius), x1 = min(w - 1, cx + radius)
            guard y0 <= y1, x0 <= x1 else { return }
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = Double(x) - p.x, dy = Double(y) - p.y
                    plane[y * w + x] += norm * exp(-(dx * dx + dy * dy) / (2 * psfSigma * psfSigma))
                }
            }
        }
        for s in stars {
            for j in 0..<substeps {
                let t = time + exposure * (Double(j) + 0.5) / Double(substeps)
                let d = rotationMatrix(axis: pole, angle: -angularRate * t) * s.direction
                guard let p = intrinsics.project(d), p.x > -10, p.y > -10, p.x < Double(w + 10), p.y < Double(h + 10) else { continue }
                stamp(p, s.flux / Double(substeps))
            }
        }
        if let (a, b) = satellite {
            let steps = Int(simd_distance(a, b) * 2)
            for k in 0...steps { stamp(a + (b - a) * Double(k) / Double(steps), 0.5 / 2) }
        }
        if let horizonY {
            for y in horizonY..<h {
                for x in 0..<w {
                    plane[y * w + x] = groundLevel + 0.004 * sin(Double(x) / 7) * cos(Double(y) / 5)
                }
            }
            for light in groundLights { stamp(light.position, light.flux) }
        }
        var image = RGBImage(width: w, height: h)
        for i in 0..<(w * h) {
            let v = plane[i]
            let sigma = noise.variance(at: v).squareRoot()
            image.r[i] = Float(v + (addNoise ? sigma * rng.gaussian() : 0))
            image.g[i] = Float(v + (addNoise ? sigma * rng.gaussian() : 0))
            image.b[i] = Float(v + (addNoise ? sigma * rng.gaussian() : 0))
        }
        return image
    }
}

func angleBetween(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    acos(min(max(simd_dot(simd_normalize(a), simd_normalize(b)), -1), 1)) * 180 / .pi
}
