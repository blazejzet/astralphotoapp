"""Folder of short exposures → registered two-layer stack → finished image (offline FrameProcessor + Finisher).

Pass 1 (parallel): load every frame, detect stars, measure noise; estimate the noise model from consecutive
frames. Then register all frames on the star lists alone (cheap, so the lens can be refitted and the whole
sequence re-registered). Pass 2: stack outwards from the reference frame, exactly like the capture loop
(warm-up median seed, robust merge, provisional occlusion mask every 30 frames)."""

from __future__ import annotations

import os
import sys
import time
from collections import deque
from concurrent.futures import Future, ProcessPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime
from itertools import islice
from pathlib import Path

import numpy as np

from . import __version__
from .alignment import CameraModel, align_sequence, max_displacement, refine_camera
from .detection import StarDetector
from .export import write_diagnostics, write_jpeg, write_linear_tiff, write_mask
from .finishing import GROUND_FROM_ORIENTATION, MASK_FREE_DRIFT, FinishingOptions, SkyMaskBuilder, finish
from .imaging import luminance
from .loader import FrameInfo, LoadOptions, discover, kind_of, load_frame, master_dark, read_metadata
from .stacking import NoiseModel, RobustStacker, WarpMapper, estimate_noise_model


@dataclass
class Settings:
    input_dir: Path
    output_dir: Path | None = None
    darks_dir: Path | None = None
    reference: str = "middle"  # middle | first
    ground: str = "auto"  # auto | down | up | left | right | none
    focal_px: float | None = None  # in pixels of the full-resolution image
    fov: float | None = None  # degrees along the longer side
    focal_mm: float | None = None
    crop_factor: float | None = None
    lens_fit: bool = True
    load: LoadOptions = field(default_factory=LoadOptions)
    finishing: FinishingOptions = field(default_factory=FinishingOptions)
    diag: bool = False
    jobs: int = 0  # 0 → number of CPUs (max 8)
    max_frames: int | None = None
    min_reference_stars: int = 12


@dataclass
class FrameAnalysis:
    positions: np.ndarray
    fwhm: float
    background: float
    noise: float
    shape: tuple[int, int]
    orientation: int
    full_size: tuple[int, int]
    binning: int
    description: str


# MARK: - Workers (top level, picklable)

_worker_options: LoadOptions | None = None


def _init_worker(options: LoadOptions):
    global _worker_options
    _worker_options = options


def _analyse(path: Path, orientation_hint: int) -> FrameAnalysis:
    frame = load_frame(path, _worker_options, orientation_hint)
    detection = StarDetector().detect(luminance(frame.rgb))
    bright = detection.fwhm[:30]
    return FrameAnalysis(detection.positions, float(np.median(bright)) if bright.size else float("nan"),
                         detection.background, detection.noise, frame.rgb.shape[1:], frame.orientation,
                         frame.full_size, frame.binning, frame.description)


def _noise_pair(a: Path, b: Path, hint: int) -> NoiseModel | None:
    la = luminance(load_frame(a, _worker_options, hint).rgb)
    lb = luminance(load_frame(b, _worker_options, hint).rgb)
    return estimate_noise_model(la, lb)


def _load_rgb(path: Path, hint: int) -> np.ndarray:
    return load_frame(path, _worker_options, hint).rgb


class _InlineExecutor:
    def submit(self, fn, *args):
        f = Future()
        try:
            f.set_result(fn(*args))
        except Exception as e:  # noqa: BLE001
            f.set_exception(e)
        return f

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _ordered(executor, fn, items, depth):
    """executor.map with bounded look-ahead (frames are tens of MB each)."""
    it = iter(items)
    pending = deque(executor.submit(fn, *item) for item in islice(it, depth))
    while pending:
        f = pending.popleft()
        nxt = next(it, None)
        if nxt is not None:
            pending.append(executor.submit(fn, *nxt))
        yield f.result()


# MARK: - Helpers


def _stats(values, fmt: str) -> str:
    v = sorted(x for x in values if x is not None and np.isfinite(x))
    if not v:
        return "no data"
    return f"median {fmt % v[len(v) // 2]}, min {fmt % v[0]}, max {fmt % v[-1]}"


def _camera(settings: Settings, info: FrameInfo, analysis: FrameAnalysis) -> tuple[CameraModel, bool, str]:
    h, w = analysis.shape
    k = analysis.binning
    full_w, full_h = analysis.full_size
    if settings.focal_px:
        return CameraModel(w, h, settings.focal_px / k), True, f"--focal-px {settings.focal_px:g}"
    if settings.fov:
        f = (max(w, h) / 2) / np.tan(np.radians(settings.fov) / 2)
        return CameraModel(w, h, f), True, f"--fov {settings.fov:g}°"
    f35 = None
    source = ""
    if settings.focal_mm and settings.crop_factor:
        f35, source = settings.focal_mm * settings.crop_factor, f"--focal-mm {settings.focal_mm:g} × {settings.crop_factor:g}"
    elif info.focal_35mm:
        f35, source = info.focal_35mm, f"EXIF 35 mm equivalent {info.focal_35mm:g} mm"
    if f35:
        f_full = f35 * np.hypot(full_w, full_h) / np.hypot(36, 24)
        return CameraModel(w, h, f_full / k), True, source
    focal_mm = settings.focal_mm or info.focal_mm
    if focal_mm and info.focal_plane_px_per_mm:
        return (CameraModel(w, h, focal_mm * info.focal_plane_px_per_mm / k), True,
                f"EXIF focal length {focal_mm:g} mm and focal-plane resolution")
    cam = CameraModel.from_fov(60, w, h)
    return cam, False, "unknown (start: 60° field of view, fitted to the stars)"


class Log:
    def __init__(self, quiet: bool = False):
        self.quiet = quiet
        self.start = time.monotonic()

    def __call__(self, message: str):
        if not self.quiet:
            print(f"[{time.monotonic() - self.start:7.1f} s] {message}", file=sys.stderr, flush=True)


# MARK: - Pipeline


def run(settings: Settings, log: Log | None = None) -> Path:
    log = log or Log()
    input_dir = settings.input_dir
    files = discover(input_dir)
    if settings.max_frames:
        files = files[: settings.max_frames]
    if len(files) < 2:
        raise SystemExit(f"Need at least 2 supported frames in {input_dir} (found {len(files)}).")
    kind = kind_of(files[0])
    log(f"{len(files)} frames ({kind}, {files[0].suffix.lower()}) in {input_dir}")

    infos = [read_metadata(p) for p in files]
    stamps = [i.timestamp for i in infos]
    if all(t is not None for t in stamps) and len(set(stamps)) > 1:
        order = sorted(range(len(files)), key=lambda i: (stamps[i], i))
        files, infos = [files[i] for i in order], [infos[i] for i in order]
        order_note = "EXIF capture time"
    else:
        order_note = "file name"

    load_options = settings.load
    dark_note = "no"
    if settings.darks_dir:
        darks = discover(settings.darks_dir)
        if not darks:
            raise SystemExit(f"No supported dark frames in {settings.darks_dir}.")
        dark, level = master_dark(darks, load_options)
        load_options = LoadOptions(load_options.bin, load_options.gamma, load_options.hot_ratio, dark)
        dark_note = f"yes ({len(darks)} frames, level {level:.5f})"
        log(f"Master dark from {len(darks)} frames, level {level:.5f}")
        if level > 0.01:
            log("Warning: the dark frames are bright – is the lens really covered?")

    jobs = settings.jobs or min(os.cpu_count() or 1, 8)
    executor = (ProcessPoolExecutor(jobs, initializer=_init_worker, initargs=(load_options,)) if jobs > 1
                else _InlineExecutor())
    if jobs <= 1:
        _init_worker(load_options)
    with executor:
        # Pass 1: stars and noise of every frame.
        analyses: list[FrameAnalysis] = []
        for k, a in enumerate(_ordered(executor, _analyse, [(p, i.orientation) for p, i in zip(files, infos)],
                                       2 * jobs)):
            analyses.append(a)
            if (k + 1) % 10 == 0 or k + 1 == len(files):
                log(f"Analysed {k + 1}/{len(files)}: {len(a.positions)} stars, FWHM {a.fwhm:.2f} px, "
                    f"noise {a.noise:.5f}")
        shapes = {a.shape for a in analyses}
        if len(shapes) > 1:
            raise SystemExit(f"Frames have different sizes: {sorted(shapes)}")
        h, w = analyses[0].shape

        n_pairs = min(9, len(files) - 1)
        pair_starts = sorted({int(round(x)) for x in np.linspace(0, len(files) - 2, n_pairs)})
        models = [m for m in _ordered(executor, _noise_pair,
                                      [(files[i], files[i + 1], infos[i].orientation) for i in pair_starts], jobs)
                  if m is not None]
        if models:
            noise = NoiseModel(float(np.median([m.lambda_s for m in models])),
                               float(np.median([m.lambda_r for m in models])))
        else:
            sigma = float(np.median([a.noise for a in analyses]))
            noise = NoiseModel(0.0, sigma * sigma)
        log(f"Noise model: λs {noise.lambda_s:.3e}, λr {noise.lambda_r:.3e} ({len(models)} frame pairs)")

        # Frames shot with a different exposure (darks, test shots) are never stacked.
        exposures = [i.exposure for i in infos if i.exposure]
        typical_exposure = float(np.median(exposures)) if exposures else None
        wrong_exposure = [bool(typical_exposure and i.exposure and abs(i.exposure - typical_exposure) > 0.25 * typical_exposure)
                          for i in infos]

        counts = np.array([len(a.positions) for a in analyses])
        need = max(settings.min_reference_stars, int(0.5 * np.median(counts)))
        candidates = [k for k in range(len(files)) if counts[k] >= need and not wrong_exposure[k]]
        if not candidates:
            raise SystemExit(f"No frame has enough stars for a reference (need {need}, best {counts.max()}). "
                             "Check focus and exposure, or lower the threshold with --min-stars.")
        reference = candidates[0] if settings.reference == "first" else min(
            candidates, key=lambda k: (abs(k - (len(files) - 1) / 2), k))
        log(f"Reference frame: {files[reference].name} ({counts[reference]} stars)")

        camera, focal_known, focal_source = _camera(settings, infos[reference], analyses[reference])
        log(f"Camera: f {camera.focal:.1f} px (HFOV {camera.horizontal_fov:.1f}°) from {focal_source}")

        # Registration on the star lists.
        positions = [a.positions for a in analyses]
        usable = [not x for x in wrong_exposure]
        alignments, aligner = align_sequence(camera, positions, reference, usable)
        lens_note = None
        if settings.lens_fit:
            refined, lens_note = refine_camera(camera, positions, reference, alignments, focal_known, True)
            if lens_note:
                camera = refined
                log(lens_note)
                alignments, aligner = align_sequence(camera, positions, reference, usable)
        accepted = [k for k, a in enumerate(alignments) if a is not None and a.accepted]
        rejected = len(files) - len(accepted)
        homographies = {k: camera.homography(alignments[k].rotation) for k in accepted}
        drifts = {k: max_displacement(homographies[k], w, h) for k in accepted}
        rms = [alignments[k].rms for k in accepted if not alignments[k].is_reference]
        log(f"Registered {len(accepted)}/{len(files)} frames, median RMS {np.median(rms) if rms else 0:.2f} px, "
            f"max sky drift {max(drifts.values()):.1f} px")
        if len(accepted) < 2:
            raise SystemExit("Fewer than 2 frames could be registered – nothing to stack.")

        # Frame weight ∝ 1/σ² relative to the session's typical noise (haze, twilight, moonlight).
        typical_noise = float(np.median([analyses[k].noise for k in accepted]))
        weights = {k: float(np.clip((typical_noise / max(analyses[k].noise, 1e-12)) ** 2, 0.1, 1)) for k in accepted}

        orientation = analyses[reference].orientation
        ground = None if settings.ground == "none" else (
            GROUND_FROM_ORIENTATION.get(orientation) if settings.ground == "auto" else settings.ground)

        # Pass 2: stacking outwards from the reference.
        mapper = WarpMapper(camera)
        stacker = RobustStacker(w, h)
        builder_prior = None
        occlusion = None
        max_drift = 0.0
        sequence = sorted(accepted, key=lambda k: (abs(k - reference), k < reference))
        loads = _ordered(executor, _load_rgb, [(files[k], infos[k].orientation) for k in sequence], 2 * jobs)
        for n, (k, rgb) in enumerate(zip(sequence, loads), start=1):
            sx, sy = mapper.source_positions(homographies[k])
            drift = drifts[k]
            if np.isfinite(drift):
                max_drift = max(max_drift, drift)
            stacker.add(rgb, sx, sy, noise, weights[k], occlusion,
                        accumulate_plain=drift < RobustStacker.PLAIN_WINDOW_PIXELS)
            # Provisional ground mask: keeps sky samples that rotated behind the horizon out of the sky stack.
            if n % 30 == 0 and max_drift >= MASK_FREE_DRIFT:
                builder = SkyMaskBuilder(ground, builder_prior)
                builder_prior = builder.occlusion_mask(stacker.result())
                occlusion = builder_prior
            if n % 10 == 0 or n == len(sequence):
                log(f"Stacked {n}/{len(sequence)}")
        result = stacker.result()

    options = settings.finishing
    options.ground_direction = ground
    options.ground_prior = builder_prior
    options.sky_drift = max_drift
    log("Finishing (mask, vignetting, gradient, deconvolution, colour, stretch)")
    finished = finish(result, options)

    out = settings.output_dir or input_dir / datetime.now().strftime("astral_%Y-%m-%d_%H-%M-%S")
    out.mkdir(parents=True, exist_ok=True)
    write_jpeg(finished.display, out / "astral.jpg", orientation)
    write_linear_tiff(finished.linear, out / "astral_linear.tif", orientation)
    write_mask(finished.sky_mask, out / "mask.png", orientation)
    if settings.diag:
        write_diagnostics(result, out)

    ref_info = infos[reference]
    integration = sum(infos[k].exposure or 0 for k in accepted)
    a_ref = analyses[reference]
    lines = [
        f"AstralStack {__version__} (Linux) – {datetime.now():%Y-%m-%d %H:%M}",
        f"Input: {input_dir} – {len(files)} frames ({kind}), ordered by {order_note}"
        + (f", camera {ref_info.camera}" if ref_info.camera else ""),
        f"Frames: {len(accepted)} accepted / {len(files)} loaded, rejected {rejected} "
        f"(wrong exposure {sum(wrong_exposure)})",
        f"Total exposure: {integration:.0f} s" if integration else "Total exposure: unknown (no EXIF exposure)",
        f"Master dark: {dark_note}",
        f"Reference frame: {files[reference].name}",
        f"Frames: {a_ref.description}, binning {a_ref.binning}×, working grid {w}×{h}",
        f"Intrinsics: from {focal_source}, f {camera.focal:.1f} px (HFOV {camera.horizontal_fov:.1f}°), "
        f"cx {camera.center[0]:.1f}, cy {camera.center[1]:.1f}, distortion k1 {camera.k1:+.4f}",
        f"Actual ISO (EXIF): {_stats([i.iso for i in infos], '%.0f')}",
        f"Actual exposure (EXIF): {_stats([i.exposure for i in infos], '%.3f s')}",
        f"Raw background (0–1 of full scale): {_stats([a.background for a in analyses], '%.4f')}; "
        f"frame noise: {_stats([a.noise for a in analyses], '%.5f')}",
        f"Noise model: lambdaS {noise.lambda_s:.3e}, lambdaR {noise.lambda_r:.3e}",
        f"Registration: median RMS {np.median(rms) if rms else 0:.2f} px, catalogue {len(aligner.catalog)} stars",
        f"Sky drift: max {max_drift:.1f} px",
        f"EXIF orientation {orientation}, ground direction {ground or 'none'}",
    ]
    if lens_note:
        lines.append(lens_note)
    lines += finished.notes
    (out / "session.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    for note in finished.notes:
        log(note)
    log(f"Saved to {out}")
    return out
