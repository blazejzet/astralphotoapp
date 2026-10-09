"""Noise model and the two-layer robust stacker (port of AstralCore/Stacking.swift, mirrors Shaders.metal)."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from scipy import ndimage

from .imaging import luminance

try:  # Optional fast path for the per-frame warp.
    import cv2
except ImportError:  # pragma: no cover
    cv2 = None


# MARK: - Noise model


@dataclass
class NoiseModel:
    """Affine (shot + read) noise model σ²(μ) = λ_s·μ + λ_r, as in HDR+ (Hasinoff et al. 2016) and
    Wronski et al. 2019. A relative model-error term (ε·μ)² protects bright star cores, whose pixel values
    fluctuate with sub-pixel registration and seeing."""

    lambda_s: float
    lambda_r: float
    relative_model_error: float = 0.1

    def variance(self, mean):
        m = np.maximum(mean, 0)
        e = self.relative_model_error * m
        return np.maximum(self.lambda_s * m + self.lambda_r + e * e, 1e-14)


def estimate_noise_model(current: np.ndarray, previous: np.ndarray, tile: int = 32, bins: int = 8) -> NoiseModel | None:
    """(λ_s, λ_r) from two consecutive, unregistered frames: per tile, var(J_k − J_{k−1})/2 against the tile
    mean. Sky motion between short frames is a fraction of a pixel, and tiles with stars/edges are
    suppressed by fitting a line through per-quantile medians."""
    if current.shape != previous.shape:
        return None
    h, w = current.shape
    ty, tx = h // tile, w // tile
    if ty * tx < bins * 2:
        return None
    a = current[: ty * tile, : tx * tile].astype(np.float64).reshape(ty, tile, tx, tile)
    b = previous[: ty * tile, : tx * tile].astype(np.float64).reshape(ty, tile, tx, tile)
    means = ((a + b) / 2).mean(axis=(1, 3)).ravel()
    d = a - b
    variances = (d.var(axis=(1, 3)) / 2).ravel()
    order = np.argsort(means, kind="stable")
    means, variances = means[order], variances[order]
    per_bin = len(means) // bins
    xs, ys = [], []
    for k in range(bins):
        sl = slice(k * per_bin, len(means) if k == bins - 1 else (k + 1) * per_bin)
        xs.append(np.median(means[sl]))
        ys.append(np.median(variances[sl]))
    xs, ys = np.array(xs), np.array(ys)
    mx, my = xs.mean(), ys.mean()
    sxx = ((xs - mx) ** 2).sum()
    slope = ((xs - mx) * (ys - my)).sum() / sxx if sxx > 1e-20 else 0.0
    intercept = my - slope * mx
    if slope < 0:
        slope, intercept = 0.0, my
    if intercept <= 0:
        intercept = max(ys.min() * 0.5, 1e-12)
    return NoiseModel(float(slope), float(intercept))


@dataclass
class RobustWeighting:
    """Robustness weight in the spirit of Wronski et al. 2019: w = clamp(s·exp(−z²/κ²) − t, 0, 1),
    z = (x − μ)/σ(μ). Satellites, planes, hot pixels and cosmic rays get w ≈ 0."""

    s: float = 1.05
    t: float = 0.05
    kappa: float = 4.0
    # Consecutive rejections after which a pixel's accumulator is reset (the mean itself was wrong)…
    reset_after: int = 8
    # …but only while the pixel holds little weight, i.e. a bad seed. Later, a static light drifting
    # slowly through the registered stack would be followed and drawn as a streak.
    reset_max_weight: float = 6

    def weight(self, value, mean, noise: NoiseModel):
        d = value - mean
        z2 = d * d / noise.variance(mean)
        return np.clip(self.s * np.exp(-z2 / (self.kappa * self.kappa)) - self.t, 0, 1)


# MARK: - Stack result


@dataclass
class StackResult:
    sky: np.ndarray  # registered (sky-tracking) weighted mean, reference grid, (3, H, W)
    sky_weight: np.ndarray  # Σ weights per pixel (coverage map)
    sky_variance: np.ndarray  # weighted temporal variance of luma in the registered stack
    foreground: np.ndarray  # unregistered mean (static foreground)
    foreground_variance: np.ndarray  # temporal variance of luma without registration
    frame_count: int
    # Registered luma mean and variance *without* robust weights or occlusion – the evidence for the sky mask
    # (robust weights hide exactly the moving scenery the mask must find). NaN = no samples.
    sky_plain_mean: np.ndarray | None = None
    sky_plain_variance: np.ndarray | None = None


# MARK: - Warp


class WarpMapper:
    """u_k = D(G_k·D⁻¹(u)): output (reference grid) pixel → source position in frame k."""

    def __init__(self, camera):
        self.camera = camera
        h, w = camera.height, camera.width
        ys, xs = np.mgrid[0:h, 0:w].astype(np.float64)
        grid = np.stack([xs.ravel(), ys.ravel()], axis=1)
        self.undistorted = camera.undistort(grid)

    def source_positions(self, homography: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        p = self.undistorted
        q = p @ homography[:, :2].T + homography[:, 2]
        with np.errstate(divide="ignore", invalid="ignore"):
            src = q[:, :2] / q[:, 2:3]
        src[q[:, 2] <= 1e-12] = np.nan
        src = self.camera.distort(src)
        shape = (self.camera.height, self.camera.width)
        return src[:, 0].reshape(shape).astype(np.float32), src[:, 1].reshape(shape).astype(np.float32)


def _remap(plane: np.ndarray, sx: np.ndarray, sy: np.ndarray) -> np.ndarray:
    h, w = plane.shape
    valid = (sx >= 0) & (sy >= 0) & (sx <= w - 1) & (sy <= h - 1)
    if cv2 is not None:
        out = cv2.remap(plane, np.where(valid, sx, -10), np.where(valid, sy, -10), cv2.INTER_LINEAR,
                        borderMode=cv2.BORDER_REPLICATE)
    else:
        out = ndimage.map_coordinates(plane, [np.where(valid, sy, 0), np.where(valid, sx, 0)], order=1,
                                      mode="nearest", prefilter=False)
    out[~valid] = np.nan
    return out


def warp(frame: np.ndarray, sx: np.ndarray, sy: np.ndarray, occlusion: np.ndarray | None = None):
    """Inverse warp of a frame onto the reference grid; invalid pixels get NaN luma.
    `occlusion` (ground probability on the static sensor grid) drops sky samples that fall behind the
    horizon in this frame. `plain` is the warped luma ignoring occlusion (for the mask evidence)."""
    out = np.stack([_remap(frame[c], sx, sy) for c in range(3)])
    plain = luminance(out)
    luma = plain.copy()
    if occlusion is not None:
        occ = _remap(occlusion, sx, sy)
        luma[~(occ <= 0.5)] = np.nan
    return out, luma, plain


class RobustLayer:
    """Weighted Welford mean/variance with robust weights (Wronski et al. 2019); the first 3 frames seed the mean
    by their median, a pixel whose seed was wrong is reset after `reset_after` consecutive rejections."""

    WARMUP_FRAMES = 3

    def __init__(self, width: int, height: int, weighting: RobustWeighting):
        self.weighting = weighting
        shape = (height, width)
        self.rgb = np.zeros((3, height, width), dtype=np.float32)
        self.w = np.zeros(shape, dtype=np.float32)
        self.mean = np.zeros(shape, dtype=np.float32)
        self.m2 = np.zeros(shape, dtype=np.float32)
        self.rejections = np.zeros(shape, dtype=np.float32)
        self.warmup: list = []
        self.frames = 0

    def add(self, rgb: np.ndarray, luma: np.ndarray, frame_weight: float, noise: NoiseModel):
        """`luma` NaN = no sample (outside the warped frame or occluded)."""
        self.frames += 1
        if self.frames <= self.WARMUP_FRAMES:
            self.warmup.append((rgb, luma, frame_weight))
            if self.frames == self.WARMUP_FRAMES:
                self.seed(noise)
            return
        valid = np.isfinite(luma)
        has = self.w > 0
        l = np.where(valid, luma, 0)
        wr = np.where(has, self.weighting.weight(l, self.mean, noise), 1).astype(np.float32)
        rejected = valid & has & (wr < 0.05)
        self.rejections[rejected] += 1
        self.rejections[valid & ~rejected] = 0
        reset = rejected & (self.rejections >= self.weighting.reset_after) & (self.w < self.weighting.reset_max_weight)
        if reset.any():
            for c in range(3):
                self.rgb[c][reset] = rgb[c][reset] * frame_weight
            self.w[reset] = frame_weight
            self.mean[reset] = luma[reset]
            self.m2[reset] = 0
            self.rejections[reset] = 0
        self._accumulate(valid & ~rejected, rgb, luma, frame_weight * wr)

    def _accumulate(self, where: np.ndarray, rgb: np.ndarray, luma: np.ndarray, weight):
        w = np.where(where, weight, 0).astype(np.float32)
        w_new = self.w + w
        upd = where & (w_new > 0)
        if not upd.any():
            return
        l = luma[upd]
        wn, wu = w_new[upd], w[upd]
        delta = l - self.mean[upd]
        mean = self.mean[upd] + (wu / wn) * delta
        self.m2[upd] += wu * delta * (l - mean)
        self.mean[upd] = mean
        for c in range(3):
            self.rgb[c][upd] += wu * rgb[c][upd]
        self.w[upd] = wn

    def seed(self, noise: NoiseModel):
        if not self.warmup:
            return
        lumas = np.stack([f[1] for f in self.warmup])
        full = np.isfinite(lumas).sum(axis=0) >= 3
        med = np.sort(np.where(np.isfinite(lumas), lumas, np.inf), axis=0)[1] if len(self.warmup) >= 3 else None
        for rgb, luma, fw in self.warmup:
            valid = np.isfinite(luma)
            weight = np.full(luma.shape, fw, dtype=np.float32)
            if med is not None:
                robust = self.weighting.weight(np.where(full & valid, luma, 0), np.where(full, med, 0), noise)
                weight = np.where(full, fw * robust, weight).astype(np.float32)
            self._accumulate(valid, rgb, luma, weight)
        self.warmup = []

    def result(self, noise: NoiseModel) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        """→ (mean RGB, Σ weights, luma variance); uncovered pixels: 0, 0, float max."""
        self.seed(noise)
        covered = self.w > 0
        safe = np.where(covered, self.w, 1)
        mean = np.where(covered, self.rgb / safe, 0).astype(np.float32)
        var = np.where(covered, self.m2 / safe, np.finfo(np.float32).max).astype(np.float32)
        return mean, self.w.copy(), var


class RobustStacker:
    """Streaming two-layer stacker for J = M_sky·I_sky + I_ground:
    * sky layer: frames are inverse-warped and merged with robust weights (O(1) memory in N);
    * foreground layer: no warping. Unlike the app's plain running mean, its *mean* is robust too, so a
      satellite or plane is not kept in the foreground stack, where it read as sharp static scenery (ground)
      to the sky mask. Its *variance* stays unweighted: it is the temporal evidence for the mask.
    * unweighted registered luma statistics within the early drift window (mask evidence)."""

    # Sky drift (px) up to which frames feed the unweighted mask statistics.
    PLAIN_WINDOW_PIXELS = 15.0

    def __init__(self, width: int, height: int, weighting: RobustWeighting | None = None):
        self.width, self.height = width, height
        self.weighting = weighting or RobustWeighting()
        shape = (height, width)
        self.sky = RobustLayer(width, height, self.weighting)
        self.ground = RobustLayer(width, height, self.weighting)
        self.fg_mean = np.zeros(shape, dtype=np.float32)
        self.fg_m2 = np.zeros(shape, dtype=np.float32)
        self.plain_sum = np.zeros(shape, dtype=np.float64)
        self.plain_sq = np.zeros(shape, dtype=np.float64)
        self.plain_count = np.zeros(shape, dtype=np.float32)
        self.last_noise = NoiseModel(0, 1e-6)
        self.frame_count = 0

    def add(self, frame: np.ndarray, sx: np.ndarray, sy: np.ndarray, noise: NoiseModel, frame_weight: float = 1.0,
            occlusion: np.ndarray | None = None, accumulate_plain: bool = True):
        self.last_noise = noise
        luma = luminance(frame)
        n = self.frame_count + 1
        delta = luma - self.fg_mean
        self.fg_mean += delta / n
        self.fg_m2 += delta * (luma - self.fg_mean)
        self.ground.add(frame, luma, frame_weight, noise)
        warped, sky_luma, plain = warp(frame, sx, sy, occlusion)
        if accumulate_plain:
            ok = np.isfinite(plain)
            self.plain_sum[ok] += plain[ok]
            self.plain_sq[ok] += plain[ok].astype(np.float64) ** 2
            self.plain_count[ok] += 1
        self.frame_count = n
        self.sky.add(warped, sky_luma, frame_weight, noise)

    def result(self) -> StackResult:
        sky, sky_w, sky_var = self.sky.result(self.last_noise)
        fg, _, _ = self.ground.result(self.last_noise)
        fg_var = (self.fg_m2 / max(self.frame_count, 1)).astype(np.float32)
        has_plain = self.plain_count > 0
        cnt = np.where(has_plain, self.plain_count, 1)
        m = self.plain_sum / cnt
        plain_mean = np.where(has_plain, m, np.nan).astype(np.float32)
        plain_var = np.where(has_plain, np.maximum(self.plain_sq / cnt - m * m, 0), np.nan).astype(np.float32)
        return StackResult(sky, sky_w, sky_var, fg, fg_var, self.frame_count, plain_mean, plain_var)
