"""SExtractor-style star detection (port of AstralCore/StarDetector.swift)."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .imaging import GAUSSIAN_BLUR5_NOISE_FACTOR, gaussian_blur5, median, sigma_clipped


@dataclass
class StarDetection:
    """Stars sorted by flux (brightest first)."""

    positions: np.ndarray  # (n, 2) intensity-weighted centroids (x, y)
    flux: np.ndarray  # background-subtracted flux inside the centroid window
    peak: np.ndarray  # background-subtracted peak value
    fwhm: np.ndarray  # FWHM from second moments (Gaussian approximation)
    background: float  # global sky background (median of mesh modes)
    noise: float  # per-pixel noise σ of the *input* image (white-noise estimate)

    @property
    def count(self) -> int:
        return len(self.flux)


class BackgroundMesh:
    """Coarse background/noise grid, bilinearly interpolated between mesh centres."""

    def __init__(self, image: np.ndarray, mesh_size: int):
        h, w = image.shape
        size = max(8, min(mesh_size, min(w, h)))
        self.nx, self.ny = max(1, w // size), max(1, h // size)
        self.step_x, self.step_y = w // self.nx, h // self.ny
        self.background = np.zeros((self.ny, self.nx), dtype=np.float32)
        self.sigma = np.zeros((self.ny, self.nx), dtype=np.float32)
        for ty in range(self.ny):
            for tx in range(self.nx):
                x0, y0 = tx * self.step_x, ty * self.step_y
                x1 = w if tx == self.nx - 1 else x0 + self.step_x
                y1 = h if ty == self.ny - 1 else y0 + self.step_y
                med, mean, sigma = sigma_clipped(image[y0:y1:2, x0:x1:2], kappa=3, iterations=4)
                if sigma > 0 and abs(mean - med) / sigma < 0.3:
                    mode = 2.5 * med - 1.5 * mean
                else:
                    mode = med
                self.background[ty, tx] = mode
                self.sigma[ty, tx] = max(sigma, 1e-9)

    @property
    def global_background(self) -> float:
        return median(self.background)

    @property
    def global_sigma(self) -> float:
        return median(self.sigma)

    def minimum_threshold(self, kappa: float) -> float:
        return float((self.background + kappa * self.sigma).min())

    def values(self, x: np.ndarray, y: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        nx, ny = self.nx, self.ny
        gx = np.clip((x + 0.5) / self.step_x - 0.5, 0, nx - 1)
        gy = np.clip((y + 0.5) / self.step_y - 0.5, 0, ny - 1)
        x0 = np.minimum(gx.astype(np.int64), max(nx - 2, 0))
        y0 = np.minimum(gy.astype(np.int64), max(ny - 2, 0))
        x1, y1 = np.minimum(x0 + 1, nx - 1), np.minimum(y0 + 1, ny - 1)
        fx, fy = (gx - x0).astype(np.float32), (gy - y0).astype(np.float32)

        def lerp(a):
            top = a[y0, x0] * (1 - fx) + a[y0, x1] * fx
            bottom = a[y1, x0] * (1 - fx) + a[y1, x1] * fx
            return top * (1 - fy) + bottom * fy

        return lerp(self.background), lerp(self.sigma)


class StarDetector:
    """Mesh background (κσ-clipped mode = 2.5·med − 1.5·mean), matched filter (≈ Gaussian σ = 1 px),
    threshold at kσ, local maxima, weighted centroids.
    Bertin & Arnouts 1996 (A&AS 117, 393); SEP – Barbary 2016 (JOSS 1(6), 58)."""

    def __init__(self, mesh_size=64, threshold_sigma=5.0, max_stars=150, min_pixels_above_threshold=3,
                 centroid_radius=3, edge_margin=6, max_elongation=None):
        self.mesh_size = mesh_size
        self.threshold_sigma = threshold_sigma
        self.max_stars = max_stars
        self.min_pixels_above_threshold = min_pixels_above_threshold
        self.centroid_radius = centroid_radius
        self.edge_margin = edge_margin
        # √(λ_max/λ_min) of the second moments above which a detection is dropped (satellite and plane
        # streaks: ≈ 2.4, stars ≈ 1.1). None = keep everything, as AstralCore's detector.
        self.max_elongation = max_elongation

    def detect(self, image: np.ndarray, mask: np.ndarray | None = None) -> StarDetection:
        image = np.ascontiguousarray(image, dtype=np.float32)
        h, w = image.shape
        smooth = gaussian_blur5(image)
        mesh = BackgroundMesh(smooth, self.mesh_size)
        thr = self.threshold_sigma
        r = self.centroid_radius
        margin = max(self.edge_margin, r + 2)
        noise = mesh.global_sigma / GAUSSIAN_BLUR5_NOISE_FACTOR
        empty = StarDetection(np.zeros((0, 2)), np.zeros(0), np.zeros(0), np.zeros(0), mesh.global_background, noise)
        if w <= 2 * margin or h <= 2 * margin:
            return empty

        inner = smooth[margin:h - margin, margin:w - margin]
        ys, xs = np.nonzero(inner > mesh.minimum_threshold(thr))
        ys, xs = ys + margin, xs + margin
        bg, sigma = mesh.values(xs.astype(np.float32), ys.astype(np.float32))
        v = smooth[ys, xs]
        t = bg + thr * sigma
        keep = v > t
        xs, ys, v, t, bg = xs[keep], ys[keep], v[keep], t[keep], bg[keep]

        # Strict local maximum in a 5×5 window (ties broken by scan order).
        is_max = np.ones(xs.size, dtype=bool)
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                if dx == 0 and dy == 0:
                    continue
                n = smooth[ys + dy, xs + dx]
                earlier = dy < 0 or (dy == 0 and dx < 0)
                is_max &= ~((n > v) | ((n == v) & earlier))
        xs, ys, v, t, bg = xs[is_max], ys[is_max], v[is_max], t[is_max], bg[is_max]

        area = np.zeros(xs.size, dtype=np.int32)
        for dy in range(-1, 2):
            for dx in range(-1, 2):
                area += smooth[ys + dy, xs + dx] > t
        keep = area >= self.min_pixels_above_threshold
        if mask is not None:
            keep &= mask[ys, xs] >= 0.5
        xs, ys, bg = xs[keep], ys[keep], bg[keep]
        if xs.size == 0:
            return empty

        offsets = np.arange(-r, r + 1)
        ox, oy = np.meshgrid(offsets, offsets)
        ox, oy = ox.ravel(), oy.ravel()
        raw = image[ys[:, None] + oy[None, :], xs[:, None] + ox[None, :]]
        peak = raw.max(axis=1) - bg
        val = (raw - bg[:, None]).astype(np.float64)
        val[val <= 0] = 0
        sw = val.sum(axis=1)
        ok = sw > 0
        val, sw, xs, ys, peak = val[ok], sw[ok], xs[ok], ys[ok], peak[ok]
        mx = (val * ox).sum(axis=1) / sw
        my = (val * oy).sum(axis=1) / sw
        sr2 = (val * (ox * ox + oy * oy)).sum(axis=1) / sw
        per_axis_variance = np.maximum(sr2 - mx * mx - my * my, 0) / 2
        order = np.argsort(-sw, kind="stable")
        if self.max_elongation is not None:
            cxx = (val * ox * ox).sum(axis=1) / sw - mx * mx
            cyy = (val * oy * oy).sum(axis=1) / sw - my * my
            cxy = (val * ox * oy).sum(axis=1) / sw - mx * my
            half_trace, det = (cxx + cyy) / 2, cxx * cyy - cxy * cxy
            root = np.sqrt(np.maximum(half_trace ** 2 - det, 0))
            elongation = np.sqrt((half_trace + root) / np.maximum(half_trace - root, 1e-9))
            order = order[elongation[order] <= self.max_elongation]
        order = order[: self.max_stars]
        positions = np.stack([xs + mx, ys + my], axis=1)[order]
        return StarDetection(positions, sw[order], peak[order].astype(np.float64),
                             2.3548 * np.sqrt(per_axis_variance[order]), mesh.global_background, noise)
