import Foundation

public struct FinishingOptions: Sendable {
    public var removeGradient = true
    /// Radial lens-falloff post-filter (Bayer RAW has no lens-shading correction).
    public var correctVignetting = true
    public var deconvolutionIterations = 15
    public var colorCalibration = true
    /// Background brightness after stretching (0…1).
    public var backgroundLevel: Float = 0.12
    /// Gravity direction in the sensor buffer; enables the horizon-line sky mask.
    public var groundDirection: ImageDirection?
    /// Sticky ground mask from capture (see `SkyMaskBuilder.groundPrior`).
    public var groundPrior: PlanarImage?
    /// Largest sky displacement over the session (px). Below `maskFreeDrift` the static
    /// scenery is as sharp in the registered stack as in the foreground one, so no mask is needed.
    public var skyDrift: Double?
    /// Precomputed sky mask (offline re-finishing of saved stacks); nil → built from the stacks.
    public var skyMask: PlanarImage?

    /// Sky drift (px) below which no mask is applied: star trails shorter than the PSF.
    public static let maskFreeDrift = 2.0

    public init() {}
}

public struct FinishedImage: Sendable {
    /// Linear (calibrated, blended) image for further processing (Siril / PixInsight).
    public var linear: RGBImage
    /// Stretched display image, 0…1.
    public var display: RGBImage
    public var skyMask: PlanarImage
    public var psf: PlanarImage?
    public var notes: [String]
}

/// Linear post-processing of the two stacks, then display stretch:
/// mask → vignetting → background neutralisation → gradient removal → PSF + Richardson–Lucy on the sky
/// → star-based white balance → α-blend (sky / foreground) → clipped highlights → asinh stretch.
/// The mask only decides which stack a pixel comes from and which pixels feed the statistics. Every
/// correction is applied identically (or as one smooth field) to both layers and the blend is stretched
/// once, so where the stacks agree – any featureless area, i.e. most mask mistakes – the seam is invisible.
public enum Finisher {
    public static func finish(_ stack: StackResult, options: FinishingOptions = .init()) -> FinishedImage {
        var notes: [String] = []
        let mask = options.skyMask
            ?? SkyMaskBuilder(groundDirection: options.groundDirection, groundPrior: options.groundPrior).build(from: stack)
        let skyFraction = mask.pixels.reduce(0, +) / Float(max(mask.pixels.count, 1))
        notes.append(String(format: "Sky mask: %.0f%% of the frame", skyFraction * 100))
        let skyRegion = mask.map { $0 >= 0.9 ? 1 : 0 }
        let hasSky = skyRegion.pixels.reduce(0, +) > Float(mask.pixels.count) * 0.05
        // With negligible drift the registered stack is as sharp on the scenery as the static one (and has
        // the robust rejection), so it is used everywhere; the mask still selects the statistics region.
        var alpha = mask
        if let drift = options.skyDrift, drift < FinishingOptions.maskFreeDrift {
            alpha = stack.skyWeight.map { $0 > 0 ? 1 : 0 }
            notes.append(String(format: "Sky drift %.1f px: registered stack used for the whole frame", drift))
        }

        var sky = stack.sky
        var foreground = stack.foreground
        // Pixels never covered by the registered stack fall back to the foreground.
        for i in 0..<sky.r.count where stack.skyWeight.pixels[i] <= 0 {
            sky.r[i] = foreground.r[i]; sky.g[i] = foreground.g[i]; sky.b[i] = foreground.b[i]
        }
        let skyClipping = Highlights.clipping(sky)
        let fgClipping = Highlights.clipping(foreground)

        if options.correctVignetting, hasSky, let model = VignettingCorrection.fit(sky, mask: skyRegion) {
            VignettingCorrection.apply(model, to: &sky)
            VignettingCorrection.apply(model, to: &foreground)
            notes.append(String(format: "Vignetting corrected: corners at %.0f%% / %.0f%% / %.0f%% of centre brightness (R/G/B)",
                                model.cornerFalloff(channel: 0) * 100, model.cornerFalloff(channel: 1) * 100,
                                model.cornerFalloff(channel: 2) * 100))
        }

        if hasSky {
            let offsets = ColorCalibration.backgroundOffsets(sky, mask: skyRegion)
            ColorCalibration.apply(offsets: offsets, to: &sky)
            ColorCalibration.apply(offsets: offsets, to: &foreground)
            if options.removeGradient {
                let correction = GradientRemoval.correction(for: sky, mask: skyRegion)
                GradientRemoval.apply(correction, to: &sky)
                GradientRemoval.apply(correction, to: &foreground)
                notes.append("Background gradient removed (quadratic surface + radial terms)")
            }
        }

        let skyLuma = sky.luminance
        let (bg, noise) = Statistics.backgroundAndNoise(skyLuma, mask: hasSky ? skyRegion : nil)
        let detection = StarDetector().detect(in: skyLuma, mask: hasSky ? skyRegion : nil)
        notes.append("Stars in stack: \(detection.stars.count)")

        var psf: PlanarImage?
        if options.deconvolutionIterations > 0,
           let estimated = PSFEstimator.estimate(luma: skyLuma, stars: detection.stars, background: bg) {
            psf = estimated
            let sharpened = Deconvolution.richardsonLucy(skyLuma, psf: estimated, background: bg, noise: noise,
                                                         iterations: options.deconvolutionIterations)
            for i in 0..<sky.r.count {
                let before = skyLuma.pixels[i] - bg
                guard before > noise else { continue }
                let ratio = min(max((sharpened.pixels[i] - bg) / before, 0), 4)
                sky.r[i] = (sky.r[i] - bg) * ratio + bg
                sky.g[i] = (sky.g[i] - bg) * ratio + bg
                sky.b[i] = (sky.b[i] - bg) * ratio + bg
            }
            notes.append("Richardson–Lucy deconvolution: \(options.deconvolutionIterations) iterations, PSF \(estimated.width)×\(estimated.height)")
        }

        if options.colorCalibration, detection.stars.count >= 10 {
            let gains = ColorCalibration.starGains(sky, stars: detection.stars, background: bg)
            ColorCalibration.apply(gains: gains, to: &sky, background: bg)
            ColorCalibration.apply(gains: gains, to: &foreground, background: bg)
            notes.append(String(format: "White balance from stars: R×%.2f B×%.2f", gains.x, gains.z))
        }

        var linear = RGBImage(width: sky.width, height: sky.height)
        var clipping = PlanarImage(width: sky.width, height: sky.height)
        for i in 0..<linear.r.count {
            let a = alpha.pixels[i]
            linear.r[i] = a * sky.r[i] + (1 - a) * foreground.r[i]
            linear.g[i] = a * sky.g[i] + (1 - a) * foreground.g[i]
            linear.b[i] = a * sky.b[i] + (1 - a) * foreground.b[i]
            clipping.pixels[i] = a * skyClipping.pixels[i] + (1 - a) * fgClipping.pixels[i]
        }
        Highlights.neutralize(&linear, clipping: clipping)

        let stretch = AsinhStretch.automatic(luma: linear.luminance, mask: hasSky ? skyRegion : nil,
                                             backgroundLevel: options.backgroundLevel)
        let display = stretch.apply(linear)
        return FinishedImage(linear: linear, display: display, skyMask: alpha, psf: psf, notes: notes)
    }
}
