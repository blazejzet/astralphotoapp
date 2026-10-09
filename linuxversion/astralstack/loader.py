"""Frame loading: RAW/DNG (Bayer super-pixel, as the app's `binBayer` kernel), TIFF/PNG/JPEG, FITS, plus EXIF."""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import numpy as np

RAW_EXTENSIONS = {".dng", ".cr2", ".cr3", ".crw", ".nef", ".nrw", ".arw", ".srf", ".sr2", ".raf", ".orf", ".rw2",
                  ".pef", ".srw", ".raw", ".3fr", ".iiq", ".erf", ".kdc", ".dcr", ".mrw", ".mos", ".x3f", ".rwl"}
RGB_EXTENSIONS = {".tif", ".tiff", ".png", ".jpg", ".jpeg"}
FITS_EXTENSIONS = {".fit", ".fits", ".fts"}
SUPPORTED_EXTENSIONS = RAW_EXTENSIONS | RGB_EXTENSIONS | FITS_EXTENSIONS


def kind_of(path: Path) -> str:
    ext = path.suffix.lower()
    if ext in RAW_EXTENSIONS:
        return "raw"
    if ext in FITS_EXTENSIONS:
        return "fits"
    return "rgb"


def _natural_key(path: Path):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", path.name)]


def discover(folder: Path) -> list[Path]:
    """Supported files of the dominant kind (RAW beats RGB beats FITS on ties), natural name order.
    Mixed folders are common: a camera writing RAW+JPEG keeps both."""
    files = [p for p in folder.iterdir() if p.is_file() and not p.name.startswith(".")
             and p.suffix.lower() in SUPPORTED_EXTENSIONS]
    if not files:
        return []
    kinds = {}
    for p in files:
        kinds.setdefault(kind_of(p), []).append(p)
    best = max(kinds, key=lambda k: (len(kinds[k]), {"raw": 2, "rgb": 1, "fits": 0}[k]))
    return sorted(kinds[best], key=_natural_key)


# MARK: - Metadata


@dataclass
class FrameInfo:
    path: Path
    timestamp: float | None = None
    exposure: float | None = None
    iso: float | None = None
    focal_mm: float | None = None
    focal_35mm: float | None = None
    focal_plane_px_per_mm: float | None = None
    orientation: int = 1
    camera: str | None = None


def _ratio(v) -> float | None:
    try:
        v = v.values[0] if hasattr(v, "values") else v
        if hasattr(v, "num"):
            return float(v.num) / float(v.den) if v.den else None
        return float(v)
    except (TypeError, ValueError, IndexError, ZeroDivisionError):
        return None


def _timestamp(text, subsec) -> float | None:
    try:
        t = datetime.strptime(str(text).strip(), "%Y:%m:%d %H:%M:%S").timestamp()
    except ValueError:
        return None
    if subsec is not None and str(subsec).strip().isdigit():
        s = str(subsec).strip()
        t += int(s) / 10 ** len(s)
    return t


def read_metadata(path: Path) -> FrameInfo:
    info = FrameInfo(path)
    tags = {}
    try:
        import exifread

        with open(path, "rb") as fh:
            tags = exifread.process_file(fh, details=False)
    except Exception:  # missing module or a format exifread does not parse
        tags = {}
    if tags:
        get = tags.get
        info.timestamp = _timestamp(get("EXIF DateTimeOriginal") or get("Image DateTime") or "",
                                    get("EXIF SubSecTimeOriginal"))
        info.exposure = _ratio(get("EXIF ExposureTime"))
        info.iso = _ratio(get("EXIF ISOSpeedRatings") or get("EXIF PhotographicSensitivity"))
        info.focal_mm = _ratio(get("EXIF FocalLength"))
        info.focal_35mm = _ratio(get("EXIF FocalLengthIn35mmFilm"))
        res, unit = _ratio(get("EXIF FocalPlaneXResolution")), _ratio(get("EXIF FocalPlaneResolutionUnit"))
        per_mm = {2: 1 / 25.4, 3: 0.1, 4: 1.0}.get(int(unit) if unit else 2)
        if res and per_mm:
            info.focal_plane_px_per_mm = res * per_mm
        o = _ratio(get("Image Orientation"))
        info.orientation = int(o) if o in (1, 2, 3, 4, 5, 6, 7, 8) else 1
        make, model = get("Image Make"), get("Image Model")
        info.camera = " ".join(str(x).strip() for x in (make, model) if x) or None
    elif kind_of(path) == "rgb":
        try:
            from PIL import Image

            with Image.open(path) as img:
                exif = img.getexif()
                sub = exif.get_ifd(0x8769)
                info.timestamp = _timestamp(sub.get(36867) or exif.get(306) or "", sub.get(37521))
                info.exposure = _ratio(sub.get(33434))
                info.iso = _ratio(sub.get(34855))
                info.focal_mm = _ratio(sub.get(37386))
                info.focal_35mm = _ratio(sub.get(41989))
                o = exif.get(274, 1)
                info.orientation = o if o in range(1, 9) else 1
                info.camera = " ".join(str(x).strip() for x in (exif.get(271), exif.get(272)) if x) or None
        except Exception:
            pass
    if info.focal_35mm == 0:
        info.focal_35mm = None
    return info


# MARK: - Pixels


@dataclass
class LoadOptions:
    bin: int | None = None  # None → RAW: 2×2 super-pixel; RGB: 2 above 16 MP, else 1
    gamma: str = "auto"  # auto | srgb | linear (8-bit files are sRGB-encoded, 16-bit/float assumed linear)
    hot_ratio: float = 8.0  # 0 disables the single-pixel hot filter
    dark: np.ndarray | None = None


@dataclass
class LoadedFrame:
    rgb: np.ndarray  # (3, H, W) float32, linear, 1.0 = white level
    orientation: int
    full_size: tuple[int, int]  # (W, H) of the image before binning (for focal lengths from EXIF)
    binning: int
    description: str


def hot_filtered(m: np.ndarray, ratio: float) -> np.ndarray:
    """Single-pixel spikes (hot pixels, cosmic rays): far above all 4 adjacent samples → replaced by the mean
    of the same-colour neighbours. Stars have a PSF wider than one pixel and survive."""
    if ratio <= 0:
        return m
    p = np.pad(m, 2, mode="edge")
    c = p[2:-2, 2:-2]
    n = np.maximum(np.maximum(p[2:-2, 1:-3], p[2:-2, 3:-1]), np.maximum(p[1:-3, 2:-2], p[3:-1, 2:-2]))
    hot = c > ratio * np.maximum(n, 0) + 0.01
    repl = 0.25 * (p[2:-2, :-4] + p[2:-2, 4:] + p[:-4, 2:-2] + p[4:, 2:-2])
    return np.where(hot, repl, c)


def superpixel(mosaic: np.ndarray, colors: np.ndarray) -> np.ndarray:
    """2×2 Bayer super-pixel without demosaicing: each output pixel averages its samples per colour
    (colors: 0 = R, 1 = G, 2 = B)."""
    h, w = mosaic.shape[0] // 2 * 2, mosaic.shape[1] // 2 * 2
    out = np.zeros((3, h // 2, w // 2), dtype=np.float32)
    count = np.zeros((3, 1, 1), dtype=np.float32)
    for dy in (0, 1):
        for dx in (0, 1):
            c = int(colors[dy, dx])
            out[c] += mosaic[dy:h:2, dx:w:2]
            count[c] += 1
    return out / np.maximum(count, 1)


def bin_rgb(rgb: np.ndarray, k: int) -> np.ndarray:
    if k <= 1:
        return rgb
    c, h, w = rgb.shape
    h, w = h // k * k, w // k * k
    return rgb[:, :h, :w].reshape(c, h // k, k, w // k, k).mean(axis=(2, 4)).astype(np.float32)


def srgb_to_linear(v: np.ndarray) -> np.ndarray:
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4).astype(np.float32)


_LIBRAW_FLIP_TO_EXIF = {0: 1, 3: 3, 5: 8, 6: 6}


def _load_raw(path: Path, options: LoadOptions):
    import rawpy

    with rawpy.imread(str(path)) as raw:
        orientation = _LIBRAW_FLIP_TO_EXIF.get(raw.sizes.flip, 1)
        pattern = raw.raw_pattern
        desc = raw.color_desc.decode(errors="ignore") if raw.color_desc else "RGBG"
        bayer = (raw.raw_type == rawpy.RawType.Flat and pattern is not None and pattern.shape == (2, 2)
                 and set(desc[:4]) <= set("RGB"))
        if bayer:
            mosaic = raw.raw_image_visible.astype(np.float32)
            colors = raw.raw_colors_visible
            black = np.array(raw.black_level_per_channel, dtype=np.float32)
            white = float(raw.white_level)
            # Some files state 12-bit levels for 14-bit data (iPhone 17 Pro DNG: 528/4095 vs samples up to 16383).
            top = float(np.percentile(mosaic[::7, ::7], 99.99))
            if top > white * 1.5:
                scale = 2.0 ** round(np.log2(top / white))
                black, white = black * scale, (white + 1) * scale - 1
            norm = (mosaic - black[colors]) / np.maximum(white - black[colors], 1)
            norm = hot_filtered(norm, options.hot_ratio)
            channel = np.array(["RGB".index(ch) for ch in desc[:4]])
            rgb = superpixel(norm, channel[colors[:2, :2]])
            full = (mosaic.shape[1], mosaic.shape[0])
            k = 2 * max(1, options.bin // 2) if options.bin else 2
            rgb = bin_rgb(rgb, k // 2)
            text = f"Bayer {desc[:4]} {pattern.ravel().tolist()}, black {black.mean():.0f}, white {white:.0f}"
            return rgb, orientation, full, k, text
        # X-Trans, linear DNG: LibRaw demosaics to linear camera RGB.
        out = raw.postprocess(gamma=(1, 1), no_auto_bright=True, output_bps=16, use_camera_wb=False,
                              use_auto_wb=False, user_wb=[1, 1, 1, 1], output_color=rawpy.ColorSpace.raw,
                              user_flip=0)
        rgb = np.moveaxis(out.astype(np.float32) / 65535, 2, 0)
        full = (rgb.shape[2], rgb.shape[1])
        k = options.bin or 2
        return bin_rgb(rgb, k), orientation, full, k, "demosaiced by LibRaw (non-Bayer sensor)"


def _load_rgb(path: Path, options: LoadOptions, orientation_hint: int):
    if path.suffix.lower() in (".tif", ".tiff"):
        import tifffile

        data = tifffile.imread(str(path))
        if data.ndim == 3 and data.shape[0] in (3, 4) and data.shape[2] not in (3, 4):
            data = np.moveaxis(data, 0, 2)
    else:
        from PIL import Image

        with Image.open(path) as img:
            data = np.asarray(img if img.mode in ("L", "I;16", "I", "F", "RGB") else img.convert("RGB"))
    # Pillow reads 16-bit greyscale PNG as 32-bit "I".
    max_hint = 65535.0 if data.dtype == np.int32 else None
    return _normalise(data, options, orientation_hint, path.suffix.lower().lstrip("."), max_hint)


def _normalise(data: np.ndarray, options: LoadOptions, orientation: int, label: str, max_hint: float | None = None):
    if np.issubdtype(data.dtype, np.integer):
        scale = float(np.iinfo(data.dtype).max) if max_hint is None else max_hint
        bits = 16 if max_hint else data.dtype.itemsize * 8
        v = data.astype(np.float32) / scale
    else:
        bits = 32
        v = data.astype(np.float32)
        if np.nanmax(v) > 2:
            v /= 65535
    if v.ndim == 2:
        v = np.stack([v, v, v], axis=2)
    v = np.moveaxis(v[..., :3], 2, 0)
    gamma = options.gamma if options.gamma != "auto" else ("srgb" if bits <= 8 else "linear")
    if gamma == "srgb":
        v = srgb_to_linear(np.clip(v, 0, 1))
    full = (v.shape[2], v.shape[1])
    k = options.bin if options.bin else (2 if full[0] * full[1] > 16_000_000 else 1)
    return bin_rgb(np.ascontiguousarray(v, dtype=np.float32), k), orientation, full, k, f"{label}, {bits}-bit, {gamma}"


def _load_fits(path: Path, options: LoadOptions):
    from astropy.io import fits

    with fits.open(path, memmap=False) as hdul:
        hdu = next(h for h in hdul if h.data is not None)
        data, header = np.asarray(hdu.data), hdu.header
    if str(header.get("ROWORDER", "")).upper() == "BOTTOM-UP":
        data = data[..., ::-1, :]
    max_hint = 65535.0 if data.dtype.kind in "iu" and data.dtype.itemsize >= 2 else None
    pattern = str(header.get("BAYERPAT", "")).strip().upper()
    if data.ndim == 2 and len(pattern) == 4 and set(pattern) <= set("RGB"):
        v = data.astype(np.float32) / (max_hint or (255.0 if data.dtype.kind in "iu" else 1.0))
        v = hot_filtered(v, options.hot_ratio)
        colors = np.array(["RGB".index(c) for c in pattern]).reshape(2, 2)
        rgb = superpixel(v, colors)
        k = 2 * max(1, (options.bin or 2) // 2)
        return bin_rgb(rgb, k // 2), 1, (v.shape[1], v.shape[0]), k, f"FITS Bayer {pattern}"
    if data.ndim == 3 and data.shape[0] == 3:
        data = np.moveaxis(data, 0, 2)
    return _normalise(data, options, 1, "FITS", max_hint)


def load_frame(path: Path, options: LoadOptions, orientation_hint: int = 1) -> LoadedFrame:
    kind = kind_of(path)
    if kind == "raw":
        rgb, orientation, full, k, text = _load_raw(path, options)
    elif kind == "fits":
        rgb, orientation, full, k, text = _load_fits(path, options)
    else:
        rgb, orientation, full, k, text = _load_rgb(path, options, orientation_hint)
    if options.dark is not None:
        if options.dark.shape != rgb.shape:
            raise ValueError(f"master dark {options.dark.shape[1:]} does not match {path.name} {rgb.shape[1:]}")
        rgb = rgb - options.dark
    return LoadedFrame(np.ascontiguousarray(rgb, dtype=np.float32), orientation, full, k, text)


def master_dark(paths: list[Path], options: LoadOptions) -> tuple[np.ndarray, float]:
    """Mean of the dark frames (each already hot-pixel filtered) → (dark, level)."""
    total = None
    for p in paths:
        frame = load_frame(p, LoadOptions(options.bin, options.gamma, options.hot_ratio, None))
        total = frame.rgb.astype(np.float64) if total is None else total + frame.rgb
    dark = (total / len(paths)).astype(np.float32)
    return dark, float(np.median(dark))
