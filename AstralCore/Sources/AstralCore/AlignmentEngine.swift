import Foundation
import simd

public struct FrameAlignment: Sendable {
    /// Undistorted reference-epoch pixels → undistorted pixels of this frame: G_k = C_k · H(Δt_k).
    public var homography: Homography
    public var dt: Double
    public var matchedStars: Int
    /// RMS of residuals after the per-frame rigid correction (px).
    public var rmsResidual: Double
    public var accepted: Bool
    public var isReference: Bool
    public var poleFitted: Bool
}

/// Per-frame registration driven by the physical model of the sky:
/// 1. predict catalogue positions with H(Δt) = K·R_p(−ωΔt)·K⁻¹ and the previous frame's drift,
/// 2. gate nearest-neighbour matches (fallback: triangle matching),
/// 3. absorb what the model does not explain (field rotation before the pole is fitted, OIS/tripod
///    drift, refraction) with a robust per-frame rigid correction C_k,
/// 4. periodically refit the pole globally over all stored observations.
public final class AlignmentEngine {
    public struct Configuration: Sendable {
        public var angularRate = Sidereal.angularRate
        public var minStarsForReference = 12
        public var minMatches = 8
        public var matchRadius = 4.0
        public var maxRMS = 1.5
        /// A pole fit worse than this is not trusted (a wrong pole accepted at 1.49 px trailed the stars).
        public var maxPoleFitRMS = 1.0
        public var refitEvery = 10
        /// Minimum time span (s) before the pole is identifiable enough to fit.
        public var minBaselineForFit = 20.0
        /// Time span (s) after which the focal scale is also fitted.
        public var fitFocalAfterBaseline = 300.0
        public var maxObservationFrames = 150
        public var maxPairsPerFrame = 40
        public var maxCatalogStars = 300
        public init() {}
    }

    public let configuration: Configuration
    public let distortion: LensDistortion?
    public private(set) var intrinsics: CameraIntrinsics
    public private(set) var pole: SIMD3<Double>?
    public private(set) var focalScale: Double = 1
    public private(set) var poleFitted = false
    public private(set) var lastFit: PoleFitResult?
    public private(set) var referenceTime: Double?
    public private(set) var catalog: [SIMD2<Double>] = []

    private var observations: [PoleObservation] = []
    private var lastCorrection = Homography.identity
    private var framesSinceFit = 0
    private let priorPole: SIMD3<Double>?
    public let poleElevation: PoleElevationConstraint?

    public init(intrinsics: CameraIntrinsics, distortion: LensDistortion?, priorPole: SIMD3<Double>?,
                poleElevation: PoleElevationConstraint? = nil, configuration: Configuration = .init()) {
        self.intrinsics = intrinsics
        self.distortion = distortion
        self.poleElevation = poleElevation
        self.priorPole = priorPole.map { simd_normalize($0) }
        self.pole = self.priorPole
        self.configuration = configuration
    }

    private var fitter: PoleFitter {
        var f = PoleFitter(intrinsics: intrinsics, angularRate: configuration.angularRate)
        f.elevation = poleElevation
        return f
    }

    /// Model-only warp for a time offset (identity until a pole is known).
    public func modelHomography(dt: Double) -> Homography {
        guard let pole else { return .identity }
        return fitter.homography(dt: dt, pole: pole, focalScale: focalScale)
    }

    public func undistort(_ p: SIMD2<Double>) -> SIMD2<Double> { distortion?.undistort(p) ?? p }

    public func process(stars: [Star], timestamp: Double) -> FrameAlignment {
        let points = stars.map { undistort($0.position) }

        guard let tRef = referenceTime else {
            guard points.count >= configuration.minStarsForReference else {
                return FrameAlignment(homography: .identity, dt: 0, matchedStars: 0, rmsResidual: .infinity,
                                      accepted: false, isReference: false, poleFitted: false)
            }
            referenceTime = timestamp
            catalog = Array(points.prefix(configuration.maxCatalogStars))
            return FrameAlignment(homography: .identity, dt: 0, matchedStars: points.count, rmsResidual: 0,
                                  accepted: true, isReference: true, poleFitted: poleFitted)
        }

        let dt = timestamp - tRef
        let model = modelHomography(dt: dt)
        var pairs = gatedMatches(points: points, prediction: lastCorrection * model,
                                 radius: configuration.matchRadius)

        if pairs.count < configuration.minMatches {
            // Lost track (start, clouds, bump): match catalogue to frame without a prior.
            if let tri = TriangleMatcher().match(source: catalog, target: points) {
                let viaTriangles = gatedMatches(points: points, predictor: { tri.transform.apply($0) },
                                                radius: configuration.matchRadius)
                if viaTriangles.count > pairs.count { pairs = viaTriangles }
            }
        }

        guard pairs.count >= configuration.minMatches else {
            return FrameAlignment(homography: lastCorrection * model, dt: dt,
                                  matchedStars: pairs.count, rmsResidual: .infinity, accepted: false,
                                  isReference: false, poleFitted: poleFitted)
        }

        // Per-frame rigid correction C_k (rotation + translation) between the model prediction and the
        // detections. Before the pole is known it carries the whole field rotation; afterwards it only
        // absorbs drift (OIS, tripod sag, refraction residue).
        var predicted: [SIMD2<Double>] = [], observed: [SIMD2<Double>] = []
        for (ref, cur) in pairs {
            if let p = model.apply(catalog[ref]) { predicted.append(p); observed.append(points[cur]) }
        }
        guard let rigid = Self.robustRigid(source: predicted, target: observed,
                                           inlierRadius: 3 * configuration.matchRadius) else {
            return FrameAlignment(homography: lastCorrection * model, dt: dt, matchedStars: pairs.count,
                                  rmsResidual: .infinity, accepted: false, isReference: false, poleFitted: poleFitted)
        }
        let rms = rigid.rms
        let accepted = rms <= configuration.maxRMS && rigid.inliers >= configuration.minMatches
        let correction = rigid.transform.homography
        let warp = correction * model

        if accepted {
            lastCorrection = correction
            storeObservation(dt: dt, pairs: pairs, points: points)
            framesSinceFit += 1
            refitIfNeeded()
            extendCatalog(points: points, matched: Set(pairs.map(\.1)), warp: warp)
        }
        return FrameAlignment(homography: warp, dt: dt, matchedStars: pairs.count, rmsResidual: rms,
                              accepted: accepted, isReference: false, poleFitted: poleFitted)
    }

    // MARK: - Matching

    private func gatedMatches(points: [SIMD2<Double>], prediction: Homography, radius: Double) -> [(Int, Int)] {
        gatedMatches(points: points, predictor: { prediction.apply($0) }, radius: radius)
    }

    /// Mutual nearest neighbours within `radius`, with an ambiguity check.
    private func gatedMatches(points: [SIMD2<Double>], predictor: (SIMD2<Double>) -> SIMD2<Double>?,
                              radius: Double) -> [(Int, Int)] {
        guard !points.isEmpty else { return [] }
        let r2 = radius * radius
        var predicted: [(Int, SIMD2<Double>)] = []
        for (i, c) in catalog.enumerated() {
            if let p = predictor(c) { predicted.append((i, p)) }
        }
        // Coarse grid over detected points for O(1) neighbourhood queries.
        let cell = max(radius, 1)
        var grid: [SIMD2<Int32>: [Int]] = [:]
        for (j, p) in points.enumerated() {
            grid[SIMD2(Int32(floor(p.x / cell)), Int32(floor(p.y / cell))), default: []].append(j)
        }
        var bestForPoint: [Int: (Int, Double)] = [:]
        var bestForCatalog: [Int: (Int, Double)] = [:]
        for (i, p) in predicted {
            let cx = Int32(floor(p.x / cell)), cy = Int32(floor(p.y / cell))
            var best = -1, bestD = r2, second = Double.infinity
            for dy in -1...1 {
                for dx in -1...1 {
                    for j in grid[SIMD2(cx + Int32(dx), cy + Int32(dy))] ?? [] {
                        let d = simd_distance_squared(points[j], p)
                        if d < bestD { second = bestD; bestD = d; best = j } else if d < second { second = d }
                    }
                }
            }
            guard best >= 0 else { continue }
            if second < r2, second < 2.25 * bestD { continue }   // ambiguous
            bestForCatalog[i] = (best, bestD)
            if let existing = bestForPoint[best], existing.1 <= bestD { continue }
            bestForPoint[best] = (i, bestD)
        }
        return bestForCatalog.compactMap { i, v in bestForPoint[v.0]?.0 == i ? (i, v.0) : nil }
    }

    // MARK: - Pole estimation

    private func storeObservation(dt: Double, pairs: [(Int, Int)], points: [SIMD2<Double>]) {
        guard dt > 0 else { return }
        let step = max(1, pairs.count / configuration.maxPairsPerFrame)
        let selected = stride(from: 0, to: pairs.count, by: step).map { pairs[$0] }
        observations.append(PoleObservation(dt: dt, pairs: selected.map {
            StarPair(reference: catalog[$0.0], current: points[$0.1])
        }))
        // Thin the history keeping it spread in time: drop the sample closest to its predecessor.
        while observations.count > configuration.maxObservationFrames {
            var dropIndex = 1, smallestGap = Double.infinity
            for i in 1..<(observations.count - 1) {
                let gap = observations[i + 1].dt - observations[i - 1].dt
                if gap < smallestGap { smallestGap = gap; dropIndex = i }
            }
            observations.remove(at: dropIndex)
        }
    }

    private func refitIfNeeded() {
        guard framesSinceFit >= configuration.refitEvery,
              let span = observations.last?.dt, span >= configuration.minBaselineForFit else { return }
        framesSinceFit = 0
        let fitFocal = span >= configuration.fitFocalAfterBaseline
        let start = poleFitted ? pole : priorPole
        guard let result = fitter.fit(observations: observations.removingStaticPoints(), prior: start, focalScale: focalScale,
                                      fitFocalScale: fitFocal, runCoarseSearch: !poleFitted) else { return }
        let improvesOnCurrent = lastFit.map { result.rms <= max($0.rms * 1.5, 0.5) } ?? true
        if result.rms < configuration.maxPoleFitRMS, improvesOnCurrent {
            pole = result.pole
            focalScale = result.focalScale
            poleFitted = true
            lastFit = result
            // Drift is now measured relative to the refined model; re-learn it from the latest observation.
            if let last = observations.last {
                let h = fitter.homography(dt: last.dt, pole: result.pole, focalScale: result.focalScale)
                var src: [SIMD2<Double>] = [], dst: [SIMD2<Double>] = []
                for pair in last.pairs {
                    if let p = h.apply(pair.reference) { src.append(p); dst.append(pair.current) }
                }
                lastCorrection = Self.robustRigid(source: src, target: dst,
                                                  inlierRadius: 3 * configuration.matchRadius)?.transform.homography ?? .identity
            }
        }
    }

    /// Newly risen / rotated-in stars are added in reference-epoch coordinates once the model is trusted.
    private func extendCatalog(points: [SIMD2<Double>], matched: Set<Int>, warp: Homography) {
        guard poleFitted, catalog.count < configuration.maxCatalogStars else { return }
        let inverse = warp.inverse
        let minSeparation2 = 9 * configuration.matchRadius * configuration.matchRadius
        for (j, p) in points.enumerated() where !matched.contains(j) {
            guard catalog.count < configuration.maxCatalogStars, let ref = inverse.apply(p) else { continue }
            if catalog.allSatisfy({ simd_distance_squared($0, ref) > minSeparation2 }) { catalog.append(ref) }
        }
    }
}

extension AlignmentEngine {
    struct RigidFit {
        var transform: SimilarityTransform
        var rms: Double
        var inliers: Int
    }

    /// Least-squares rotation + translation with two rounds of outlier trimming.
    static func robustRigid(source: [SIMD2<Double>], target: [SIMD2<Double>], inlierRadius: Double) -> RigidFit? {
        var src = source, dst = target
        var transform: SimilarityTransform?
        for round in 0..<3 {
            guard src.count >= 2, let similarity = SimilarityTransform.fit(source: src, target: dst) else { return nil }
            let theta = similarity.rotation
            let c = cos(theta), s = sin(theta)
            var meanSrc = SIMD2<Double>(0, 0), meanDst = SIMD2<Double>(0, 0)
            for i in src.indices { meanSrc += src[i]; meanDst += dst[i] }
            meanSrc /= Double(src.count); meanDst /= Double(src.count)
            let rigid = SimilarityTransform(a: c, b: s, t: meanDst - SIMD2(c * meanSrc.x - s * meanSrc.y, s * meanSrc.x + c * meanSrc.y))
            transform = rigid
            guard round < 2 else { break }
            let residuals = zip(source, target).map { simd_distance(rigid.apply($0), $1) }
            let threshold = max(min(3 * median(residuals), inlierRadius), 0.5)
            let keep = residuals.indices.filter { residuals[$0] <= threshold }
            src = keep.map { source[$0] }
            dst = keep.map { target[$0] }
        }
        guard let transform else { return nil }
        var sum = 0.0, n = 0
        for (p, q) in zip(source, target) {
            let d2 = simd_distance_squared(transform.apply(p), q)
            if d2 < inlierRadius * inlierRadius { sum += d2; n += 1 }
        }
        return RigidFit(transform: transform, rms: n > 0 ? (sum / Double(n)).squareRoot() : .infinity, inliers: n)
    }
}

extension SimilarityTransform {
    var homography: Homography {
        Homography(simd_double3x3(rows: [SIMD3(a, -b, t.x), SIMD3(b, a, t.y), SIMD3(0, 0, 1)]))
    }
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let s = values.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
}
