"""Registration without a prior (port of AstralCore/TriangleMatcher.swift)."""

from __future__ import annotations

from dataclasses import dataclass
from itertools import combinations

import numpy as np
from scipy.spatial import cKDTree


@dataclass
class SimilarityTransform:
    """x' = [[a, −b], [b, a]]·x + t  (scale s = |(a, b)|, rotation θ = atan2(b, a))."""

    a: float
    b: float
    t: np.ndarray

    @property
    def scale(self) -> float:
        return float(np.hypot(self.a, self.b))

    def apply(self, p: np.ndarray) -> np.ndarray:
        p = np.asarray(p, dtype=np.float64)
        x, y = p[..., 0], p[..., 1]
        return np.stack([self.a * x - self.b * y + self.t[0], self.b * x + self.a * y + self.t[1]], axis=-1)

    @staticmethod
    def fit(source: np.ndarray, target: np.ndarray) -> "SimilarityTransform | None":
        """Least-squares similarity (2-D Umeyama)."""
        n = min(len(source), len(target))
        if n < 2:
            return None
        src, dst = np.asarray(source[:n], dtype=np.float64), np.asarray(target[:n], dtype=np.float64)
        ps, qs = src.mean(axis=0), dst.mean(axis=0)
        p, q = src - ps, dst - qs
        norm = (p * p).sum()
        if norm <= 1e-12:
            return None
        a = (p * q).sum() / norm
        b = (p[:, 0] * q[:, 1] - p[:, 1] * q[:, 0]).sum() / norm
        t = qs - np.array([a * ps[0] - b * ps[1], b * ps[0] + a * ps[1]])
        return SimilarityTransform(a, b, t)


class TriangleMatcher:
    """After astroalign (Beroiz, Cabral & Sanchez 2020, Astronomy and Computing 32, 100384): triangles of each
    bright star with its 4 nearest neighbours, invariants (L2/L1, L1/L0) of sorted side lengths, hypotheses
    from matched triangles, consensus on a similarity."""

    def __init__(self, max_stars=40, neighbors=4, invariant_tolerance=0.03, inlier_tolerance=2.0,
                 min_inliers=6, scale_range=(0.8, 1.25), max_hypotheses=4000):
        self.max_stars = max_stars
        self.neighbors = neighbors
        self.invariant_tolerance = invariant_tolerance
        self.inlier_tolerance = inlier_tolerance
        self.min_inliers = min_inliers
        self.scale_range = scale_range
        self.max_hypotheses = max_hypotheses

    def triangles(self, points: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """→ vertices (m, 3) opposite the shortest, middle, longest side, invariants (m, 2)."""
        n = len(points)
        if n < 3:
            return np.zeros((0, 3), dtype=np.int64), np.zeros((0, 2))
        k = min(self.neighbors, n - 1)
        _, nearest = cKDTree(points).query(points, k=k + 1)
        seen = set()
        vertices, invariants = [], []
        for i in range(n):
            group = [i] + [j for j in nearest[i] if j != i][:k]
            for tri in combinations(group, 3):
                ids = tuple(sorted(tri))
                if ids in seen:
                    continue
                seen.add(ids)
                a, b, c = ids
                sides = sorted([(np.linalg.norm(points[b] - points[c]), a),
                                (np.linalg.norm(points[a] - points[c]), b),
                                (np.linalg.norm(points[a] - points[b]), c)])
                if sides[0][0] <= 1e-6:
                    continue
                vertices.append((sides[0][1], sides[1][1], sides[2][1]))
                invariants.append((sides[2][0] / sides[1][0], sides[1][0] / sides[0][0]))
        return np.array(vertices, dtype=np.int64).reshape(-1, 3), np.array(invariants).reshape(-1, 2)

    def match(self, source: np.ndarray, target: np.ndarray):
        """→ (SimilarityTransform, [(source index, target index)]) or None."""
        src = np.asarray(source[: self.max_stars], dtype=np.float64)
        dst = np.asarray(target[: self.max_stars], dtype=np.float64)
        if len(src) < 3 or len(dst) < 3:
            return None
        src_v, src_inv = self.triangles(src)
        dst_v, dst_inv = self.triangles(dst)
        if len(src_v) == 0 or len(dst_v) == 0:
            return None
        candidates = cKDTree(dst_inv).query_ball_point(src_inv, self.invariant_tolerance)
        hypotheses = []
        for s, ds in enumerate(candidates):
            for d in ds:
                tr = SimilarityTransform.fit(src[src_v[s]], dst[dst_v[d]])
                if tr is None or not (self.scale_range[0] <= tr.scale <= self.scale_range[1]):
                    continue
                hypotheses.append(tr)
                if len(hypotheses) >= self.max_hypotheses:
                    break
            if len(hypotheses) >= self.max_hypotheses:
                break
        if not hypotheses:
            return None

        tree = cKDTree(dst)

        def inliers(tr: SimilarityTransform) -> list[tuple[int, int]]:
            d, j = tree.query(tr.apply(src), distance_upper_bound=self.inlier_tolerance)
            return [(i, int(j[i])) for i in range(len(src)) if np.isfinite(d[i])]

        # All hypotheses in one query: count, per hypothesis, the source stars with a target nearby.
        mats = np.array([[h.a, h.b, h.t[0], h.t[1]] for h in hypotheses])
        x, y = src[:, 0][None, :], src[:, 1][None, :]
        px = mats[:, 0:1] * x - mats[:, 1:2] * y + mats[:, 2:3]
        py = mats[:, 1:2] * x + mats[:, 0:1] * y + mats[:, 3:4]
        d, _ = tree.query(np.stack([px.ravel(), py.ravel()], axis=1), distance_upper_bound=self.inlier_tolerance)
        counts = np.isfinite(d).reshape(len(hypotheses), len(src)).sum(axis=1)
        best_pairs = inliers(hypotheses[int(np.argmax(counts))])
        if len(best_pairs) < self.min_inliers:
            return None
        refined = SimilarityTransform.fit(src[[p[0] for p in best_pairs]], dst[[p[1] for p in best_pairs]])
        if refined is None:
            return None
        refined_pairs = inliers(refined)
        if len(refined_pairs) >= len(best_pairs):
            again = SimilarityTransform.fit(src[[p[0] for p in refined_pairs]], dst[[p[1] for p in refined_pairs]])
            if again is not None:
                refined, best_pairs = again, refined_pairs
        return refined, best_pairs
