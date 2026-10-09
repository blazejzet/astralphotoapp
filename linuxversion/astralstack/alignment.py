"""Per-frame registration on the physical model of the sky (counterpart of AlignmentEngine.swift).

The phone app knows the frame timestamps and the device attitude, so it predicts H(Δt) = K·R_p(−ωΔt)·K⁻¹
from a fitted pole and adds a rigid drift correction. Offline we have neither the sensors nor reliable
timestamps (EXIF has 1 s resolution), but the model is the same: for a static camera looking at the sky
every frame is a pure 3-D rotation of the reference, G_k = K·R_k·K⁻¹. R_k already contains the sidereal
rotation *and* any tripod sag, so it is solved directly from the stars (Kabsch, 3 parameters per frame).
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace

import numpy as np
from scipy.optimize import minimize
from scipy.spatial import cKDTree

from .matching import TriangleMatcher


@dataclass(frozen=True)
class CameraModel:
    """Pinhole intrinsics + one-parameter division model for radial distortion:
    p_u = c + (p_d − c) / (1 + k1·r_d²), r normalised by the half diagonal."""

    width: int
    height: int
    focal: float
    k1: float = 0.0

    @property
    def center(self) -> np.ndarray:
        return np.array([(self.width - 1) / 2, (self.height - 1) / 2])

    @property
    def norm_radius(self) -> float:
        return float(np.hypot(*self.center))

    @staticmethod
    def from_fov(horizontal_fov_degrees: float, width: int, height: int) -> "CameraModel":
        """f = (W/2)/tan(HFOV/2)."""
        return CameraModel(width, height, (width / 2) / np.tan(np.radians(horizontal_fov_degrees) / 2))

    @property
    def horizontal_fov(self) -> float:
        return float(np.degrees(2 * np.arctan(self.width / 2 / self.focal)))

    def undistort(self, p: np.ndarray) -> np.ndarray:
        if self.k1 == 0:
            return p
        d = p - self.center
        s = (d * d).sum(axis=-1, keepdims=True) / self.norm_radius ** 2
        return self.center + d / (1 + self.k1 * s)

    def distort(self, p: np.ndarray) -> np.ndarray:
        """Inverse of `undistort`: r_d = 2·r_u / (1 + √(1 − 4·k1·r_u²)); NaN where it has no solution."""
        if self.k1 == 0:
            return p
        d = p - self.center
        ru2 = (d * d).sum(axis=-1, keepdims=True) / self.norm_radius ** 2
        disc = 1 - 4 * self.k1 * ru2
        with np.errstate(invalid="ignore"):
            scale = np.where(disc >= 0, 2 / (1 + np.sqrt(np.maximum(disc, 0))), np.nan)
        return self.center + d * scale

    @property
    def matrix(self) -> np.ndarray:
        cx, cy = self.center
        return np.array([[self.focal, 0, cx], [0, self.focal, cy], [0, 0, 1]])

    @property
    def inverse_matrix(self) -> np.ndarray:
        cx, cy = self.center
        f = self.focal
        return np.array([[1 / f, 0, -cx / f], [0, 1 / f, -cy / f], [0, 0, 1]])

    def rays(self, undistorted: np.ndarray) -> np.ndarray:
        cx, cy = self.center
        v = np.stack([(undistorted[:, 0] - cx) / self.focal, (undistorted[:, 1] - cy) / self.focal,
                      np.ones(len(undistorted))], axis=1)
        return v / np.linalg.norm(v, axis=1, keepdims=True)

    def project(self, rays: np.ndarray) -> np.ndarray:
        """Undistorted pixels; NaN behind the camera."""
        z = rays[:, 2]
        with np.errstate(divide="ignore", invalid="ignore"):
            out = np.stack([self.focal * rays[:, 0] / z + self.center[0],
                            self.focal * rays[:, 1] / z + self.center[1]], axis=1)
        out[z <= 1e-12] = np.nan
        return out

    def homography(self, rotation: np.ndarray) -> np.ndarray:
        """Undistorted reference pixels → undistorted pixels of the frame."""
        return self.matrix @ rotation @ self.inverse_matrix


def apply_homography(h: np.ndarray, p: np.ndarray) -> np.ndarray:
    q = p @ h[:, :2].T + h[:, 2]
    with np.errstate(divide="ignore", invalid="ignore"):
        out = q[:, :2] / q[:, 2:3]
    out[q[:, 2] <= 1e-12] = np.nan
    return out


def max_displacement(h: np.ndarray, width: int, height: int) -> float:
    """Largest displacement of the frame corners and centre under a warp (undistorted pixels)."""
    pts = np.array([[0, 0], [width - 1, 0], [0, height - 1], [width - 1, height - 1],
                    [(width - 1) / 2, (height - 1) / 2]], dtype=np.float64)
    d = np.linalg.norm(apply_homography(h, pts) - pts, axis=1)
    return float(np.inf if not np.all(np.isfinite(d)) else d.max())


def fit_rotation(p: np.ndarray, q: np.ndarray) -> np.ndarray:
    """Kabsch: rotation R minimising Σ|q − R·p|² for unit rays p, q (n, 3)."""
    u, _, vt = np.linalg.svd(p.T @ q)
    d = 1.0 if np.linalg.det(vt.T @ u.T) >= 0 else -1.0
    return vt.T @ np.diag([1, 1, d]) @ u.T


@dataclass
class RotationFit:
    rotation: np.ndarray
    rms: float
    inliers: np.ndarray  # boolean, per pair


def robust_rotation(camera: CameraModel, ref_rays: np.ndarray, observed: np.ndarray,
                    inlier_radius: float) -> RotationFit | None:
    """Least-squares rotation with two rounds of outlier trimming (cf. AlignmentEngine.robustRigid)."""
    obs_rays = camera.rays(observed)
    keep = np.ones(len(observed), dtype=bool)
    rotation = None
    for rnd in range(3):
        if keep.sum() < 2:
            return None
        rotation = fit_rotation(ref_rays[keep], obs_rays[keep])
        if rnd == 2:
            break
        residuals = np.linalg.norm(camera.project(ref_rays @ rotation.T) - observed, axis=1)
        threshold = max(min(3 * float(np.nanmedian(residuals)), inlier_radius), 0.5)
        keep = residuals <= threshold
    residuals = np.linalg.norm(camera.project(ref_rays @ rotation.T) - observed, axis=1)
    inliers = residuals < inlier_radius
    rms = float(np.sqrt((residuals[inliers] ** 2).mean())) if inliers.any() else np.inf
    return RotationFit(rotation, rms, inliers)


@dataclass
class FrameAlignment:
    rotation: np.ndarray  # reference rays → frame rays
    matched: int
    rms: float
    accepted: bool
    is_reference: bool = False
    pairs: list = field(default_factory=list)  # (catalogue index, star index), inliers only


class Aligner:
    """Registration of frames against the reference catalogue:
    1. predict catalogue positions with the neighbouring frame's rotation,
    2. gate nearest-neighbour matches (fallback: triangle matching),
    3. robust Kabsch rotation on the matched rays, one re-match with the fitted rotation,
    4. stars that rotated into the frame are added to the catalogue once the fit is trusted."""

    def __init__(self, camera: CameraModel, min_matches=8, match_radius=4.0, max_rms=1.5,
                 trusted_rms=1.0, max_catalog_stars=300):
        self.camera = camera
        self.min_matches = min_matches
        self.match_radius = match_radius
        self.max_rms = max_rms
        self.trusted_rms = trusted_rms
        self.max_catalog_stars = max_catalog_stars
        self.catalog = np.zeros((0, 2))  # undistorted reference pixels
        self.catalog_rays = np.zeros((0, 3))
        self.reference_count = 0  # catalogue entries detected in the reference frame itself

    def set_reference(self, positions: np.ndarray) -> FrameAlignment:
        self.catalog = self.camera.undistort(np.asarray(positions[: self.max_catalog_stars], dtype=np.float64))
        self.catalog_rays = self.camera.rays(self.catalog)
        self.reference_count = len(self.catalog)
        n = len(self.catalog)
        return FrameAlignment(np.eye(3), n, 0.0, True, True, [(i, i) for i in range(n)])

    def _gated_matches(self, points: np.ndarray, predicted: np.ndarray) -> list[tuple[int, int]]:
        """Mutual nearest neighbours within the match radius, with an ambiguity check."""
        if len(points) == 0:
            return []
        valid = np.all(np.isfinite(predicted), axis=1)
        idx = np.nonzero(valid)[0]
        if idx.size == 0:
            return []
        k = 2 if len(points) > 1 else 1
        d, j = cKDTree(points).query(predicted[idx], k=k, distance_upper_bound=self.match_radius)
        if k == 1:
            d, j = d[:, None], j[:, None]
            d = np.concatenate([d, np.full_like(d, np.inf)], axis=1)
        found = np.isfinite(d[:, 0])
        ambiguous = np.isfinite(d[:, 1]) & (d[:, 1] ** 2 < 2.25 * d[:, 0] ** 2)
        ok = found & ~ambiguous
        cat, star, dist = idx[ok], j[ok, 0], d[ok, 0]
        order = np.argsort(dist, kind="stable")
        _, first = np.unique(star[order], return_index=True)
        chosen = order[first]
        return [(int(cat[i]), int(star[i])) for i in np.sort(chosen)]

    def _fit(self, pairs, points):
        cat = np.array([p[0] for p in pairs])
        star = np.array([p[1] for p in pairs])
        fit = robust_rotation(self.camera, self.catalog_rays[cat], points[star], 3 * self.match_radius)
        if fit is None:
            return None, []
        return fit, [pairs[i] for i in np.nonzero(fit.inliers)[0]]

    def align(self, positions: np.ndarray, prediction: np.ndarray) -> FrameAlignment:
        points = self.camera.undistort(np.asarray(positions, dtype=np.float64))
        pairs = self._gated_matches(points, self.camera.project(self.catalog_rays @ prediction.T))
        if len(pairs) < self.min_matches:
            # Lost track (start, clouds, bump): match catalogue to frame without a prior.
            tri = TriangleMatcher().match(self.catalog, points)
            if tri is not None:
                via_triangles = self._gated_matches(points, tri[0].apply(self.catalog))
                if len(via_triangles) > len(pairs):
                    pairs = via_triangles
        if len(pairs) < self.min_matches:
            return FrameAlignment(prediction, len(pairs), np.inf, False)
        fit, inlier_pairs = self._fit(pairs, points)
        if fit is None:
            return FrameAlignment(prediction, len(pairs), np.inf, False)
        # Re-match with the fitted rotation: picks up stars the prediction placed just outside the gate.
        again = self._gated_matches(points, self.camera.project(self.catalog_rays @ fit.rotation.T))
        if len(again) > len(pairs):
            fit2, inlier2 = self._fit(again, points)
            if fit2 is not None and len(inlier2) >= len(inlier_pairs):
                pairs, fit, inlier_pairs = again, fit2, inlier2
        accepted = fit.rms <= self.max_rms and len(inlier_pairs) >= self.min_matches
        if accepted and fit.rms <= self.trusted_rms:
            self._extend_catalog(points, {p[1] for p in pairs}, fit.rotation)
        return FrameAlignment(fit.rotation, len(pairs), fit.rms, accepted, False, inlier_pairs)

    def _extend_catalog(self, points: np.ndarray, matched: set, rotation: np.ndarray):
        """Newly risen / rotated-in stars are added in reference-epoch coordinates."""
        room = self.max_catalog_stars - len(self.catalog)
        if room <= 0:
            return
        new = [j for j in range(len(points)) if j not in matched]
        if not new:
            return
        rays = self.camera.rays(points[new]) @ rotation  # Rᵀ·q
        ref = self.camera.project(rays)
        min_separation = 3 * self.match_radius
        tree = cKDTree(self.catalog)
        added = []
        for p, r in zip(ref, rays):
            if len(added) >= room or not np.all(np.isfinite(p)):
                continue
            if np.isfinite(tree.query(p, distance_upper_bound=min_separation)[0]):
                continue
            if any(np.hypot(*(p - q)) <= min_separation for q, _ in added):
                continue
            added.append((p, r))
        if added:
            self.catalog = np.vstack([self.catalog, [a[0] for a in added]])
            self.catalog_rays = np.vstack([self.catalog_rays, [a[1] for a in added]])


def align_sequence(camera: CameraModel, star_positions: list[np.ndarray], reference: int,
                   usable: list[bool]) -> tuple[list[FrameAlignment | None], Aligner]:
    """Aligns every usable frame to `reference`, walking outwards from it in both directions so that each
    frame is predicted from its accepted neighbour (the sky moves a fraction of a pixel per second)."""
    aligner = Aligner(camera)
    results: list[FrameAlignment | None] = [None] * len(star_positions)
    results[reference] = aligner.set_reference(star_positions[reference])
    for direction in (1, -1):
        prediction = np.eye(3)
        k = reference + direction
        while 0 <= k < len(star_positions):
            if usable[k]:
                a = aligner.align(star_positions[k], prediction)
                results[k] = a
                if a.accepted:
                    prediction = a.rotation
            k += direction
    return results, aligner


def refine_camera(camera: CameraModel, star_positions: list[np.ndarray], reference: int,
                  alignments: list[FrameAlignment | None], focal_known: bool,
                  fit_distortion: bool) -> tuple[CameraModel, str | None]:
    """Fits the focal length (unknown, or ±25 % when taken from EXIF) and the radial distortion k1 to the
    matched stars of the frames that moved most, by minimising the truncated reprojection error.
    Equivalent of the app's focal-scale fit; the app takes the lens distortion from Apple's LUT instead."""
    ref_positions = np.asarray(star_positions[reference], dtype=np.float64)
    frames = []
    for k, a in enumerate(alignments):
        if a is None or not a.accepted or a.is_reference:
            continue
        pairs = [(i, j) for i, j in a.pairs if i < len(ref_positions)]
        if len(pairs) < 8:
            continue
        drift = max_displacement(camera.homography(a.rotation), camera.width, camera.height)
        frames.append((drift, ref_positions[[p[0] for p in pairs]], star_positions[k][[p[1] for p in pairs]]))
    if not frames:
        return camera, None
    frames.sort(key=lambda f: -f[0])
    if frames[0][0] < 10:
        return camera, None
    selected = frames[: max(1, len(frames) // 2)]
    selected = [selected[int(i)] for i in np.unique(np.linspace(0, len(selected) - 1, min(12, len(selected))).round())]

    def cost(cam: CameraModel) -> float:
        total, n = 0.0, 0
        for _, ref, obs in selected:
            p = cam.rays(cam.undistort(ref))
            rotation = fit_rotation(p, cam.rays(cam.undistort(obs)))
            pred = cam.distort(cam.project(p @ rotation.T))
            r2 = ((pred - obs) ** 2).sum(axis=1)
            r2 = np.where(np.isfinite(r2), r2, 4.0)
            total += np.minimum(r2, 4.0).sum()  # truncated quadratic, 2 px
            n += len(r2)
        return total / max(n, 1)

    def camera_for(x) -> CameraModel:
        return replace(camera, focal=float(np.exp(x[0])), k1=float(x[1]) if fit_distortion else 0.0)

    base = cost(camera)
    log_f0 = np.log(camera.focal)
    if focal_known:
        lo, hi = log_f0 - np.log(1.25), log_f0 + np.log(1.25)
        start = log_f0
    else:
        # Horizontal field of view 5°…140°.
        lo = np.log(camera.width / 2 / np.tan(np.radians(140) / 2))
        hi = np.log(camera.width / 2 / np.tan(np.radians(5) / 2))
        grid = np.linspace(lo, hi, 48)
        start = grid[int(np.argmin([cost(replace(camera, focal=float(np.exp(g)), k1=0.0)) for g in grid]))]

    def objective(x):
        if not (lo <= x[0] <= hi) or (fit_distortion and not (-0.6 <= x[1] <= 0.15)):
            return 1e9
        return cost(camera_for(x))

    res = minimize(objective, np.array([start, 0.0]), method="Nelder-Mead",
                   options={"xatol": 1e-4, "fatol": 1e-6, "maxiter": 400,
                            "initial_simplex": np.array([[start, 0], [start + 0.05, 0], [start, 0.02]])})
    if res.fun < 0.95 * base:
        refined = camera_for(res.x)
        note = (f"Lens fitted to the stars: f {camera.focal:.1f} → {refined.focal:.1f} px "
                f"(HFOV {refined.horizontal_fov:.1f}°), distortion k1 {refined.k1:+.4f}; "
                f"reprojection {np.sqrt(base):.2f} → {np.sqrt(res.fun):.2f} px")
        return refined, note
    return camera, None
