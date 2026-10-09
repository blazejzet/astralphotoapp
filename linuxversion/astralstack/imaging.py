"""Planar images, robust statistics and filters (port of AstralCore/Images.swift).

Conventions shared by the whole package:
* a plane is a float32 array (H, W), an RGB image a float32 array (3, H, W) in linear camera RGB,
  1.0 = sensor white level;
* pixel centres lie on integer coordinates, origin top-left, positions are (x, y).
"""

from __future__ import annotations

import numpy as np
from scipy import ndimage


def luminance(rgb: np.ndarray) -> np.ndarray:
    """Luma used everywhere for detection and robust weighting: mean of the 4 Bayer samples = (R + 2G + B)/4."""
    return (rgb[0] + 2 * rgb[1] + rgb[2]) * 0.25


# MARK: - Statistics


def percentile(values: np.ndarray, p: float) -> float:
    values = np.asarray(values).ravel()
    if values.size == 0:
        return 0.0
    idx = min(values.size - 1, max(0, int(round((values.size - 1) * p))))
    return float(np.partition(values, idx)[idx])


def median(values: np.ndarray) -> float:
    return percentile(values, 0.5)


def median_mean(values) -> float:
    """Median averaging the two middle values (AlignmentEngine's `median` over Doubles)."""
    values = np.asarray(values, dtype=np.float64)
    return float(np.median(values)) if values.size else 0.0


def sigma_clipped(values: np.ndarray, kappa: float = 3, iterations: int = 3) -> tuple[float, float, float]:
    """Iterative κ-σ clipping around the median → (median, mean, sigma)."""
    current = np.sort(np.asarray(values, dtype=np.float64).ravel())
    if current.size == 0:
        return 0.0, 0.0, 0.0
    med = mean = sigma = 0.0
    for _ in range(iterations + 1):
        med = current[current.size // 2]
        mean = current.mean()
        sigma = float(np.sqrt(max((current * current).mean() - mean * mean, 0)))
        lo, hi = med - kappa * sigma, med + kappa * sigma
        a, b = np.searchsorted(current, lo, "left"), np.searchsorted(current, hi, "right")
        if b - a == current.size or b - a < 3:
            break
        current = current[a:b]
    return float(med), float(mean), sigma


def sample(image: np.ndarray, stride: int, mask: np.ndarray | None = None) -> np.ndarray:
    """Strided subsample of an image's pixels (optionally restricted by a mask ≥ 0.5)."""
    values = image[::stride, ::stride]
    keep = np.isfinite(values)
    if mask is not None:
        keep &= mask[::stride, ::stride] >= 0.5
    return values[keep]


def background_and_noise(image: np.ndarray, mask: np.ndarray | None = None) -> tuple[float, float]:
    """Robust background level and noise (MAD·1.4826)."""
    stride = max(1, int(np.sqrt(image.size / 200_000)))
    values = sample(image, stride, mask)
    if values.size < 16:
        values = sample(image, stride)
    med = median(values)
    mad = median(np.abs(values - med))
    return med, mad * 1.4826


# MARK: - Filters


def _box1d(a: np.ndarray, radius: int, axis: int) -> np.ndarray:
    n = a.shape[axis]
    c = np.cumsum(a, axis=axis, dtype=np.float64)
    pad = [(0, 0)] * a.ndim
    pad[axis] = (1, 0)
    c = np.pad(c, pad)
    idx = np.arange(n)
    lo, hi = np.maximum(idx - radius, 0), np.minimum(idx + radius, n - 1)
    s = np.take(c, hi + 1, axis=axis) - np.take(c, lo, axis=axis)
    shape = [1] * a.ndim
    shape[axis] = n
    return s / (hi - lo + 1).reshape(shape)


def box_blur(image: np.ndarray, radius: int) -> np.ndarray:
    """Separable box blur with edge renormalisation (mean over the in-bounds window)."""
    if radius <= 0:
        return image
    return _box1d(_box1d(image, radius, 1), radius, 0).astype(np.float32)


_K5 = np.array([1, 4, 6, 4, 1], dtype=np.float32) / 16


def gaussian_blur5(image: np.ndarray) -> np.ndarray:
    """Separable [1 4 6 4 1]/16 smoothing (≈ Gaussian σ = 1 px) with clamped edges."""
    tmp = ndimage.correlate1d(image, _K5, axis=1, mode="nearest")
    return ndimage.correlate1d(tmp, _K5, axis=0, mode="nearest")


# Noise reduction factor of `gaussian_blur5` for white noise: sqrt(Σk²)² over 2-D = 70/256.
GAUSSIAN_BLUR5_NOISE_FACTOR = 70.0 / 256.0


def bilinear(image: np.ndarray, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    """Bilinear samples at (x, y); NaN outside the valid interpolation domain [0, W−1]×[0, H−1]."""
    h, w = image.shape
    x = np.asarray(x, dtype=np.float64)
    y = np.asarray(y, dtype=np.float64)
    valid = (x >= 0) & (y >= 0) & (x <= w - 1) & (y <= h - 1)
    xs, ys = np.where(valid, x, 0), np.where(valid, y, 0)
    x0 = np.minimum(xs.astype(np.int64), w - 2)
    y0 = np.minimum(ys.astype(np.int64), h - 2)
    fx, fy = xs - x0, ys - y0
    top = image[y0, x0] * (1 - fx) + image[y0, x0 + 1] * fx
    bottom = image[y0 + 1, x0] * (1 - fx) + image[y0 + 1, x0 + 1] * fx
    return np.where(valid, top * (1 - fy) + bottom * fy, np.nan)


def solve_linear_system(a, b) -> np.ndarray | None:
    try:
        return np.linalg.solve(np.asarray(a, dtype=np.float64), np.asarray(b, dtype=np.float64))
    except np.linalg.LinAlgError:
        return None
