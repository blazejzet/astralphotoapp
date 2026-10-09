"""Output files, same set as the app's ExportService (astral.jpg, astral_linear.tif, mask.png, session.txt, diag_*)."""

from __future__ import annotations

from pathlib import Path

import numpy as np

from .stacking import StackResult


def oriented(image: np.ndarray, orientation: int) -> np.ndarray:
    """Applies an EXIF orientation to an (H, W, …) array, so that the result displays upright without metadata."""
    ops = {
        1: lambda a: a,
        2: lambda a: a[:, ::-1],
        3: lambda a: a[::-1, ::-1],
        4: lambda a: a[::-1, :],
        5: lambda a: np.swapaxes(a, 0, 1),
        6: lambda a: np.rot90(a, k=-1, axes=(0, 1)),
        7: lambda a: np.rot90(a, k=-1, axes=(0, 1))[::-1, :],
        8: lambda a: np.rot90(a, k=1, axes=(0, 1)),
    }
    return np.ascontiguousarray(ops.get(orientation, ops[1])(image))


def _hwc(rgb: np.ndarray) -> np.ndarray:
    return np.moveaxis(rgb, 0, 2)


def write_jpeg(display: np.ndarray, path: Path, orientation: int, quality: int = 95):
    from PIL import Image

    data = (np.clip(_hwc(display), 0, 1) * 255 + 0.5).astype(np.uint8)
    Image.fromarray(oriented(data, orientation)).save(path, quality=quality, subsampling=0)


def write_linear_tiff(rgb: np.ndarray, path: Path, orientation: int | None = None):
    """32-bit float linear RGB (readable by Siril, PixInsight, GIMP). `orientation` None → sensor grid as is."""
    import tifffile

    data = _hwc(rgb).astype(np.float32)
    if orientation is not None:
        data = oriented(data, orientation)
    tifffile.imwrite(path, np.ascontiguousarray(data), photometric="rgb", compression="zlib")


def write_mask(mask: np.ndarray, path: Path, orientation: int):
    """Sky mask (white = sky stack, black = foreground stack) on the sensor grid with the EXIF orientation,
    exactly like the app writes it (the Tools/ package reads it back onto the diag_* stacks)."""
    from PIL import Image

    img = Image.fromarray((np.clip(mask, 0, 1) * 255 + 0.5).astype(np.uint8), mode="L")
    exif = Image.Exif()
    exif[274] = orientation
    img.save(path, exif=exif.tobytes())


def write_diagnostics(stack: StackResult, folder: Path):
    """Raw two-layer stacks (sensor grid, no orientation) for offline analysis with Tools/ (Refinish, MaskLab…)."""
    write_linear_tiff(stack.sky, folder / "diag_sky.tif")
    write_linear_tiff(stack.foreground, folder / "diag_ground.tif")
    variances = np.stack([np.minimum(stack.sky_variance, 1), stack.foreground_variance, stack.sky_weight])
    write_linear_tiff(variances, folder / "diag_skyvar_groundvar_weight.tif")
    if stack.sky_plain_mean is not None and stack.sky_plain_variance is not None:
        pm, pv = stack.sky_plain_mean, stack.sky_plain_variance
        plain = np.stack([np.where(np.isfinite(pm), pm, -1), np.where(np.isfinite(pv), pv, -1), np.zeros_like(pm)])
        write_linear_tiff(plain, folder / "diag_skyplain_mean_var.tif")
