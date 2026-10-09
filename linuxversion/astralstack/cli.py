"""Command line: astralstack <folder> [options]."""

from __future__ import annotations

import argparse
from pathlib import Path

from .finishing import FinishingOptions
from .loader import LoadOptions
from .pipeline import Log, Settings, run


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="astralstack",
        description="Stacks a folder of short sky exposures from a tripod: registers the sky on its rotation, "
                    "keeps a separate static foreground stack and blends them with an automatic sky mask.")
    p.add_argument("input", type=Path, help="folder with the frames (RAW/DNG, TIFF, PNG, JPEG or FITS)")
    p.add_argument("-o", "--output", type=Path, help="output folder (default: <input>/astral_<date>_<time>)")
    p.add_argument("--darks", type=Path, help="folder with dark frames (same camera settings, lens covered)")
    p.add_argument("--reference", choices=["middle", "first"], default="middle",
                   help="reference frame (default: middle – the smallest drift to both ends)")
    p.add_argument("--ground", choices=["auto", "down", "up", "left", "right", "none"], default="auto",
                   help="where the ground is in the stored image (default: from the EXIF orientation); "
                        "'none' for a sky-only frame or an unknown direction")

    lens = p.add_argument_group("lens (default: from EXIF, refined on the stars)")
    lens.add_argument("--focal-px", type=float, help="focal length in pixels of the full-resolution image")
    lens.add_argument("--fov", type=float, help="field of view along the longer side, degrees")
    lens.add_argument("--focal-mm", type=float, help="focal length in mm (with --crop-factor)")
    lens.add_argument("--crop-factor", type=float, help="sensor crop factor (1.0 = full frame)")
    lens.add_argument("--no-lens-fit", action="store_true", help="do not refine focal length and distortion")

    inp = p.add_argument_group("input")
    inp.add_argument("--bin", type=int, help="binning factor relative to the sensor (RAW: 2 = Bayer super-pixel, "
                                             "default; RGB files: default 2 above 16 MP, else 1)")
    inp.add_argument("--gamma", choices=["auto", "srgb", "linear"], default="auto",
                     help="encoding of RGB files (auto: 8-bit = sRGB, 16-bit/float = linear)")
    inp.add_argument("--no-hot-filter", action="store_true", help="disable the single-pixel hot pixel filter")
    inp.add_argument("--max-frames", type=int, help="use only the first N frames")
    inp.add_argument("--min-stars", type=int, default=12, help="minimum stars in the reference frame (default 12)")

    fin = p.add_argument_group("finishing")
    fin.add_argument("--no-gradient", action="store_true", help="keep the light-pollution gradient")
    fin.add_argument("--no-vignetting", action="store_true", help="no lens falloff correction")
    fin.add_argument("--no-color", action="store_true", help="no white balance from stars")
    fin.add_argument("--deconvolution", type=int, default=15, metavar="N",
                     help="Richardson–Lucy iterations (0 = off, default 15)")
    fin.add_argument("--background", type=float, default=0.12,
                     help="sky background brightness after the stretch, 0…1 (default 0.12)")

    p.add_argument("--diag", action="store_true", help="also write the diag_* stacks (for Tools/Refinish, MaskLab)")
    p.add_argument("-j", "--jobs", type=int, default=0, help="worker processes (default: CPUs, max 8)")
    p.add_argument("-q", "--quiet", action="store_true")
    args = p.parse_args(argv)

    if not args.input.is_dir():
        p.error(f"{args.input} is not a folder")
    finishing = FinishingOptions(
        remove_gradient=not args.no_gradient,
        correct_vignetting=not args.no_vignetting,
        deconvolution_iterations=max(args.deconvolution, 0),
        color_calibration=not args.no_color,
        background_level=args.background,
    )
    settings = Settings(
        input_dir=args.input,
        output_dir=args.output,
        darks_dir=args.darks,
        reference=args.reference,
        ground=args.ground,
        focal_px=args.focal_px,
        fov=args.fov,
        focal_mm=args.focal_mm,
        crop_factor=args.crop_factor,
        lens_fit=not args.no_lens_fit,
        load=LoadOptions(bin=args.bin, gamma=args.gamma, hot_ratio=0 if args.no_hot_filter else 8.0),
        finishing=finishing,
        diag=args.diag,
        jobs=args.jobs,
        max_frames=args.max_frames,
        min_reference_stars=args.min_stars,
    )
    out = run(settings, Log(args.quiet))
    print(out)


if __name__ == "__main__":
    main()
