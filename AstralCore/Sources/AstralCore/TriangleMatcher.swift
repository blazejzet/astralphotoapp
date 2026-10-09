import Foundation
import simd

/// x' = [[a, −b], [b, a]]·x + t  (scale s = |(a, b)|, rotation θ = atan2(b, a)).
public struct SimilarityTransform: Sendable, Equatable {
    public var a: Double
    public var b: Double
    public var t: SIMD2<Double>

    public init(a: Double, b: Double, t: SIMD2<Double>) {
        self.a = a; self.b = b; self.t = t
    }

    public var scale: Double { (a * a + b * b).squareRoot() }
    public var rotation: Double { atan2(b, a) }

    @inlinable
    public func apply(_ p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(a * p.x - b * p.y + t.x, b * p.x + a * p.y + t.y)
    }

    /// Least-squares similarity (2-D Umeyama).
    public static func fit(source: [SIMD2<Double>], target: [SIMD2<Double>]) -> SimilarityTransform? {
        let n = min(source.count, target.count)
        guard n >= 2 else { return nil }
        var ps = SIMD2<Double>(0, 0), qs = SIMD2<Double>(0, 0)
        for i in 0..<n { ps += source[i]; qs += target[i] }
        ps /= Double(n); qs /= Double(n)
        var norm = 0.0, dotSum = 0.0, crossSum = 0.0
        for i in 0..<n {
            let p = source[i] - ps, q = target[i] - qs
            norm += p.x * p.x + p.y * p.y
            dotSum += p.x * q.x + p.y * q.y
            crossSum += p.x * q.y - p.y * q.x
        }
        guard norm > 1e-12 else { return nil }
        let a = dotSum / norm, b = crossSum / norm
        let t = qs - SIMD2(a * ps.x - b * ps.y, b * ps.x + a * ps.y)
        return SimilarityTransform(a: a, b: b, t: t)
    }
}

public struct IndexPair: Sendable, Equatable {
    public var source: Int
    public var target: Int
}

/// Registration without a prior, after astroalign (Beroiz, Cabral & Sanchez 2020, Astronomy and
/// Computing 32, 100384): triangles of each bright star with its 4 nearest neighbours, invariants
/// (L2/L1, L1/L0) of sorted side lengths, hypotheses from matched triangles, RANSAC on a similarity.
public struct TriangleMatcher: Sendable {
    public struct Configuration: Sendable {
        public var maxStars = 40
        public var neighbors = 4
        public var invariantTolerance = 0.03
        public var inlierTolerance = 2.0
        public var minInliers = 6
        public var scaleRange: ClosedRange<Double> = 0.8...1.25
        public var maxHypotheses = 4000
        public init() {}
    }

    public struct Match: Sendable {
        public var transform: SimilarityTransform
        public var pairs: [IndexPair]
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    struct Triangle {
        var v0: Int, v1: Int, v2: Int      // vertices opposite the shortest, middle, longest side
        var invariant: SIMD2<Double>
    }

    func triangles(_ points: [SIMD2<Double>]) -> [Triangle] {
        let n = points.count
        guard n >= 3 else { return [] }
        let k = min(configuration.neighbors, n - 1)
        var seen = Set<SIMD3<Int32>>()
        var result: [Triangle] = []
        for i in 0..<n {
            let nearest = (0..<n).filter { $0 != i }
                .sorted { simd_distance_squared(points[$0], points[i]) < simd_distance_squared(points[$1], points[i]) }
                .prefix(k)
            let group: [Int] = [i] + Array(nearest)
            for a in 0..<group.count {
                for b in (a + 1)..<group.count {
                    for c in (b + 1)..<group.count {
                        let ids = [group[a], group[b], group[c]].sorted()
                        let key = SIMD3<Int32>(Int32(ids[0]), Int32(ids[1]), Int32(ids[2]))
                        if !seen.insert(key).inserted { continue }
                        if let t = makeTriangle(ids[0], ids[1], ids[2], points) { result.append(t) }
                    }
                }
            }
        }
        return result
    }

    private func makeTriangle(_ i: Int, _ j: Int, _ k: Int, _ p: [SIMD2<Double>]) -> Triangle? {
        // (side length, opposite vertex)
        var sides = [(simd_distance(p[j], p[k]), i), (simd_distance(p[i], p[k]), j), (simd_distance(p[i], p[j]), k)]
        sides.sort { $0.0 < $1.0 }
        guard sides[0].0 > 1e-6 else { return nil }
        return Triangle(v0: sides[0].1, v1: sides[1].1, v2: sides[2].1,
                        invariant: SIMD2(sides[2].0 / sides[1].0, sides[1].0 / sides[0].0))
    }

    public func match(source: [SIMD2<Double>], target: [SIMD2<Double>]) -> Match? {
        let src = Array(source.prefix(configuration.maxStars))
        let dst = Array(target.prefix(configuration.maxStars))
        guard src.count >= 3, dst.count >= 3 else { return nil }
        let srcTris = triangles(src), dstTris = triangles(dst)
        let tol2 = configuration.invariantTolerance * configuration.invariantTolerance

        var hypotheses: [SimilarityTransform] = []
        outer: for s in srcTris {
            for d in dstTris where simd_distance_squared(s.invariant, d.invariant) < tol2 {
                guard let tr = SimilarityTransform.fit(source: [src[s.v0], src[s.v1], src[s.v2]],
                                                       target: [dst[d.v0], dst[d.v1], dst[d.v2]]),
                      configuration.scaleRange.contains(tr.scale) else { continue }
                hypotheses.append(tr)
                if hypotheses.count >= configuration.maxHypotheses { break outer }
            }
        }
        guard !hypotheses.isEmpty else { return nil }

        let tol2px = configuration.inlierTolerance * configuration.inlierTolerance
        func inliers(_ tr: SimilarityTransform) -> [IndexPair] {
            var pairs: [IndexPair] = []
            for (i, p) in src.enumerated() {
                let q = tr.apply(p)
                var best = -1, bestD = tol2px
                for (j, t) in dst.enumerated() {
                    let d = simd_distance_squared(q, t)
                    if d < bestD { bestD = d; best = j }
                }
                if best >= 0 { pairs.append(IndexPair(source: i, target: best)) }
            }
            return pairs
        }

        var bestPairs: [IndexPair] = []
        for h in hypotheses {
            let p = inliers(h)
            if p.count > bestPairs.count { bestPairs = p }
        }
        guard bestPairs.count >= configuration.minInliers,
              var refined = SimilarityTransform.fit(source: bestPairs.map { src[$0.source] },
                                                    target: bestPairs.map { dst[$0.target] }) else { return nil }
        let refinedPairs = inliers(refined)
        if refinedPairs.count >= bestPairs.count,
           let again = SimilarityTransform.fit(source: refinedPairs.map { src[$0.source] },
                                               target: refinedPairs.map { dst[$0.target] }) {
            refined = again
            bestPairs = refinedPairs
        }
        return Match(transform: refined, pairs: bestPairs)
    }
}
