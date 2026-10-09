import Foundation
import simd

public struct StarPair: Sendable, Equatable {
    /// Undistorted position at the reference epoch.
    public var reference: SIMD2<Double>
    /// Undistorted position in the frame taken `dt` seconds later.
    public var current: SIMD2<Double>

    public init(reference: SIMD2<Double>, current: SIMD2<Double>) {
        self.reference = reference
        self.current = current
    }
}

public struct PoleObservation: Sendable {
    public var dt: Double
    public var pairs: [StarPair]

    public init(dt: Double, pairs: [StarPair]) {
        self.dt = dt
        self.pairs = pairs
    }
}

/// The celestial pole stands at an altitude equal to the latitude φ: with "up" known from gravity,
/// p · up = sin φ – exact, and independent of the compass (which reported ±89° on the fourth night).
/// Short wide-angle baselines cannot tell (pₓ, p_y, p_z) from (pₓ, p_y, −p_z) by image motion alone;
/// this constraint removes that ambiguity.
public struct PoleElevationConstraint: Sendable {
    /// Unit "up" in the camera frame.
    public var up: SIMD3<Double>
    public var sinLatitude: Double
    /// Residual weight in pixels per unit of (p · up − sin φ): ≈ 5 px per degree.
    public var weight: Double = 300
    /// Coarse search ignores axes further than this from the constraint cone.
    public var searchTolerance: Double = sin(10 * Double.pi / 180)

    public init(up: SIMD3<Double>, latitudeDegrees: Double) {
        self.up = simd_normalize(up)
        self.sinLatitude = sin(latitudeDegrees * .pi / 180)
    }

    func violation(_ pole: SIMD3<Double>) -> Double {
        simd_dot(simd_normalize(pole), up) - sinLatitude
    }
}

public struct PoleFitResult: Sendable {
    public var pole: SIMD3<Double>
    public var focalScale: Double
    /// RMS residual (px) over inliers.
    public var rms: Double
    public var inlierCount: Int
    public var pairCount: Int
}

/// Global estimation of the celestial rotation axis in the camera frame from star correspondences
/// across all frames, with the angular rate fixed to the sidereal value:
///
///     min_{p ∈ S², s}  Σ_k Σ_i ρ( ‖ π(K_s · R_p(−ω·Δt_k) · K_s⁻¹ · u_i,ref) − u_i,k ‖ )
///
/// ρ – Huber loss (IRLS), optimised with Levenberg–Marquardt on the tangent plane of S².
/// A Fibonacci-sphere coarse search removes the dependence on the (compass-based) prior.
public struct PoleFitter: Sendable {
    public var intrinsics: CameraIntrinsics
    public var angularRate: Double
    public var huberDelta: Double = 1.0
    public var inlierThreshold: Double = 4.0
    public var elevation: PoleElevationConstraint?

    public init(intrinsics: CameraIntrinsics, angularRate: Double = Sidereal.angularRate) {
        self.intrinsics = intrinsics
        self.angularRate = angularRate
    }

    public func homography(dt: Double, pole: SIMD3<Double>, focalScale: Double = 1) -> Homography {
        let k = intrinsics.withFocalScale(focalScale)
        return Homography(k.matrix * rotationMatrix(axis: pole, angle: -angularRate * dt) * k.inverseMatrix)
    }

    /// Residual vectors (predicted − observed) for every pair, in observation order.
    func residuals(pole: SIMD3<Double>, focalScale: Double, observations: [PoleObservation]) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = []
        out.reserveCapacity(observations.reduce(0) { $0 + $1.pairs.count })
        for obs in observations {
            let h = homography(dt: obs.dt, pole: pole, focalScale: focalScale)
            for pair in obs.pairs {
                if let p = h.apply(pair.reference) {
                    out.append(p - pair.current)
                } else {
                    out.append(SIMD2(1e3, 1e3))
                }
            }
        }
        return out
    }

    /// Pair residuals plus the elevation residual (when constrained); used for the cost, not the RMS.
    func costResiduals(pole: SIMD3<Double>, focalScale: Double, observations: [PoleObservation]) -> [SIMD2<Double>] {
        var r = residuals(pole: pole, focalScale: focalScale, observations: observations)
        if let elevation { r.append(SIMD2(elevation.weight * elevation.violation(pole), 0)) }
        return r
    }

    func huberCost(_ r: [SIMD2<Double>]) -> Double {
        var c = 0.0
        for v in r {
            let n = simd_length(v)
            c += n <= huberDelta ? n * n : 2 * huberDelta * n - huberDelta * huberDelta
        }
        return c
    }

    func summary(pole: SIMD3<Double>, focalScale: Double, observations: [PoleObservation]) -> PoleFitResult {
        let r = residuals(pole: pole, focalScale: focalScale, observations: observations)
        var sum = 0.0, count = 0
        for v in r {
            let d2 = simd_length_squared(v)
            if d2 < inlierThreshold * inlierThreshold { sum += d2; count += 1 }
        }
        return PoleFitResult(pole: pole, focalScale: focalScale,
                             rms: count > 0 ? (sum / Double(count)).squareRoot() : .infinity,
                             inlierCount: count, pairCount: r.count)
    }

    /// Exhaustive search over a Fibonacci lattice of candidate axes (both hemispheres) with a
    /// truncated quadratic cost on a subset of pairs.
    public func coarseSearch(observations: [PoleObservation], samples: Int = 4000, maxPairs: Int = 500) -> SIMD3<Double>? {
        let total = observations.reduce(0) { $0 + $1.pairs.count }
        guard total > 0 else { return nil }
        let step = max(1, total / maxPairs)
        var subset: [PoleObservation] = []
        var counter = 0
        for obs in observations {
            var pairs: [StarPair] = []
            for p in obs.pairs {
                if counter % step == 0 { pairs.append(p) }
                counter += 1
            }
            if !pairs.isEmpty { subset.append(PoleObservation(dt: obs.dt, pairs: pairs)) }
        }
        let cap = 9 * huberDelta * huberDelta
        var best: SIMD3<Double>?
        var bestCost = Double.infinity
        let golden = Double.pi * (3 - 5.0.squareRoot())
        for i in 0..<samples {
            let z = 1 - 2 * (Double(i) + 0.5) / Double(samples)
            let rho = (1 - z * z).squareRoot()
            let theta = golden * Double(i)
            let p = SIMD3(rho * cos(theta), rho * sin(theta), z)
            if let elevation, abs(elevation.violation(p)) > elevation.searchTolerance { continue }
            var cost = 0.0
            for v in residuals(pole: p, focalScale: 1, observations: subset) {
                cost += min(simd_length_squared(v), cap)
                if cost >= bestCost { break }
            }
            if cost < bestCost { bestCost = cost; best = p }
        }
        return best
    }

    public func refine(pole initialPole: SIMD3<Double>, focalScale initialScale: Double = 1,
                       fitFocalScale: Bool, observations: [PoleObservation], iterations: Int = 40) -> PoleFitResult {
        var pole = simd_normalize(initialPole)
        var logScale = log(initialScale)
        let n = fitFocalScale ? 3 : 2
        var lambda = 1e-3

        func evaluate(_ base: SIMD3<Double>, _ e1: SIMD3<Double>, _ e2: SIMD3<Double>, _ x: [Double], _ ls: Double)
            -> (SIMD3<Double>, Double, [SIMD2<Double>]) {
            let p = simd_normalize(base + x[0] * e1 + x[1] * e2)
            let s = exp(n == 3 ? ls + x[2] : ls)
            return (p, s, costResiduals(pole: p, focalScale: s, observations: observations))
        }

        var current = costResiduals(pole: pole, focalScale: exp(logScale), observations: observations)
        var currentCost = huberCost(current)

        for _ in 0..<iterations {
            let helper = abs(pole.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
            let e1 = simd_normalize(simd_cross(pole, helper))
            let e2 = simd_cross(pole, e1)

            // IRLS weights for the Huber loss.
            let weights = current.map { v -> Double in
                let d = simd_length(v)
                return d <= huberDelta ? 1 : huberDelta / d
            }
            // Forward-difference Jacobian.
            let h = 1e-7
            var columns: [[SIMD2<Double>]] = []
            for j in 0..<n {
                var x = [Double](repeating: 0, count: 3)
                x[j] = h
                let (_, _, r) = evaluate(pole, e1, e2, x, logScale)
                columns.append(zip(r, current).map { ($0 - $1) / h })
            }
            var a = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var g = [Double](repeating: 0, count: n)
            for i in 0..<current.count {
                let w = weights[i]
                for p in 0..<n {
                    g[p] += w * simd_dot(columns[p][i], current[i])
                    for q in p..<n { a[p][q] += w * simd_dot(columns[p][i], columns[q][i]) }
                }
            }
            for p in 0..<n { for q in 0..<p { a[p][q] = a[q][p] } }

            var improved = false
            while lambda < 1e12 {
                var damped = a
                for p in 0..<n { damped[p][p] += lambda * max(a[p][p], 1e-12) }
                guard let delta = solveLinearSystem(damped, g.map { -$0 }) else { lambda *= 10; continue }
                var x = delta
                while x.count < 3 { x.append(0) }
                let (p, s, r) = evaluate(pole, e1, e2, x, logScale)
                let cost = huberCost(r)
                if cost < currentCost {
                    pole = p
                    logScale = log(s)
                    current = r
                    let gain = currentCost - cost
                    currentCost = cost
                    lambda = max(lambda / 10, 1e-12)
                    improved = true
                    if gain < 1e-10 * max(cost, 1) || delta.reduce(0, { $0 + $1 * $1 }) < 1e-24 { return summary(pole: pole, focalScale: s, observations: observations) }
                    break
                }
                lambda *= 10
            }
            if !improved { break }
        }
        return summary(pole: pole, focalScale: exp(logScale), observations: observations)
    }

    /// Full fit: coarse search + LM, plus LM from the prior (sensors or previous fit); keeps the better.
    public func fit(observations: [PoleObservation], prior: SIMD3<Double>?, focalScale: Double = 1,
                    fitFocalScale: Bool = false, runCoarseSearch: Bool = true) -> PoleFitResult? {
        guard observations.contains(where: { !$0.pairs.isEmpty }) else { return nil }
        var candidates: [PoleFitResult] = []
        if let prior {
            candidates.append(refine(pole: prior, focalScale: focalScale, fitFocalScale: fitFocalScale, observations: observations))
        }
        if runCoarseSearch || prior == nil, let seed = coarseSearch(observations: observations) {
            candidates.append(refine(pole: seed, focalScale: focalScale, fitFocalScale: fitFocalScale, observations: observations))
        }
        return candidates.max { a, b in
            if a.inlierCount != b.inlierCount { return a.inlierCount < b.inlierCount }
            return a.rms > b.rms
        }
    }
}

public extension Array where Element == PoleObservation {
    /// Drops scenery detected as "stars" (street lights, lit windows): points that stay put while the
    /// sky has visibly moved. On the fourth night such lights pulled short fits towards "no rotation".
    func removingStaticPoints(minimumSkyMotion: Double = 3, tolerance: Double = 1, minimumVotes: Int = 2) -> [PoleObservation] {
        func key(_ p: SIMD2<Double>) -> SIMD2<Int32> { SIMD2(Int32((p.x * 4).rounded()), Int32((p.y * 4).rounded())) }
        var votes: [SIMD2<Int32>: Int] = [:]
        for obs in self {
            let moves = obs.pairs.map { simd_distance($0.current, $0.reference) }.sorted()
            guard !moves.isEmpty, moves[moves.count / 2] > minimumSkyMotion else { continue }
            for pair in obs.pairs where simd_distance(pair.current, pair.reference) < tolerance {
                votes[key(pair.reference), default: 0] += 1
            }
        }
        let fixed = Set(votes.filter { $0.value >= minimumVotes }.keys)
        guard !fixed.isEmpty else { return self }
        return map { PoleObservation(dt: $0.dt, pairs: $0.pairs.filter { !fixed.contains(key($0.reference)) }) }
    }
}
