"""Undoes a star-trail photo: finds the trails, puts every star back at one point of its arc and repaints the sky.

A static camera sees the sky turn about the celestial pole, so every trail is the same arc of hour angle,
only at a different polar distance. In the sky coordinates of the pole (ρ = angle from the pole,
φ = hour angle about it) all trails become horizontal segments of one common length and one common
brightness pattern along φ (the exposure timeline: one long exposure, or a stack with gaps between frames).
The tool:

1. fits the geometry – pole, focal length and principal point – by maximising how much of the image is
   explained by concentric rings of constant ρ (rectilinear lens; arcs are conics, not circles, off-axis);
2. resamples the background-subtracted luma onto a (ρ, φ) grid;
3. estimates the common kernel along φ by aligning and median-stacking isolated trails;
4. detects trails with that kernel as a matched filter (non-maximum suppression in ρ and φ);
5. replaces trail pixels with the sky background and renders each star as a Gaussian at the start, middle
   or end of its trail, with the trail's peak brightness and mean colour.

Deconvolution along φ is deliberately not used: the kernel is many degrees long and box-like, its spectrum has
zeros, trails are clipped and JPEG-compressed, so the inverse filter is dominated by ringing.
"""

from __future__ import annotations

import argparse
import sys
import time
import warnings
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np
from scipy import ndimage
from scipy.optimize import minimize
from scipy.spatial import cKDTree

try:
    import cv2
except ImportError:  # optional, as in stacking.py
    cv2 = None

from .finishing import GROUND_FROM_ORIENTATION, SkyMaskBuilder
from .imaging import box_blur, luminance, sigma_clipped
from .loader import LoadOptions, _load_rgb


# MARK: - Geometry


@dataclass(frozen=True)
class SkyGeometry:
    """Pinhole camera (focal length and principal point in pixels) plus the pixel where the pole projects."""

    width: int
    height: int
    focal: float
    cx: float
    cy: float
    pole_x: float
    pole_y: float

    @staticmethod
    def initial(width: int, height: int, focal: float, pole) -> "SkyGeometry":
        return SkyGeometry(width, height, focal, (width - 1) / 2, (height - 1) / 2, float(pole[0]), float(pole[1]))

    @property
    def field_of_view(self) -> float:
        return float(np.degrees(2 * np.arctan(max(self.width, self.height) / 2 / self.focal)))

    def rays(self, x, y) -> np.ndarray:
        x, y = np.asarray(x, dtype=np.float64), np.asarray(y, dtype=np.float64)
        v = np.stack([(x - self.cx) / self.focal, (y - self.cy) / self.focal, np.ones_like(x)], axis=-1)
        return v / np.linalg.norm(v, axis=-1, keepdims=True)

    def frame(self) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        """Pole direction and an orthonormal basis of the plane perpendicular to it."""
        p = self.rays(self.pole_x, self.pole_y)
        a = np.array([0.0, 1.0, 0.0]) if abs(p[1]) < 0.9 else np.array([1.0, 0.0, 0.0])
        e1 = np.cross(a, p)
        e1 /= np.linalg.norm(e1)
        return p, e1, np.cross(p, e1)

    def sky(self, x, y) -> tuple[np.ndarray, np.ndarray]:
        """(ρ, φ) in radians, φ in [0, 2π)."""
        p, e1, e2 = self.frame()
        v = self.rays(x, y)
        rho = np.arccos(np.clip(v @ p, -1, 1))
        phi = np.mod(np.arctan2(v @ e2, v @ e1), 2 * np.pi)
        return rho, phi

    def pixels(self, rho, phi) -> tuple[np.ndarray, np.ndarray]:
        """Pixel positions of sky points; far outside the image when behind the camera."""
        p, e1, e2 = self.frame()
        rho, phi = np.asarray(rho, dtype=np.float64), np.asarray(phi, dtype=np.float64)
        s = np.sin(rho)
        v = (np.cos(rho)[..., None] * p + (s * np.cos(phi))[..., None] * e1 + (s * np.sin(phi))[..., None] * e2)
        z = v[..., 2]
        ok = z > 1e-9
        zs = np.where(ok, z, 1)
        x = np.where(ok, self.focal * v[..., 0] / zs + self.cx, -1e6)
        y = np.where(ok, self.focal * v[..., 1] / zs + self.cy, -1e6)
        return x, y

    def boundary(self, n: int = 200) -> tuple[np.ndarray, np.ndarray]:
        t = np.linspace(0, 1, n)
        w, h = self.width - 1, self.height - 1
        x = np.concatenate([t * w, np.full(n, w), (1 - t) * w, np.zeros(n)])
        y = np.concatenate([np.zeros(n), t * h, np.full(n, h), (1 - t) * h])
        return x, y

    def pole_inside(self, margin: float = 0) -> bool:
        return (margin <= self.pole_x <= self.width - 1 - margin) and (margin <= self.pole_y <= self.height - 1 - margin)

    def rho_range(self) -> tuple[float, float]:
        rho, _ = self.sky(*self.boundary())
        return (0.0 if self.pole_inside() else float(rho.min())), float(rho.max())

    def phi_increases_clockwise(self) -> bool:
        """Whether growing φ runs clockwise on screen (y down) around the pole."""
        lo, hi = self.rho_range()
        rho = lo + 0.25 * (hi - lo) + 1e-3
        _, phi = self.sky(*self.boundary(16))
        x0, y0 = self.pixels(rho, phi[0])
        x1, y1 = self.pixels(rho, phi[0] + 0.01)
        cross = (x0 - self.pole_x) * (y1 - y0) - (y0 - self.pole_y) * (x1 - x0)
        return bool(cross > 0)


class Concentricity:
    """Share of the high-passed image variance explained by arcs of constant ρ: bins of `bin_px` pixels (at the
    pole's scale) along ρ times `sectors` sectors of φ, with the small-sample bias of the bin means removed.
    Whole rings (one sector) would let unrelated trails at the same ρ collide in a bin, which makes the score
    noisy when trails are short or sparse; sectors keep it a measure of how well each trail follows its arc."""

    def __init__(self, image: np.ndarray, stride: int, center=None, radius: float | None = None, sectors: int = 24):
        self.sectors = sectors
        h, w = image.shape
        ys, xs = np.mgrid[0:h:stride, 0:w:stride]
        x, y, v = xs.ravel().astype(np.float64), ys.ravel().astype(np.float64), image[::stride, ::stride].ravel()
        if center is not None and radius is not None:
            keep = np.hypot(x - center[0], y - center[1]) < radius
            x, y, v = x[keep], y[keep], v[keep]
        self.x, self.y = x, y
        self.v = v.astype(np.float64) - v.mean()
        self.total = float(np.sum(self.v * self.v)) or 1.0

    def score(self, g: SkyGeometry, bin_px: float = 0.5) -> float:
        rho, phi = g.sky(self.x, self.y)
        b = (rho * g.focal / bin_px).astype(np.int64) * self.sectors + (phi * (self.sectors / (2 * np.pi))).astype(np.int64)
        n = np.bincount(b)
        s = np.bincount(b, self.v)
        ok = n > 0
        explained = np.sum(s[ok] ** 2 / n[ok]) - ok.sum() * self.total / self.v.size
        return float(explained / self.total)


def highpass(residual: np.ndarray) -> np.ndarray:
    top = float(np.percentile(residual[::4, ::4], 99.9))
    c = np.clip(residual, 0, max(top, 1e-6))
    return (c - ndimage.gaussian_filter(c, 6)).astype(np.float32)


def gradient_pole(residual: np.ndarray, step: int = 4) -> np.ndarray:
    """Rough pole as the robust least-squares meeting point of the lines across the trails (circle model)."""
    small = ndimage.gaussian_filter(np.clip(residual, 0, None), 1.5)[::step, ::step]
    gy, gx = np.gradient(small)
    w = gx * gx + gy * gy
    keep = w > np.percentile(w, 90)
    ys, xs = np.nonzero(keep)
    gx, gy, w = gx[keep], gy[keep], w[keep]
    n = np.hypot(gx, gy)
    tx, ty = -gy / n, gx / n  # trail direction; the pole lies on the line through (x, y) along the gradient
    p = np.array([small.shape[1] / 2, small.shape[0] / 2])
    scale = np.inf
    for _ in range(20):
        d = tx * (p[0] - xs) + ty * (p[1] - ys)
        ww = w / (1 + (d / scale) ** 2)
        a = np.array([[np.sum(ww * tx * tx), np.sum(ww * tx * ty)], [np.sum(ww * tx * ty), np.sum(ww * ty * ty)]])
        c = tx * xs + ty * ys
        p = np.linalg.solve(a, [np.sum(ww * tx * c), np.sum(ww * ty * c)])
        scale = 3 * np.median(np.abs(tx * (p[0] - xs) + ty * (p[1] - ys))) + 1e-3
    return p * step


def _nelder_mead(f, x0, steps, xatol, maxfev):
    x0 = np.asarray(x0, dtype=np.float64)
    simplex = np.vstack([x0, x0 + np.diag(steps)])
    return minimize(f, x0, method="Nelder-Mead",
                    options=dict(initial_simplex=simplex, xatol=xatol, fatol=1e-10, maxfev=maxfev)).x


def fit_geometry(residual: np.ndarray, pole=None, focal: float | None = None, fit_center: bool = True,
                 log=print) -> SkyGeometry:
    h, w = residual.shape
    hp = highpass(residual)
    if pole is None:
        pole = gradient_pole(residual)
        log(f"pole from trail directions: ({pole[0]:.0f}, {pole[1]:.0f})")
        g = SkyGeometry.initial(w, h, 1e6, pole)
        if g.pole_inside(margin=50):
            # Near the pole the lens projection does not matter yet: concentric circles, coarse to fine.
            for half, step, blur, bin_px in ((160, 8, 3, 2.0), (12, 1, 0, 0.5)):
                c = Concentricity(ndimage.gaussian_filter(hp, blur) if blur else hp, 2, pole, 400 + half)
                best = max(((c.score(replace(g, pole_x=pole[0] + dx, pole_y=pole[1] + dy), bin_px), dx, dy)
                            for dy in range(-half, half + 1, step) for dx in range(-half, half + 1, step)))
                pole = (pole[0] + best[1], pole[1] + best[2])
            log(f"pole from the rings around it: ({pole[0]:.1f}, {pole[1]:.1f})")

    # Coarse to fine: trails are a few pixels wide, so the sharp score is rugged; the blurred one with wider bins
    # has a wide basin for the lens scan and the first joint fit.
    coarse = Concentricity(ndimage.gaussian_filter(hp, 2.0), 4)
    fine = Concentricity(hp, 2)

    def refine(g: SkyGeometry, c: Concentricity, bin_px: float, steps, maxfev: int, free_focal: bool,
               free_center: bool) -> SkyGeometry:
        """Nelder–Mead over the pole and optionally log(focal) and the principal point;
        `steps` = initial simplex steps for (pole px, log focal, principal point px)."""
        names = ["pole_x", "pole_y"] + (["log_focal"] if free_focal else []) + (["cx", "cy"] if free_center else [])
        start = dict(pole_x=g.pole_x, pole_y=g.pole_y, log_focal=np.log(g.focal), cx=g.cx, cy=g.cy)
        step = dict(pole_x=steps[0], pole_y=steps[0], log_focal=steps[1], cx=steps[2], cy=steps[2])

        def unpack(q):
            d = dict(start, **dict(zip(names, q)))
            return replace(g, pole_x=float(d["pole_x"]), pole_y=float(d["pole_y"]),
                           focal=float(np.exp(d["log_focal"])), cx=float(d["cx"]), cy=float(d["cy"]))

        q = _nelder_mead(lambda q: -c.score(unpack(q), bin_px), [start[n] for n in names], [step[n] for n in names],
                         0.02, maxfev)
        return unpack(q)

    if focal is None:
        candidates = []
        for fov in (30, 40, 50, 60, 70, 80, 90, 100, 115, 130):
            f = (max(w, h) / 2) / np.tan(np.radians(fov) / 2)
            g = refine(SkyGeometry.initial(w, h, f, pole), coarse, 1.5, (6, 0, 0), 80, False, False)
            candidates.append((coarse.score(g, 1.5), fov, g))
        score, fov, g = max(candidates, key=lambda t: t[0])
        log(f"lens scan: best field of view {fov}° (concentricity {score:.4f})")
    else:
        g = SkyGeometry.initial(w, h, focal, pole)
    free_focal = focal is None
    g = refine(g, coarse, 1.5, (3, 0.05, 30), 500, free_focal, fit_center)
    g = refine(g, fine, 0.5, (1, 0.015, 8), 400, free_focal, fit_center)
    log(f"geometry: pole ({g.pole_x:.1f}, {g.pole_y:.1f}), focal {g.focal:.0f} px "
        f"(FOV {g.field_of_view:.1f}°), principal point ({g.cx:.0f}, {g.cy:.0f}), "
        f"concentricity {fine.score(g):.4f}")
    return g


# MARK: - Polar grid


@dataclass
class PolarGrid:
    """Rows = ρ from `rho0` in steps of `drho`, columns = φ over the full circle (wrapping)."""

    geometry: SkyGeometry
    rho0: float
    drho: float
    nrho: int
    nphi: int

    @staticmethod
    def covering(g: SkyGeometry, row_px: float = 0.75, max_columns: int = 16384) -> "PolarGrid":
        lo, hi = g.rho_range()
        drho = row_px / g.focal
        x, y = g.boundary()
        rho, phi = g.sky(x, y)
        x1, y1 = g.pixels(rho, phi + 1e-4)
        per_radian = float(np.max(np.hypot(x1 - x, y1 - y)) / 1e-4)  # pixels per radian of φ, worst case
        nphi = int(np.clip(np.ceil(2 * np.pi * per_radian / 256) * 256, 1024, max_columns))
        return PolarGrid(g, lo, drho, int(np.ceil((hi - lo) / drho)) + 1, nphi)

    @property
    def dphi(self) -> float:
        return 2 * np.pi / self.nphi

    def degrees(self, columns) -> float:
        return float(np.asarray(columns) * 360 / self.nphi)

    def pixels(self, rows, cols) -> tuple[np.ndarray, np.ndarray]:
        return self.geometry.pixels(self.rho0 + np.asarray(rows) * self.drho, np.asarray(cols) * self.dphi)

    def coords(self, x, y) -> tuple[np.ndarray, np.ndarray]:
        rho, phi = self.geometry.sky(x, y)
        return (rho - self.rho0) / self.drho, phi / self.dphi

    def maps(self) -> tuple[np.ndarray, np.ndarray]:
        mx = np.empty((self.nrho, self.nphi), np.float32)
        my = np.empty_like(mx)
        cols = np.arange(self.nphi)
        for r in range(self.nrho):
            x, y = self.pixels(np.full(self.nphi, r), cols)
            mx[r], my[r] = x, y
        return mx, my


def remap(image: np.ndarray, mx: np.ndarray, my: np.ndarray, fill=np.nan) -> np.ndarray:
    """Bilinear samples of `image` at (mx, my); `fill` outside. OpenCV when installed (≈ 10× faster)."""
    image = np.ascontiguousarray(image, dtype=np.float32)
    out = np.empty(mx.shape, np.float32)
    for i in range(0, mx.shape[0], 4096):  # OpenCV maps are limited to 32767 in each dimension
        x, y = mx[i:i + 4096].astype(np.float32), my[i:i + 4096].astype(np.float32)
        if cv2 is not None:
            out[i:i + 4096] = cv2.remap(image, x, y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT,
                                        borderValue=fill)
        else:
            h, w = image.shape
            inside = (x >= -0.5) & (y >= -0.5) & (x <= w - 0.5) & (y <= h - 0.5)
            v = ndimage.map_coordinates(image, [y, x], order=1, mode="nearest")
            out[i:i + 4096] = np.where(inside, v, fill)
    return out


# MARK: - Kernel and detection


@dataclass
class TrailKernel:
    """Brightness along φ of one trail, normalised to mean 1 over its support, starting at index 0
    (lowest φ). Same for every star: it is the exposure timeline."""

    profile: np.ndarray

    @property
    def length(self) -> int:
        return len(self.profile)

    @staticmethod
    def box(columns: int) -> "TrailKernel":
        return TrailKernel(np.ones(max(columns, 3), np.float32))


def _wrap_box(a: np.ndarray, size: int) -> np.ndarray:
    """Mean over `size` columns starting at each column (circular)."""
    c = np.cumsum(np.concatenate([a, a[:, :size]], axis=1), axis=1, dtype=np.float64)
    c = np.concatenate([np.zeros((a.shape[0], 1)), c], axis=1)
    n = a.shape[1]
    return ((c[:, size:size + n] - c[:, :n]) / size).astype(np.float32)


def _suppress(rows, cols, score, row_radius, col_radius, nphi):
    """Greedy non-maximum suppression in (ρ, φ) boxes; returns kept indices, strongest first."""
    order = np.argsort(-score, kind="stable")
    pts = np.stack([rows / row_radius, cols / col_radius], axis=1)
    period = nphi / col_radius
    tree = cKDTree(pts)
    taken = np.zeros(len(rows), bool)
    kept = []
    for i in order:
        if taken[i]:
            continue
        kept.append(i)
        for p in (pts[i], pts[i] + [0, period], pts[i] - [0, period]):
            for j in tree.query_ball_point(p, 1.0, p=np.inf):
                taken[j] = True
    return np.array(kept, dtype=np.int64)


def _peaks(response: np.ndarray, rows_ok: np.ndarray, threshold: float, row_size: int, col_size: int):
    mx = ndimage.maximum_filter(response, size=(row_size, max(col_size, 1)), mode=("nearest", "wrap"))
    pk = (response >= mx) & (response > threshold) & rows_ok[:, None]
    r, c = np.nonzero(pk)
    return r, c, response[r, c]


def estimate_kernel(q: np.ndarray, valid: np.ndarray, rows_ok: np.ndarray, noise: float, nphi: int,
                    start_degrees: float = 8.0, log=print) -> TrailKernel:
    """Iterates: box detection with the current length → isolated strong trails → aligned median profile →
    support above half its contrast → new length. Starts short: a box longer than the trails locks onto
    neighbouring trails at the same ρ. When it does not settle (it can alternate between the true length and
    one that swallows a neighbour's piece), the pass whose template stands out most from its flanks wins."""
    length = max(int(start_degrees / 360 * nphi), 8)
    qv = np.where(valid, q, 0)
    template = None
    passes = []
    for it in range(6):
        cov = _wrap_box(valid.astype(np.float32), length)
        s = _wrap_box(qv, length) / np.maximum(cov, 1e-3)
        s[cov < 0.999] = 0
        r, c, v = _peaks(s, rows_ok, 3 * noise, 9, length)
        keep = _suppress(r, c, v, 8, 1.6 * length, nphi)[:3000]
        r, c, v = r[keep], c[keep], v[keep]
        # isolated: no other detection at a similar ρ within 1.6 lengths
        tree = cKDTree(np.stack([r / 8.0, c / (1.6 * length)], 1))
        lonely = np.array([len(tree.query_ball_point([ri / 8.0, ci / (1.6 * length)], 1.0, p=np.inf)) == 1
                           for ri, ci in zip(r, c)], dtype=bool)
        r, c = r[lonely][:400], c[lonely][:400]
        if len(r) < 20:
            break
        half = min(2 * length, nphi // 2 - 1)
        cols = (c[:, None] + np.arange(-half, half + 1)[None, :]) % nphi
        prof = q[r[:, None], cols]
        prof = prof / np.maximum(np.percentile(prof, 90, axis=1, keepdims=True), 1e-6)
        tmpl = np.median(prof, axis=0)
        n = prof.shape[1]
        limit = max(length // 2, 2)
        for _ in range(6):
            cc = np.fft.irfft(np.fft.rfft(prof, axis=1) * np.conj(np.fft.rfft(tmpl))[None, :], n, axis=1)
            cc[:, limit + 1:n - limit] = -np.inf
            lag = np.argmax(cc, axis=1)
            lag = np.where(lag > n // 2, lag - n, lag)
            idx = (np.arange(n)[None, :] + lag[:, None]) % n
            prof = np.take_along_axis(prof, idx, axis=1)
            tmpl = np.median(prof, axis=0)
        smooth = ndimage.uniform_filter1d(tmpl, max(3, int(0.3 / 360 * nphi)), mode="nearest")
        core = smooth[n // 2 - length // 2:n // 2 + length // 2 + 1]
        low, high = np.percentile(smooth, 15), np.percentile(core, 80)
        on = smooth > (low + high) / 2
        on = ndimage.binary_closing(on, structure=np.ones(max(3, int(2.0 / 360 * nphi))))  # bridge frame gaps
        labels, _ = ndimage.label(on)
        centre = labels[n // 2] or labels[np.argmax(smooth * on)]
        span = np.flatnonzero(labels == centre)
        a, b = int(span[0]), int(span[-1])
        template = np.clip(tmpl[a:b + 1] - low, 0, None)
        new = b - a + 1
        flanks = np.r_[smooth[:max(a - 5, 0)], smooth[b + 6:]]
        contrast = float(np.mean(smooth[a:b + 1]) - (np.mean(flanks) if flanks.size else low))
        passes.append((contrast, template))
        log(f"kernel pass {it + 1}: {len(r)} isolated trails, length {360 * new / nphi:.2f}°")
        tolerance = max(2, 0.02 * length)
        if abs(new - length) <= tolerance:
            break
        if len(passes) >= 3 and abs(new - len(passes[-3][1])) <= tolerance:  # going round in a cycle
            template = max(passes, key=lambda t: t[0])[1]
            log(f"kernel alternates, keeping {360 * len(template) / nphi:.2f}° (strongest template)")
            break
        length = new
    else:
        if passes:
            template = max(passes, key=lambda t: t[0])[1]
    if template is None:
        log("too few isolated trails for the kernel, using a box")
        return TrailKernel.box(length)
    return TrailKernel((template / max(template.mean(), 1e-9)).astype(np.float32))


@dataclass
class Trails:
    rows: np.ndarray  # ρ row of the trail
    cols: np.ndarray  # φ column where the kernel starts
    amplitude: np.ndarray  # matched-filter brightness (luma residual)


def _circular_correlate(rows: np.ndarray, kernel_full: np.ndarray, chunk: int = 256) -> np.ndarray:
    """out[r, c] = Σ_j rows[r, c + j]·kernel_full[j] (circular along φ)."""
    n = rows.shape[1]
    kf = np.conj(np.fft.rfft(kernel_full))
    out = np.empty(rows.shape, np.float32)
    for i in range(0, rows.shape[0], chunk):
        out[i:i + chunk] = np.fft.irfft(np.fft.rfft(rows[i:i + chunk], axis=1) * kf, n, axis=1)
    return out


def detect_trails(q: np.ndarray, valid: np.ndarray, rows_ok: np.ndarray, kernel: TrailKernel, noise: float,
                  threshold_sigma: float) -> Trails:
    """Matched filter along φ, normalised by the visible part of the kernel (trails leaving the frame keep their
    brightness); peaks are local maxima over ±1 row and one trail length (a wider row window would hide faint
    trails next to bright ones). The position is then refined on the derivative along φ, which locks onto the
    trail's ends instead of the middle of a broad hump. Two trails overlapping at almost the same ρ make one
    hump: the weaker one is not detected (its pixels are still repainted by the faint-trail mask). Detecting
    on the derivative alone would split them, but every step inside a trail (frame gaps, frames of different
    brightness) echoes there."""
    nrho, nphi = q.shape
    k = np.zeros(nphi, np.float32)
    k[:kernel.length] = kernel.profile
    kk = float(np.sum(k * k))
    response = _circular_correlate(np.where(valid, q, 0), k)
    coverage = _circular_correlate(valid.astype(np.float32), k * k) / kk
    response = np.where(coverage < 0.3, 0, response / kk / np.maximum(coverage, 0.05))
    r, c, v = _peaks(response, rows_ok, threshold_sigma * noise, 3, kernel.length)
    keep = _suppress(r, c, v, 2.5, kernel.length / 2, nphi)  # flat (clipped) trails tie on adjacent rows
    r, c, v = r[keep], c[keep], v[keep]
    del response, coverage

    # Refinement: best alignment of the ends within a quarter of a trail.
    s = max(1.0, kernel.length / 30)
    ks = ndimage.gaussian_filter1d(k, s, mode="wrap")
    kd = (np.roll(ks, -1) - np.roll(ks, 1)) / 2
    rows = np.unique(np.clip(r[:, None] + np.arange(-1, 2)[None, :], 0, nrho - 1))
    qd = ndimage.gaussian_filter1d(np.where(valid[rows], q[rows], 0), s, axis=1, mode="wrap")
    qd = (np.roll(qd, -1, axis=1) - np.roll(qd, 1, axis=1)) / 2
    # Where a trail leaves the frame or goes behind the landscape it just stops: that is not one of its ends.
    edge = ndimage.maximum_filter1d((~valid[rows]).astype(np.uint8), 2 * int(np.ceil(3 * s)) + 3, axis=1,
                                    mode="wrap") > 0
    qd[edge] = 0
    ends = np.full((nrho, nphi), np.nan, np.float32)
    ends[rows] = _circular_correlate(qd, kd) / float(np.sum(kd * kd))
    reach = kernel.length // 4
    win = (c[:, None] + np.arange(-reach, reach + 1)[None, :]) % nphi
    best = np.full(len(r), -np.inf)
    shift = np.zeros(len(r), np.int64)
    for dr in (-1, 0, 1):
        vals = ends[np.clip(r + dr, 0, nrho - 1)[:, None], win]
        i = np.nanargmax(np.where(np.isfinite(vals), vals, -np.inf), axis=1)
        m = vals[np.arange(len(r)), i]
        better = m > best
        best[better], shift[better] = m[better], i[better] - reach
    c = np.where(best > 0.5 * v, (c + shift) % nphi, c)

    # The trail must really be there along its length, not two neighbours meeting under the window.
    cols = (c[:, None] + np.arange(kernel.length)[None, :]) % nphi
    seg = q[r[:, None], cols]
    ok_seg = valid[r[:, None], cols]
    on = kernel.profile[None, :] > 0.5
    lit = ((seg > 0.4 * v[:, None]) & on & ok_seg).sum(1) / np.maximum((on & ok_seg).sum(1), 1)
    good = (lit > 0.6) & ((on & ok_seg).sum(1) >= 0.3 * on.sum())
    return Trails(r[good], c[good], v[good])


# MARK: - Image


def _fill_holes(grid: np.ndarray, have: np.ndarray) -> np.ndarray:
    """Fills missing cells of a coarse grid from ever larger neighbourhoods (normalised convolution)."""
    if not have.any():
        return np.zeros_like(grid, dtype=np.float64)
    out = np.where(have, grid, 0.0).astype(np.float64)
    done = have.copy()
    for sigma in (1, 2, 4, 8, 16, 32):
        if done.all():
            break
        n = ndimage.gaussian_filter(np.where(have, grid, 0.0), sigma)
        d = ndimage.gaussian_filter(have.astype(np.float64), sigma)
        fill = (d > 0.05) & ~done
        out[fill] = n[fill] / d[fill]
        done |= fill
    out[~done] = float(np.median(grid[have]))
    return out


def _upsample(grid: np.ndarray, factor: int, shape) -> np.ndarray:
    h, w = shape
    yy = (np.arange(h) + 0.5) / factor - 0.5
    xx = (np.arange(w) + 0.5) / factor - 0.5
    return ndimage.map_coordinates(grid, np.meshgrid(yy, xx, indexing="ij"), order=1, mode="nearest").astype(np.float32)


def sky_background(plane: np.ndarray, factor: int = 4, percentile: float = 10, size: int = 15,
                   smooth: float = 2, keep: np.ndarray | None = None) -> np.ndarray:
    """Low percentile over `size`·`factor` px windows: the dark sky between trails, not the trails. Pixels outside
    `keep` (the foreground) take no part; the sky is extended over them."""
    h, w = plane.shape
    hs, ws = h // factor, w // factor

    def down(a):
        return a[:hs * factor, :ws * factor].reshape(hs, factor, ws, factor).mean(axis=(1, 3))

    if keep is None:
        small = ndimage.percentile_filter(down(plane), percentile, size=size)
    else:
        share = down(keep.astype(np.float32))
        mean = down(np.where(keep, plane, 0)) / np.maximum(share, 1e-6)
        sky_cells = share >= 0.5
        top = float(mean[sky_cells].max()) + 1 if sky_cells.any() else 1.0
        small = ndimage.percentile_filter(np.where(sky_cells, mean, top + 1), percentile, size=size)
        small = _fill_holes(small, small < top)
    return _upsample(ndimage.gaussian_filter(small, smooth), factor, (h, w))


def _along_phi(op, mask: np.ndarray, length: int) -> np.ndarray:
    """Binary morphology along φ that wraps around the circle (no seam at φ = 0)."""
    pad = 2 * length
    wide = np.concatenate([mask[:, -pad:], mask, mask[:, :pad]], axis=1)
    return op(wide, structure=np.ones((1, length), bool))[:, pad:-pad]


def polar_floor(p: np.ndarray, rows: int, percentile: float = 20, cols_avg: int = 8) -> np.ndarray:
    """Sky level under the trails: a low percentile across them (along ρ, `rows` wide), where the dark gaps
    between neighbouring trails are, smoothed along them (φ)."""
    n, m = p.shape
    mc = m // cols_avg
    small = p[:, :mc * cols_avg].reshape(n, mc, cols_avg).mean(axis=2)
    floor = ndimage.percentile_filter(small, percentile, size=(rows, 1), mode="nearest")
    floor = ndimage.uniform_filter1d(floor, 9, axis=1, mode="wrap")
    out = np.repeat(floor, cols_avg, axis=1)
    if out.shape[1] < m:
        out = np.concatenate([out, np.repeat(floor[:, -1:], m - out.shape[1], axis=1)], axis=1)
    return out.astype(np.float32)


def detected_mask(trails: Trails, kernel: TrailKernel, q: np.ndarray, half_width: int,
                  rows_ok: np.ndarray) -> np.ndarray:
    """Polar pixels of the detected trails where they are actually lit (not where the landscape hides them),
    small gaps between frames bridged."""
    nrho, nphi = q.shape
    det = np.zeros((nrho, nphi), bool)
    pad = max(2, kernel.length // 40)
    cols = (trails.cols[:, None] + np.arange(-pad, kernel.length + pad)[None, :]) % nphi
    for dr in range(-half_width, half_width + 1):
        rr = np.clip(trails.rows + dr, 0, nrho - 1)[:, None]
        lit = q[rr, cols] > 0.3 * trails.amplitude[:, None]
        det[np.broadcast_to(rr, cols.shape)[lit], cols[lit]] = True
    det = _along_phi(ndimage.binary_closing, det, max(3, kernel.length // 30))
    return det & rows_ok[:, None]


def faint_mask(significance: np.ndarray, kernel: TrailKernel, half_width: int, rows_ok: np.ndarray) -> np.ndarray:
    """Polar pixels of every long run along φ where any colour channel stands above the sky level between the
    trails: faint trails and the colour fringes of the bright ones."""
    floor = polar_floor(significance, 8 * half_width + 1)
    # Averaging along the trails lifts faint, speckled ones (JPEG chroma noise) well above the noise.
    above = ndimage.uniform_filter1d(significance - floor, 3, axis=0)
    above = ndimage.uniform_filter1d(above, max(3, kernel.length // 20), axis=1, mode="wrap")
    faint = _along_phi(ndimage.binary_opening, above > 0.35, max(3, kernel.length // 6))
    return faint & rows_ok[:, None]


def polar_to_image(grid: PolarGrid, m: np.ndarray, shape) -> np.ndarray:
    nrho, nphi = m.shape
    h, w = shape
    out = np.zeros((h, w), bool)
    for y0 in range(0, h, 256):
        ys, xs = np.mgrid[y0:min(y0 + 256, h), 0:w]
        r, c = grid.coords(xs.ravel(), ys.ravel())
        ri = np.clip(np.rint(r).astype(np.int64), 0, nrho - 1)
        ci = np.rint(c).astype(np.int64) % nphi
        inside = (r > -0.5) & (r < nrho - 0.5)
        out[y0:y0 + ys.shape[0]] = (m[ri, ci] & inside).reshape(ys.shape)
    return out


def repaint_area(core: np.ndarray, bridge: int = 5, dilate: int = 2) -> np.ndarray:
    """Soft mask of what gets repainted: the trails, the narrow lanes between dense trails (closing; a lane of a
    few pixels holds only fringes and would read as a dark streak) and a margin for the halos."""
    disk = np.hypot(*np.mgrid[-bridge:bridge + 1, -bridge:bridge + 1]) <= bridge
    m = ndimage.binary_closing(np.pad(core, bridge, mode="edge"), structure=disk)[bridge:-bridge, bridge:-bridge]
    m = ndimage.binary_dilation(m | core, iterations=dilate)
    return ndimage.gaussian_filter(m.astype(np.float32), 1.0)


def masked_background(plane: np.ndarray, keep: np.ndarray, block: int = 32, min_share: float = 0.05) -> np.ndarray:
    """Smooth map from the `keep` pixels only: median per block (robust to trail remnants left in the gaps),
    outlier blocks dropped, holes filled from ever larger neighbourhoods, bilinear back to full size."""
    h, w = plane.shape
    by, bx = -(-h // block), -(-w // block)
    pad = np.full((by * block, bx * block), np.nan, np.float32)
    pad[:h, :w] = np.where(keep, plane, np.nan)
    tiles = pad.reshape(by, block, bx, block).transpose(0, 2, 1, 3).reshape(by, bx, -1)
    share = np.isfinite(tiles).mean(axis=2)
    with np.errstate(all="ignore"), warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        grid = np.nanmedian(np.where(share[..., None] >= min_share, tiles, np.nan), axis=2)
        # A block whose few free pixels are a missed bright trail stands out from its neighbours: drop it.
        for _ in range(2):
            filled = np.where(np.isfinite(grid), grid, np.nanmedian(grid))
            local = ndimage.median_filter(filled, size=5, mode="nearest")
            dev = np.abs(grid - local)
            scale = 1.4826 * np.nanmedian(dev) + 1e-6
            grid[dev > 4 * scale] = np.nan
    have = np.isfinite(grid)
    out = ndimage.gaussian_filter(_fill_holes(grid, have), 1.0, mode="nearest")
    return _upsample(out, block, (h, w))


def landscape_mask(trails: np.ndarray, luma: np.ndarray, ground: str) -> np.ndarray:
    """Landscape (bool).
    Coarse: trails exist only on the sky, the landscape is dark; with the gravity direction the stacker's horizon
    model turns that evidence into one sky band per column.
    Fine: the landscape is a silhouette, darker than half of the sky level around it; dark pixels connected to the
    coarse ground are landscape too (tree crowns poking into the sky band), dark lanes between trails up in the
    sky are not. Each pass measures the sky level without the silhouette found so far, so tree crowns stop
    dragging it down."""
    h, w = trails.shape
    r = max(8, min(h, w) // 100)
    density = box_blur(trails.astype(np.float32), r)
    # Trails are evidence of sky; their absence is not evidence of ground (sparse fields), darkness is.
    free = box_blur((~trails).astype(np.float32), r)
    with np.errstate(divide="ignore", invalid="ignore"):
        blurred = np.where(free > 0.2, box_blur(np.where(trails, 0, luma).astype(np.float32), r) / free, np.nan)
    sure_sky = (density > 0.05) & np.isfinite(blurred)
    reference = float(np.median(blurred[sure_sky])) if sure_sky.any() else float(np.nanmedian(blurred))
    with np.errstate(divide="ignore", invalid="ignore"):
        dark = np.clip(np.log(np.nan_to_num(blurred, nan=reference) / (0.5 * reference + 1e-12)), -4, 0)
    score = (np.clip(np.log((density + 0.01) / 0.03), 0, 4) + dark).astype(np.float32)
    builder = SkyMaskBuilder(ground)
    coarse_ground = builder.horizon_mask(box_blur(score, r), ground, 1.0) <= 0.5
    smooth = ndimage.gaussian_filter(luma, 2)
    foreground = coarse_ground
    for _ in range(3):
        level = sky_background(luma, percentile=30, size=25, smooth=3, keep=~foreground & ~trails)
        dark = (smooth < 0.5 * level) & ~trails
        labels, _ = ndimage.label(dark | coarse_ground)
        grounded = np.unique(labels[coarse_ground])
        foreground = ndimage.binary_opening(np.isin(labels, grounded[grounded > 0]), iterations=1) | coarse_ground
    return foreground


@dataclass
class Stars:
    x: np.ndarray
    y: np.ndarray
    rgb: np.ndarray  # (n, 3) peak above the background, linear


def place_stars(grid: PolarGrid, trails: Trails, kernel: TrailKernel, rgb_residual: np.ndarray, at: str,
                hemisphere: str, q: np.ndarray) -> Stars:
    n = len(trails.rows)
    if at == "middle":
        offset = (kernel.length - 1) / 2
    else:
        # Northern sky turns counter-clockwise on screen, southern clockwise.
        time_along_phi = grid.geometry.phi_increases_clockwise() == (hemisphere == "south")
        offset = 0.0 if (at == "start") == time_along_phi else kernel.length - 1.0
    x, y = grid.pixels(trails.rows, trails.cols + offset)
    # A star whose trail is dark around that moment was behind the foreground (or between frames): skip it.
    nrho, nphi = q.shape
    reach = max(2, kernel.length // 25)
    around = (np.rint(trails.cols + offset).astype(np.int64)[:, None] + np.arange(-reach, reach + 1)[None, :]) % nphi
    seen = q[trails.rows[:, None], around].max(axis=1) > 0.3 * trails.amplitude
    # Colour: matched-filter amplitude of every channel along the same trail.
    cols = trails.cols[:, None] + np.arange(kernel.length)[None, :]
    px, py = grid.pixels(np.repeat(trails.rows[:, None], kernel.length, 1), cols)
    k = kernel.profile[None, :]
    rgb = np.zeros((n, 3))
    for ch in range(3):
        s = remap(rgb_residual[ch], px, py)
        ok = np.isfinite(s)
        rgb[:, ch] = np.sum(np.where(ok, s, 0) * k, 1) / np.maximum(np.sum(np.where(ok, k * k, 0), 1), 1e-9)
    rgb = np.maximum(rgb, 0)
    keep = seen & (x >= 0) & (y >= 0) & (x <= grid.geometry.width - 1) & (y <= grid.geometry.height - 1)
    return Stars(x[keep], y[keep], rgb[keep])


def render_stars(image: np.ndarray, stars: Stars, fwhm: float, gain: float = 1.0) -> np.ndarray:
    out = image.copy()
    _, h, w = out.shape
    sigma = fwhm / 2.3548
    r = int(np.ceil(3 * sigma))
    off = np.arange(-r, r + 1)
    for x, y, c in zip(stars.x, stars.y, stars.rgb):
        ix, iy = int(round(x)), int(round(y))
        x0, x1 = max(ix - r, 0), min(ix + r + 1, w)
        y0, y1 = max(iy - r, 0), min(iy + r + 1, h)
        if x0 >= x1 or y0 >= y1:
            continue
        gx = np.exp(-0.5 * ((off[x0 - ix + r:x1 - ix + r] + ix - x) / sigma) ** 2)
        gy = np.exp(-0.5 * ((off[y0 - iy + r:y1 - iy + r] + iy - y) / sigma) ** 2)
        stamp = np.outer(gy, gx).astype(np.float32)
        out[:, y0:y1, x0:x1] += gain * c.astype(np.float32)[:, None, None] * stamp[None]
    return out


def trail_width(grid: PolarGrid, q: np.ndarray, trails: Trails, kernel: TrailKernel, valid: np.ndarray) -> float:
    """FWHM across the trails in pixels (median over the brightest unsaturated ones)."""
    nrho, nphi = q.shape
    order = np.argsort(-trails.amplitude)
    top = trails.amplitude[order[0]] if len(order) else 1
    pick = [i for i in order if trails.amplitude[i] < 0.7 * top][:300]
    widths = []
    k = kernel.profile
    for i in pick:
        r, c = trails.rows[i], trails.cols[i]
        rows = np.arange(r - 15, r + 16)
        if rows[0] < 0 or rows[-1] >= nrho:
            continue
        cols = (c + np.arange(kernel.length)) % nphi
        seg = q[rows[:, None], cols[None, :]]
        ok = valid[rows[:, None], cols[None, :]]
        prof = np.sum(np.where(ok, seg, 0) * k, 1) / np.maximum(np.sum(np.where(ok, k * k, 0), 1), 1e-9)
        prof = prof - np.median(np.r_[prof[:5], prof[-5:]])
        peak = prof[15]
        if peak <= 0:
            continue
        above = prof > peak / 2
        lo = hi = 15
        while lo > 0 and above[lo - 1]:
            lo -= 1
        while hi < 30 and above[hi + 1]:
            hi += 1
        x0, y0 = grid.pixels(r + lo - 0.5, c + kernel.length / 2)
        x1, y1 = grid.pixels(r + hi + 0.5, c + kernel.length / 2)
        widths.append(float(np.hypot(x1 - x0, y1 - y0)))
    return float(np.median(widths)) if widths else 3.0


def linear_to_srgb(v: np.ndarray) -> np.ndarray:
    v = np.clip(v, 0, 1)
    return np.where(v <= 0.0031308, 12.92 * v, 1.055 * np.power(v, 1 / 2.4) - 0.055)


# MARK: - Pipeline


@dataclass
class Options:
    pole: tuple[float, float] | None = None
    focal: float | None = None
    fit_center: bool = True
    length_degrees: float | None = None
    at: str = "middle"  # start | middle | end of the exposure
    hemisphere: str = "north"
    star_fwhm: float | None = None
    star_gain: float = 1.0
    threshold: float = 2.0  # trail amplitude in units of the per-pixel noise
    gamma: str = "auto"
    ground: str | None = "down"  # where the ground is in the stored image; None = sky only
    seed: int = 0


@dataclass
class Result:
    image: np.ndarray  # (3, H, W) linear
    stars: Stars
    geometry: SkyGeometry
    kernel: TrailKernel
    grid: PolarGrid
    mask: np.ndarray
    sky: np.ndarray
    polar: np.ndarray
    srgb: bool


def _to_polar(residual: np.ndarray, mx: np.ndarray, my: np.ndarray):
    """Polar resampling: raw (NaN outside the sky), valid mask, zero-filled, and smoothed over 5 rows (≈ 4 px
    across the trails) for detection."""
    polar = remap(residual, mx, my)
    valid = np.isfinite(polar)
    q = np.where(valid, polar, 0).astype(np.float32)
    return polar, valid, q, ndimage.uniform_filter1d(q, 5, axis=0)


def untrail(rgb: np.ndarray, options: Options, srgb: bool = True, log=print) -> Result:
    _, h, w = rgb.shape
    luma = luminance(rgb)
    bg = np.stack([sky_background(c) for c in rgb])
    residual = luminance(rgb - bg)
    _, _, noise = sigma_clipped(residual[::3, ::3], kappa=2.5, iterations=6)
    log(f"{w}×{h}, sky noise σ = {noise:.5f}")

    geometry = fit_geometry(residual, options.pole, options.focal, options.fit_center, log)
    grid = PolarGrid.covering(geometry)
    mx, my = grid.maps()
    log(f"polar grid {grid.nrho}×{grid.nphi} (ρ step {grid.drho * geometry.focal:.2f} px, "
        f"φ step {360 / grid.nphi:.3f}°)")

    polar, valid, q, qs = _to_polar(residual, mx, my)
    rows = np.arange(grid.nrho)
    if options.length_degrees:
        kernel = TrailKernel.box(int(round(options.length_degrees / 360 * grid.nphi)))
    else:
        rows_ok = (grid.rho0 + rows * grid.drho) * geometry.focal * np.radians(5) > 12  # long enough to measure
        kernel = estimate_kernel(qs, valid, rows_ok, noise, grid.nphi, log=log)
    # Closer to the pole a trail is shorter than a star is wide: nothing to undo there.
    rows_ok = (grid.rho0 + rows * grid.drho) * geometry.focal * kernel.length * grid.dphi > 4
    log(f"trail length {360 * kernel.length / grid.nphi:.2f}° ≈ {360 * kernel.length / grid.nphi / 15.041:.2f} h")

    trails = detect_trails(qs, valid, rows_ok, kernel, noise, options.threshold)
    width = trail_width(grid, q, trails, kernel, valid)
    half_rows = int(np.ceil(width / (grid.drho * geometry.focal)))
    landscape = np.zeros((h, w), bool)
    if options.ground is not None and len(trails.rows):
        # Second pass without the landscape: it pulls the background down along the horizon (a bright band that
        # lines up with the arcs low in the frame) and a trail going behind it must not seem to end there.
        first = polar_to_image(grid, detected_mask(trails, kernel, qs, half_rows, rows_ok), (h, w))
        landscape = landscape_mask(first, luma, options.ground)
        log(f"landscape: {100 * landscape.mean():.1f} % of the frame")
        bg = np.stack([sky_background(c, keep=~landscape) for c in rgb])
        residual = luminance(rgb - bg)
        polar, valid, q, qs = _to_polar(np.where(landscape, np.nan, residual), mx, my)
        trails = detect_trails(qs, valid, rows_ok, kernel, noise, options.threshold)
        width = trail_width(grid, q, trails, kernel, valid)
        half_rows = int(np.ceil(width / (grid.drho * geometry.focal)))
    residual_rgb = rgb - bg
    log(f"{len(trails.rows)} trails")
    fwhm = options.star_fwhm or width
    log(f"trail width {width:.1f} px → star FWHM {fwhm:.1f} px")

    sigma_rgb = np.array([sigma_clipped(c[::3, ::3], kappa=2.5, iterations=6)[2] for c in residual_rgb])
    significance = ndimage.gaussian_filter(np.max(residual_rgb / sigma_rgb[:, None, None], axis=0), 1.0)
    significance = np.nan_to_num(remap(np.where(landscape, 0, significance), mx, my), nan=0.0)
    del mx, my
    core = polar_to_image(grid, detected_mask(trails, kernel, qs, half_rows, rows_ok)
                          | faint_mask(significance, kernel, half_rows, rows_ok), (h, w)) & ~landscape
    del significance
    sky_alpha = ndimage.gaussian_filter((~landscape).astype(np.float32), 1.0)
    mask = repaint_area(core) * sky_alpha
    # Sky under the trails: the low-percentile background (defined everywhere, but a bit off where trails are
    # dense) corrected by a smooth offset measured on the pixels that stay, plus matching noise. Where trails cover
    # everything only the offset is interpolated, never the sky itself. Pixels right next to a trail are left
    # out: sharpened photos have dark halos there.
    gaps = ndimage.binary_erosion(mask < 0.01, iterations=2) & (sky_alpha > 0.99)
    base = np.stack([sky_background(c, size=41, smooth=6, keep=~landscape) for c in rgb])
    sky = base + np.stack([masked_background(rgb[c] - base[c], gaps) for c in range(3)])
    clear = mask < 0.05
    sigma_rgb = np.array([sigma_clipped((rgb[c] - sky[c])[clear][::5], kappa=2.5, iterations=6)[2]
                          for c in range(3)], np.float32)
    rng = np.random.default_rng(options.seed)
    fill = sky + rng.normal(size=rgb.shape).astype(np.float32) * sigma_rgb[:, None, None]
    clean = rgb * (1 - mask) + fill * mask
    log(f"{100 * mask.mean():.1f} % of the frame repainted")

    stars = place_stars(grid, trails, kernel, residual_rgb, options.at, options.hemisphere, qs)
    iy = np.clip(np.rint(stars.y).astype(int), 0, h - 1)
    ix = np.clip(np.rint(stars.x).astype(int), 0, w - 1)
    on_sky = ~landscape[iy, ix]
    stars = Stars(stars.x[on_sky], stars.y[on_sky], stars.rgb[on_sky])
    out = render_stars(clean, stars, fwhm, options.star_gain)
    log(f"{len(stars.x)} stars placed at the {options.at} of the exposure")
    return Result(out, stars, geometry, kernel, grid, mask, sky_alpha, polar, srgb)


def load(path: Path, gamma: str) -> tuple[np.ndarray, bool, int]:
    from PIL import Image

    rgb, _, _, _, desc = _load_rgb(path, LoadOptions(bin=1, gamma=gamma, hot_ratio=0), 1)
    orientation = 1
    try:
        with Image.open(path) as img:
            orientation = int(img.getexif().get(274, 1))
    except Exception:
        pass
    return rgb, desc.endswith("srgb"), orientation


def save(result: Result, path: Path, orientation: int):
    from PIL import Image

    data = np.moveaxis(result.image, 0, 2)
    if path.suffix.lower() in (".tif", ".tiff"):  # 32-bit float, linear (or as the input was encoded)
        import tifffile

        out = data if not result.srgb else linear_to_srgb(data)
        tifffile.imwrite(path, np.ascontiguousarray(np.clip(out, 0, None).astype(np.float32)),
                         photometric="rgb", compression="zlib")
        return
    img = Image.fromarray((linear_to_srgb(data) * 255 + 0.5).astype(np.uint8))
    exif = Image.Exif()
    exif[274] = orientation
    img.save(path, quality=95, subsampling=0, exif=exif.tobytes())


def save_diagnostics(result: Result, folder: Path):
    from PIL import Image

    folder.mkdir(parents=True, exist_ok=True)
    p = np.nan_to_num(result.polar)
    top = max(float(np.percentile(p, 99.5)), 1e-6)
    disp = np.sqrt(np.clip(p / top, 0, 1))
    step = max(1, result.grid.nphi // 4096)
    Image.fromarray((disp[:, ::step] * 255).astype(np.uint8)).save(folder / "polar.png")
    Image.fromarray((np.clip(result.mask, 0, 1) * 255).astype(np.uint8)).save(folder / "trail_mask.png")
    Image.fromarray((np.clip(result.sky, 0, 1) * 255).astype(np.uint8)).save(folder / "sky_mask.png")
    k = result.kernel.profile
    deg = np.arange(len(k)) * 360 / result.grid.nphi
    np.savetxt(folder / "kernel.csv", np.stack([deg, k], 1), delimiter=",", header="phi_deg,weight", fmt="%.5f")
    s = result.stars
    np.savetxt(folder / "stars.csv", np.column_stack([s.x, s.y, s.rgb]), delimiter=",",
               header="x,y,r,g,b", fmt="%.4f")
    g = result.geometry
    (folder / "geometry.txt").write_text(
        f"pole {g.pole_x:.2f} {g.pole_y:.2f}\nfocal {g.focal:.2f}\nprincipal {g.cx:.2f} {g.cy:.2f}\n"
        f"fov {g.field_of_view:.2f}\nkernel_degrees {deg[-1] if len(deg) else 0:.3f}\n")


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="astralstack-untrail",
        description="Undoes a star-trail photo from a static camera: fits the celestial pole and the lens, finds "
                    "every trail and puts its star back at one point of the arc.")
    p.add_argument("input", type=Path, help="star-trail image (JPEG, PNG or TIFF)")
    p.add_argument("-o", "--output", type=Path,
                   help="output image, .jpg/.png or .tif (32-bit float); default: <input>_untrailed.jpg, "
                        "or .tif for linear input")
    p.add_argument("--at", choices=["middle", "start", "end"], default="middle",
                   help="which moment of the exposure the stars show (default: middle – needs no direction)")
    p.add_argument("--hemisphere", choices=["north", "south"], default="north",
                   help="pole in the frame, for --at start/end (north: sky turns counter-clockwise)")
    p.add_argument("--pole", type=float, nargs=2, metavar=("X", "Y"), help="approximate pole pixel (refined)")
    lens = p.add_mutually_exclusive_group()
    lens.add_argument("--fov", type=float, help="field of view along the longer side, degrees (default: fitted)")
    lens.add_argument("--focal-px", type=float, help="focal length in pixels (default: fitted)")
    p.add_argument("--no-center-fit", action="store_true",
                   help="keep the principal point in the image centre (uncropped photos)")
    p.add_argument("--length", type=float, metavar="DEG",
                   help="trail length in degrees of hour angle (15°/h); default: measured, with the gap pattern")
    p.add_argument("--star-fwhm", type=float, help="star size in pixels (default: trail width)")
    p.add_argument("--star-gain", type=float, default=1.0, help="star brightness factor (default 1)")
    p.add_argument("--threshold", type=float, default=2.0,
                   help="minimum trail brightness in units of the sky noise (default 2)")
    p.add_argument("--ground", choices=["auto", "down", "up", "left", "right", "none"], default="auto",
                   help="where the ground is in the stored image (default: from the EXIF orientation); "
                        "'none' for a sky-only frame")
    p.add_argument("--gamma", choices=["auto", "srgb", "linear"], default="auto",
                   help="input encoding (auto: 8-bit = sRGB, 16-bit/float = linear)")
    p.add_argument("--diag", type=Path, help="folder for polar.png, trail_mask.png, kernel.csv, stars.csv")
    p.add_argument("-q", "--quiet", action="store_true")
    args = p.parse_args(argv)

    if not args.input.is_file():
        p.error(f"{args.input} is not a file")
    start = time.monotonic()

    def log(message: str):
        if not args.quiet:
            print(f"[{time.monotonic() - start:7.1f} s] {message}", file=sys.stderr, flush=True)

    rgb, srgb, orientation = load(args.input, args.gamma)
    focal = args.focal_px
    if args.fov:
        focal = (max(rgb.shape[1:]) / 2) / np.tan(np.radians(args.fov) / 2)
    options = Options(pole=tuple(args.pole) if args.pole else None, focal=focal, fit_center=not args.no_center_fit,
                      length_degrees=args.length, at=args.at, hemisphere=args.hemisphere,
                      star_fwhm=args.star_fwhm, star_gain=args.star_gain, threshold=args.threshold,
                      gamma=args.gamma,
                      ground=None if args.ground == "none" else (
                          GROUND_FROM_ORIENTATION.get(orientation) if args.ground == "auto" else args.ground))
    result = untrail(rgb, options, srgb, log)
    out = args.output or args.input.with_name(args.input.stem + ("_untrailed.jpg" if srgb else "_untrailed.tif"))
    save(result, out, orientation)
    if args.diag:
        save_diagnostics(result, args.diag)
    print(out)


if __name__ == "__main__":
    main()
