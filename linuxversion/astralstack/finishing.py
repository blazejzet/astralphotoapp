"""Linear post-processing and display stretch (port of Finisher.swift, PostProcessing.swift, Vignetting.swift)."""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
from scipy.signal import fftconvolve

from .detection import StarDetector
from .imaging import (background_and_noise, bilinear, box_blur, luminance, median, median_mean, sample,
                      sigma_clipped, solve_linear_system)
from .stacking import StackResult

# MARK: - Sky / foreground mask

# Direction of gravity in the sensor buffer, from the EXIF orientation of the frames.
GROUND_FROM_ORIENTATION = {1: "down", 3: "up", 6: "right", 8: "left"}


def _to_uv(a: np.ndarray, direction: str) -> np.ndarray:
    """Image (H, W) → (U, V): u along the horizon, v along gravity (top of the sky first)."""
    if direction == "down":
        return a.T
    if direction == "up":
        return a[::-1, :].T
    if direction == "right":
        return a
    return a[:, ::-1]


def _from_uv(a: np.ndarray, direction: str) -> np.ndarray:
    if direction == "down":
        return np.ascontiguousarray(a.T)
    if direction == "up":
        return np.ascontiguousarray(a.T[::-1, :])
    if direction == "right":
        return a
    return np.ascontiguousarray(a[:, ::-1])


class SkyMaskBuilder:
    """The mask comes from the physics of the two stacks: sky pixels are temporally stable when registered
    (var_sky < var_fg), static scenery when not. Evidence (positive = sky, negative = ground, ≈ 0 in
    featureless regions):
    * temporal: log(var_fg / var_sky);
    * spatial: log(HF_sky / HF_fg), local high-frequency energy of the two *means* – stars are points in the
      registered stack and trails in the static one, scenery is sharp only in the static one.

    With a known gravity direction each column u is a sky band [t, h) between optional foreground at the top
    (eaves, branches) and the landscape at the bottom:
        argmin_{t≤h}  Σ_{v∉[t,h)} max(s − τ, 0) + Σ_{v∈[t,h)} max(−s − τ, 0) + γ·(t + V − h)
    solved in O(V) per column with a running minimum, then median-filtered along the horizon. Without a
    direction a smoothed majority vote of sign(s) is used."""

    def __init__(self, ground_direction: str | None = None, ground_prior: np.ndarray | None = None):
        self.smoothing_radius: int | None = None
        self.feather_radius: int | None = None
        self.bias = 0.05
        self.evidence_threshold = 0.25
        self.ground_penalty = 0.02
        self.ground_direction = ground_direction
        self.ground_prior = ground_prior

    @staticmethod
    def high_frequency_energy(image: np.ndarray, radius: int) -> np.ndarray:
        """Local high-frequency energy: box-averaged squared difference from a 3×3 mean."""
        d = image - box_blur(image, 1)
        detail = np.where(np.isfinite(d), d * d, 0).astype(np.float32)
        return box_blur(detail, radius)

    def build(self, stack: StackResult) -> np.ndarray:
        h, w = stack.sky_weight.shape
        if stack.frame_count < 4:
            return (stack.sky_weight > 0).astype(np.float32)
        short_side = min(w, h)
        smoothing_radius = self.smoothing_radius or max(3, short_side // 250)
        feather_radius = self.feather_radius or max(1, short_side // 700)
        eps = 1e-12
        uncovered_score = -4.0 if self.ground_direction is None else 0.0
        radius_hf = max(2, smoothing_radius // 2)
        hf_fg = self.high_frequency_energy(luminance(stack.foreground), radius_hf)
        # Noise floor: half the typical static-stack detail energy, so pure noise compares as a tie.
        hf_floor = max(median(sample(hf_fg, 7)) * 0.5, 1e-14)

        def evidence(sky_luma, sky_variance):
            hf_sky = self.high_frequency_energy(sky_luma, radius_hf)
            with np.errstate(divide="ignore", invalid="ignore", over="ignore"):
                temporal = np.clip(np.log((stack.foreground_variance + eps) / (sky_variance.astype(np.float64) + eps)), -4, 4)
                spatial = np.clip(np.log((hf_sky + hf_floor) / (hf_fg + hf_floor)), -4, 4)
            return np.clip(temporal + spatial, -4, 4)

        # Two sources: the robust stack (sees fast-moving scenery) and the unweighted early-window stack (sees
        # slowly drifting scenery that robust weights reject). Strong ground evidence from either wins;
        # otherwise the stronger sky evidence counts.
        robust = evidence(luminance(stack.sky), stack.sky_variance)
        score = robust
        if stack.sky_plain_mean is not None and stack.sky_plain_variance is not None:
            pm, pv = stack.sky_plain_mean, stack.sky_plain_variance
            plain = evidence(np.where(np.isfinite(pm), pm, 0), np.where(np.isfinite(pv), pv, 1))
            lo, hi = np.minimum(robust, plain), np.maximum(robust, plain)
            score = np.where(np.isfinite(pm), np.where(lo < -0.5, lo, hi), robust)
        score = np.where(stack.sky_weight <= 0, uncovered_score, score)
        if self.ground_prior is not None:
            score = np.where(self.ground_prior >= 0.5, np.minimum(score, 0) - 0.3, score)
        smoothed = box_blur(score.astype(np.float32), smoothing_radius)
        if self.ground_direction is not None:
            alpha = self.horizon_mask(smoothed, self.ground_direction, float(max(feather_radius, 1)))
        else:
            binary = (smoothed > -self.bias).astype(np.float32)
            majority = (box_blur(binary, smoothing_radius) >= 0.5).astype(np.float32)
            alpha = box_blur(majority, feather_radius)
        alpha = np.where(stack.sky_weight <= 0, 0, alpha)
        return alpha.astype(np.float32)

    def horizon_mask(self, score: np.ndarray, direction: str, feather: float) -> np.ndarray:
        s = _to_uv(score, direction).astype(np.float64)
        length_u, length_v = s.shape
        tau, gamma = self.evidence_threshold, self.ground_penalty
        pos = np.concatenate([np.zeros((length_u, 1)), np.cumsum(np.maximum(s - tau, 0), axis=1)], axis=1)
        neg = np.concatenate([np.zeros((length_u, 1)), np.cumsum(np.maximum(-s - tau, 0), axis=1)], axis=1)
        # Sky band [t, h): cost = B(t) − B(h) + const,  B(x) = P(x) − N(x) + γ·x.
        v = np.arange(length_v + 1)
        b = pos - neg + gamma * v
        running = np.minimum.accumulate(b, axis=1)
        new_min = np.ones_like(b, dtype=bool)
        new_min[:, 1:] = b[:, 1:] < running[:, :-1]  # ties → smaller t (more sky)
        min_t = np.maximum.accumulate(np.where(new_min, v, 0), axis=1)
        cost = running - b
        bottom = length_v - np.argmin(cost[:, ::-1], axis=1)  # last minimum: ties → larger h
        top = min_t[np.arange(length_u), bottom]

        # Median filter along the horizon removes single-column spikes (a star, a hot column).
        half = max(1, length_u // 120)

        def median_filtered(a):
            out = np.empty_like(a)
            for u in range(length_u):
                window = np.sort(a[max(0, u - half): min(length_u - 1, u + half) + 1])
                out[u] = window[len(window) // 2]
            return out

        t, hz = median_filtered(top), median_filtered(bottom)
        fv = np.arange(length_v) + 0.5
        below = np.clip((hz[:, None] - fv[None, :]) / feather + 0.5, 0, 1)
        above = np.where(t[:, None] == 0, 1.0, np.clip((fv[None, :] - t[:, None]) / feather + 0.5, 0, 1))
        return _from_uv(np.minimum(below, above).astype(np.float32), direction)

    def occlusion_mask(self, stack: StackResult, minimum_frames: int = 10) -> np.ndarray | None:
        """Provisional ground mask (1 = ground, transition counted as ground) used during stacking to keep
        occluded samples out of the sky stack. None until there are enough frames for a stable decision."""
        if stack.frame_count < minimum_frames:
            return None
        alpha = self.build(stack)
        covered = stack.sky_weight > 0
        if not np.any(alpha[covered] < 0.9):
            return None
        return np.where(covered, (alpha < 0.9).astype(np.float32), 0).astype(np.float32)


# MARK: - Background (light pollution) gradient


def _cells(plane: np.ndarray, mask: np.ndarray, grid_x: int, grid_y: int, cw: int, ch: int):
    h, w = plane.shape
    for gy in range(grid_y):
        for gx in range(grid_x):
            ys, xs = slice(gy * ch, min(h, (gy + 1) * ch), 2), slice(gx * cw, min(w, (gx + 1) * cw), 2)
            yield gx, gy, plane[ys, xs], mask[ys, xs]


def fit_background(plane: np.ndarray, mask: np.ndarray, grid_x: int = 16, grid_y: int = 12) -> np.ndarray | None:
    """Smooth background (quadratic surface + radial r⁴/r⁶ terms) through κσ-clipped cell medians inside the
    mask, rejecting outlier cells."""
    h, w = plane.shape
    cw, ch = max(1, w // grid_x), max(1, h // grid_y)
    xs, ys, vs = [], [], []
    for gx, gy, values, m in _cells(plane, mask, grid_x, grid_y, cw, ch):
        values = values[m >= 0.9]
        if values.size < max(16, cw * ch // 16):
            continue
        xs.append((gx + 0.5) / grid_x * 2 - 1)
        ys.append((gy + 0.5) / grid_y * 2 - 1)
        vs.append(sigma_clipped(values, kappa=2, iterations=5)[0])
    xs, ys, vs = np.array(xs), np.array(ys), np.array(vs)
    # Quadratic surface (light pollution) + radial r⁴, r⁶ about the optical centre (what is left of lens
    # falloff – a parabola alone leaves a bright centre and a dark ring).
    diag = np.hypot(w, h)
    ax, ay = w / diag, h / diag

    def terms(x, y):
        r2 = (x * ax) ** 2 + (y * ay) ** 2
        return np.stack([np.ones_like(x), x, y, x * x, x * y, y * y, r2 * r2, r2 * r2 * r2], axis=-1)

    n = 8
    if len(vs) < 3 * n:
        return None

    def solve(idx):
        t = terms(xs[idx], ys[idx])
        return solve_linear_system(t.T @ t + 1e-12 * np.eye(n), t.T @ vs[idx])

    c = solve(np.arange(len(vs)))
    if c is None:
        return None
    # Cells off the smooth model (Milky Way, nebulae, lit clouds) must not shape the background.
    residuals = vs - terms(xs, ys) @ c
    mad = median_mean(np.abs(residuals)) * 1.4826
    keep = np.nonzero(np.abs(residuals) <= max(3 * mad, 1e-9))[0]
    if len(keep) >= 3 * n:
        refined = solve(keep)
        if refined is not None:
            c = refined
    ny = (np.arange(h) + 0.5) / h * 2 - 1
    nx = (np.arange(w) + 0.5) / w * 2 - 1
    gx, gy = np.meshgrid(nx, ny)
    return (terms(gx, gy) @ c).astype(np.float32)


def gradient_correction(image: np.ndarray, mask: np.ndarray) -> list:
    """Per-channel additive correction, pedestal − model (the pedestal is the model's median), fitted inside the
    mask. Outside it the correction is clamped to the range it takes inside, so the foreground gets the same
    smooth shift (no step at the mask edge) without the extrapolated polynomial running away."""
    out = []
    inside = mask >= 0.9
    for c in range(3):
        model = fit_background(image[c], mask)
        if model is None or not inside.any():
            out.append(None)
            continue
        pedestal = median(sample(model, 8, mask))
        lo, hi = model[inside].min(), model[inside].max()
        out.append((pedestal - np.clip(model, lo, hi)).astype(np.float32))
    return out


def apply_gradient(correction: list, image: np.ndarray):
    for c, f in enumerate(correction):
        if f is not None:
            image[c] += f


# MARK: - Vignetting


@dataclass
class VignettingModel:
    """Radial lens falloff V(r) = 1 + a·r² + b·r⁴ + c·r⁶ per colour channel, r normalised by the half diagonal."""

    center: np.ndarray
    normalising_radius: float
    coefficients: list  # (a, b, c) per channel
    max_data_radius: float

    def falloff(self, channel: int, x, y):
        k = self.coefficients[channel]
        dx, dy = (x - self.center[0]) / self.normalising_radius, (y - self.center[1]) / self.normalising_radius
        r2 = np.minimum(dx * dx + dy * dy, self.max_data_radius ** 2)
        return np.clip(1 + k[0] * r2 + k[1] * r2 * r2 + k[2] * r2 ** 3, 0.15, 1.05)

    def corner_falloff(self, channel: int) -> float:
        return float(self.falloff(channel, 0.0, 0.0))


def _alternating_fit(xs, ys, vs):
    """Alternating least squares for v = (p0 + p1·x + p2·y) · (1 + a·r² + b·r⁴ + c·r⁶)."""
    k = np.zeros(3)
    p = np.array([median_mean(vs), 0, 0])
    r2 = xs * xs + ys * ys
    for _ in range(25):
        v = 1 + k[0] * r2 + k[1] * r2 ** 2 + k[2] * r2 ** 3
        f = np.stack([v, v * xs, v * ys], axis=1)
        s = solve_linear_system(f.T @ f, f.T @ vs)
        if s is not None:
            p = s
        pl = p[0] + p[1] * xs + p[2] * ys
        f2 = np.stack([pl * r2, pl * r2 ** 2, pl * r2 ** 3], axis=1)
        s = solve_linear_system(f2.T @ f2 + 1e-9 * np.eye(3), f2.T @ (vs - pl))
        if s is not None:
            k = s
    return p, k


def _fit_vignetting_plane(plane, mask, center, norm, grid_x, grid_y):
    h, w = plane.shape
    cw, ch = max(2, w // grid_x), max(2, h // grid_y)
    xs, ys, vs = [], [], []
    for gx, gy, values, m in _cells(plane, mask, grid_x, grid_y, cw, ch):
        total = values.size
        values = values[(m >= 0.9) & np.isfinite(values)]
        if total == 0 or values.size * 2 < total:
            continue
        med = sigma_clipped(values, kappa=2, iterations=5)[0]
        if med <= 0:
            continue
        xs.append(((gx + 0.5) * cw - center[0]) / norm)
        ys.append(((gy + 0.5) * ch - center[1]) / norm)
        vs.append(med)
    if len(vs) < 30:
        return None
    xs, ys, vs = np.array(xs), np.array(ys), np.array(vs)
    r_max = float(np.hypot(xs, ys).max())
    if r_max < 0.6:
        return None
    keep = np.arange(len(vs))
    p, k = np.zeros(3), np.zeros(3)
    for rnd in range(3):
        p, k = _alternating_fit(xs[keep], ys[keep], vs[keep])
        if rnd == 2:
            break
        r2 = xs * xs + ys * ys
        model = (p[0] + p[1] * xs + p[2] * ys) * (1 + k[0] * r2 + k[1] * r2 ** 2 + k[2] * r2 ** 3)
        residuals = vs / np.maximum(model, 1e-12) - 1
        mad = median_mean(np.abs(residuals)) * 1.4826
        nxt = np.nonzero(np.abs(residuals) <= max(3 * mad, 0.01))[0]
        if len(nxt) < 30:
            break
        keep = nxt
    # Physical sanity: a lens only darkens towards the edge.
    edge = 1 + k[0] * r_max ** 2 + k[1] * r_max ** 4 + k[2] * r_max ** 6
    if not (0.15 < edge < 1.02):
        return None
    return k, r_max


def fit_vignetting(image: np.ndarray, mask: np.ndarray, grid_x: int = 32, grid_y: int = 24) -> VignettingModel | None:
    """The sky background is modelled as B(x, y) = P(x, y)·V(r), a plane P (linear light-pollution gradient)
    times the radial falloff, fitted by alternating least squares to κσ-clipped cell medians inside the sky
    mask, with outlier cells (Milky Way, light domes) rejected."""
    _, h, w = image.shape
    center = np.array([(w - 1) / 2, (h - 1) / 2])
    norm = float(np.hypot(*center))

    def falloff(k, r):
        return 1 + k[0] * r * r + k[1] * r ** 4 + k[2] * r ** 6

    # The lens shape comes from luma (best S/N); a colour channel may only deviate a little from it.
    luma = _fit_vignetting_plane(luminance(image), mask, center, norm, grid_x, grid_y)
    if luma is None:
        return None
    coefficients = []
    for c in range(3):
        ch = _fit_vignetting_plane(image[c], mask, center, norm, grid_x, grid_y)
        if ch is not None and abs(falloff(ch[0], luma[1]) - falloff(luma[0], luma[1])) <= 0.12:
            coefficients.append(ch[0])
        else:
            coefficients.append(luma[0])
    return VignettingModel(center, norm, coefficients, luma[1])


def apply_vignetting(model: VignettingModel, image: np.ndarray):
    _, h, w = image.shape
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float64)
    for c in range(3):
        image[c] /= model.falloff(c, xs, ys).astype(np.float32)


# MARK: - PSF and deconvolution (inverting J = M ⊛ I)


def estimate_psf(luma: np.ndarray, detection, background: float, saturation: float = 0.8,
                 max_stars: int = 60) -> np.ndarray | None:
    """Median-combined, sub-pixel-centred stamps of isolated, unsaturated stars."""
    usable = np.nonzero((detection.peak > 0) & (detection.peak + background < saturation) & (detection.fwhm > 0.3))[0]
    if usable.size < 5:
        return None
    fwhm = median_mean(detection.fwhm[usable])
    radius = min(max(int(np.ceil(2 * fwhm)), 3), 7)
    size = 2 * radius + 1
    pos = detection.positions[usable]
    d = np.linalg.norm(pos[:, None, :] - pos[None, :, :], axis=2)
    np.fill_diagonal(d, np.inf)
    offsets = np.arange(-radius, radius + 1)
    ox, oy = np.meshgrid(offsets, offsets)
    stamps = []
    for k in range(len(usable)):
        if len(stamps) >= max_stars:
            break
        if d[k].min() <= 2 * radius:  # isolation: no other detected star inside 2R
            continue
        stamp = bilinear(luma, pos[k, 0] + ox, pos[k, 1] + oy)
        if not np.all(np.isfinite(stamp)):
            continue
        stamp = np.maximum(stamp - background, 0)
        total = stamp.sum()
        if total <= 0:
            continue
        stamps.append(stamp / total)
    if len(stamps) < 5:
        return None
    psf = np.median(np.stack(stamps), axis=0)
    total = psf.sum()
    return (psf / total).astype(np.float32) if total > 0 else None


def _convolve(image: np.ndarray, kernel: np.ndarray) -> np.ndarray:
    """Correlation with edge extension (vImageConvolve_PlanarF + kvImageEdgeExtend)."""
    r = kernel.shape[0] // 2
    padded = np.pad(image, r, mode="edge")
    return fftconvolve(padded, kernel[::-1, ::-1], mode="valid").astype(np.float32)


def richardson_lucy(observed: np.ndarray, psf: np.ndarray, background: float, noise: float,
                    iterations: int = 15) -> np.ndarray:
    """Richardson–Lucy (Richardson 1972; Lucy 1974) for J = a ⊛ I + b with Poisson noise:
        I ← I ⊙ ( ã ⊛ ( J ⊘ (a ⊛ I + b) ) )
    Noise protection: the update is only kept where the signal exceeds the background by a few σ (soft mask),
    which plays the role of damping and avoids amplifying sky noise."""
    eps = 1e-9
    flipped = psf[::-1, ::-1]
    estimate = np.maximum(observed - background, eps).astype(np.float32)
    for _ in range(iterations):
        model = _convolve(estimate, psf) + background
        ratio = np.clip(observed / np.maximum(model, eps), 0.2, 5).astype(np.float32)
        estimate *= _convolve(ratio, flipped)
    lo, hi = 3 * noise, 10 * noise
    m = np.clip((observed - background - lo) / max(hi - lo, eps), 0, 1)
    return (m * (estimate + background) + (1 - m) * observed).astype(np.float32)


# MARK: - Colour


def background_offsets(image: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """Per-channel offsets that equalise the sky background (light-pollution colour cast) to the luma background."""
    target = background_and_noise(luminance(image), mask)[0]
    return np.array([target - background_and_noise(image[c], mask)[0] for c in range(3)], dtype=np.float32)


def star_gains(image: np.ndarray, detection, background: float) -> np.ndarray:
    """White balance so that the average star is neutral (aperture photometry on detected stars)."""
    _, h, w = image.shape
    flux = np.zeros(3)
    for k in range(min(100, detection.count)):
        radius = max(2, int(np.ceil(1.5 * detection.fwhm[k])))
        cx, cy = int(round(detection.positions[k, 0])), int(round(detection.positions[k, 1]))
        if cx - radius < 0 or cy - radius < 0 or cx + radius >= w or cy + radius >= h:
            continue
        f = (image[:, cy - radius:cy + radius + 1, cx - radius:cx + radius + 1].astype(np.float64)
             - background).sum(axis=(1, 2))
        if np.all(f > 0):
            flux += f
    if not np.all(flux > 0):
        return np.ones(3, dtype=np.float32)
    return np.array([np.clip(flux[1] / flux[0], 0.25, 4), 1, np.clip(flux[1] / flux[2], 0.25, 4)], dtype=np.float32)


def apply_gains(gains: np.ndarray, image: np.ndarray, background: float):
    for c in range(3):
        image[c] = (image[c] - background) * gains[c] + background


# MARK: - Clipped highlights


def clipping(raw: np.ndarray, start: float = 0.85, full: float = 0.97) -> np.ndarray:
    """Soft clipping weight from the *unprocessed* stack (1.0 = sensor white level) on the brightest channel."""
    return np.clip((raw.max(axis=0) - start) / (full - start), 0, 1).astype(np.float32)


def neutralize_highlights(image: np.ndarray, weight: np.ndarray):
    """Clipped pixels have lost their colour; channel gains would turn them magenta or green. Blends them
    towards neutral at their brightest channel."""
    m = image.max(axis=0)
    for c in range(3):
        image[c] += weight * (m - image[c])


# MARK: - Display stretch


@dataclass
class AsinhStretch:
    """Colour-preserving arcsinh stretch (Lupton et al. 2004, PASP 116, 133):
    (R, G, B) ← (R, G, B)·F(I)/I,  I = (R + G + B)/3,  F(I) = asinh(I/β)/asinh(W/β)."""

    black: float
    white: float
    beta: float

    def __post_init__(self):
        self.white = max(self.white, self.black + 1e-6)
        self.beta = max(self.beta, 1e-9)

    @staticmethod
    def automatic(luma: np.ndarray, mask: np.ndarray | None, background_level: float = 0.12,
                  black_sigmas: float = 2) -> "AsinhStretch":
        """Chooses β so that the sky background lands at `background_level` of the output range."""
        bg, sigma = background_and_noise(luma, mask)
        noise = max(sigma, 1e-7)
        black = bg - black_sigmas * noise
        stride = max(1, int(np.sqrt(luma.size / 300_000)))
        s = sample(luma, stride)
        idx = min(s.size - 1, int(round((s.size - 1) * 0.9995))) if s.size else 0
        white = max(float(np.partition(s, idx)[idx]) if s.size else bg, bg + 20 * noise)
        rng, x = white - black, bg - black
        lo, hi = 1e-9, rng * 100
        for _ in range(60):
            mid = np.sqrt(lo * hi)
            f = np.arcsinh(x / mid) / np.arcsinh(rng / mid)
            if f > background_level:
                lo = mid
            else:
                hi = mid
        return AsinhStretch(black, white, float(np.sqrt(lo * hi)))

    def apply(self, image: np.ndarray) -> np.ndarray:
        norm = np.arcsinh((self.white - self.black) / self.beta)
        rgb = np.maximum(image - self.black, 0)
        intensity = rgb.mean(axis=0)
        with np.errstate(divide="ignore", invalid="ignore"):
            scale = np.where(intensity > 0, np.arcsinh(intensity / self.beta) / norm / intensity, 0)
        out = rgb * scale
        m = out.max(axis=0)
        out = np.where(m > 1, out / np.maximum(m, 1e-12), out)
        return out.astype(np.float32)


# MARK: - Finisher


@dataclass
class FinishingOptions:
    remove_gradient: bool = True
    # Radial lens-falloff post-filter (Bayer RAW has no lens-shading correction).
    correct_vignetting: bool = True
    deconvolution_iterations: int = 15
    color_calibration: bool = True
    # Background brightness after stretching (0…1).
    background_level: float = 0.12
    # Gravity direction in the sensor buffer; enables the horizon-line sky mask.
    ground_direction: str | None = None
    # Sticky ground mask from stacking (see `SkyMaskBuilder.occlusion_mask`).
    ground_prior: np.ndarray | None = None
    # Largest sky displacement over the session (px). Below MASK_FREE_DRIFT the static scenery is as sharp
    # in the registered stack as in the foreground one, so no mask is needed.
    sky_drift: float | None = None
    # Precomputed sky mask; None → built from the stacks.
    sky_mask: np.ndarray | None = None


# Sky drift (px) below which no mask is applied: star trails shorter than the PSF.
MASK_FREE_DRIFT = 2.0


@dataclass
class FinishedImage:
    linear: np.ndarray  # calibrated, blended linear image for Siril / PixInsight
    display: np.ndarray  # stretched display image, 0…1
    sky_mask: np.ndarray
    psf: np.ndarray | None
    notes: list = field(default_factory=list)


def finish(stack: StackResult, options: FinishingOptions | None = None) -> FinishedImage:
    """mask → vignetting → background neutralisation → gradient removal → PSF + Richardson–Lucy on the sky →
    star-based white balance → α-blend (sky / foreground) → clipped highlights → asinh stretch.
    The mask only decides which stack a pixel comes from and which pixels feed the statistics. Every correction
    is applied identically to both layers and the blend is stretched once, so where the stacks agree – any
    featureless area, i.e. most mask mistakes – the seam is invisible."""
    options = options or FinishingOptions()
    notes = []
    mask = options.sky_mask
    if mask is None:
        mask = SkyMaskBuilder(options.ground_direction, options.ground_prior).build(stack)
    notes.append(f"Sky mask: {mask.mean() * 100:.0f}% of the frame")
    sky_region = (mask >= 0.9).astype(np.float32)
    has_sky = sky_region.sum() > mask.size * 0.05
    # With negligible drift the registered stack is as sharp on the scenery as the static one (and has the
    # robust rejection), so it is used everywhere; the mask still selects the statistics region.
    alpha = mask
    if options.sky_drift is not None and options.sky_drift < MASK_FREE_DRIFT:
        alpha = (stack.sky_weight > 0).astype(np.float32)
        notes.append(f"Sky drift {options.sky_drift:.1f} px: registered stack used for the whole frame")

    foreground = stack.foreground.copy()
    # Pixels never covered by the registered stack fall back to the foreground.
    sky = np.where(stack.sky_weight[None] > 0, stack.sky, foreground).astype(np.float32)
    sky_clipping, fg_clipping = clipping(sky), clipping(foreground)

    if options.correct_vignetting and has_sky:
        model = fit_vignetting(sky, sky_region)
        if model is not None:
            apply_vignetting(model, sky)
            apply_vignetting(model, foreground)
            notes.append("Vignetting corrected: corners at {:.0f}% / {:.0f}% / {:.0f}% of centre brightness (R/G/B)"
                         .format(*(model.corner_falloff(c) * 100 for c in range(3))))

    if has_sky:
        offsets = background_offsets(sky, sky_region)
        sky += offsets[:, None, None]
        foreground += offsets[:, None, None]
        if options.remove_gradient:
            correction = gradient_correction(sky, sky_region)
            apply_gradient(correction, sky)
            apply_gradient(correction, foreground)
            notes.append("Background gradient removed (quadratic surface + radial terms)")

    sky_luma = luminance(sky)
    stats_mask = sky_region if has_sky else None
    bg, noise = background_and_noise(sky_luma, stats_mask)
    detection = StarDetector().detect(sky_luma, stats_mask)
    notes.append(f"Stars in stack: {detection.count}")

    psf = None
    if options.deconvolution_iterations > 0:
        psf = estimate_psf(sky_luma, detection, bg)
        if psf is not None:
            sharpened = richardson_lucy(sky_luma, psf, bg, noise, options.deconvolution_iterations)
            before = sky_luma - bg
            with np.errstate(divide="ignore", invalid="ignore"):
                ratio = np.clip((sharpened - bg) / before, 0, 4)
            update = before > noise
            for c in range(3):
                sky[c] = np.where(update, (sky[c] - bg) * ratio + bg, sky[c])
            notes.append(f"Richardson–Lucy deconvolution: {options.deconvolution_iterations} iterations, "
                         f"PSF {psf.shape[1]}×{psf.shape[0]}")

    if options.color_calibration and detection.count >= 10:
        gains = star_gains(sky, detection, bg)
        apply_gains(gains, sky, bg)
        apply_gains(gains, foreground, bg)
        notes.append(f"White balance from stars: R×{gains[0]:.2f} B×{gains[2]:.2f}")

    linear = (alpha * sky + (1 - alpha) * foreground).astype(np.float32)
    neutralize_highlights(linear, alpha * sky_clipping + (1 - alpha) * fg_clipping)

    stretch = AsinhStretch.automatic(luminance(linear), stats_mask, options.background_level)
    return FinishedImage(linear, stretch.apply(linear), alpha.astype(np.float32), psf, notes)
