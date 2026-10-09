import AstralCore
import CoreGraphics
import QuartzCore
import CoreVideo
import Foundation
import ImageIO
import simd

/// What actually happened in a session, written to sesja.txt (the first night showed that
/// requested and actual capture settings can differ).
struct SessionDiagnostics {
    var pixelFormat = "?"
    var bufferSize = "?"
    var crop = "none"
    var levels = "?"
    var intrinsics = "?"
    var isoValues: [Float] = []
    var exposureValues: [Double] = []
    var rawBackground: [Double] = []
    var rawNoise: [Double] = []
    var levelsNote = "?"
    var rawDarkest: Float?
    /// Sticky ground mask accumulated during capture (prior for the final sky mask).
    var groundMask: PlanarImage?
    /// Largest sky displacement from the reference frame (px), see `FinishingOptions.skyDrift`.
    var maxSkyDrift = 0.0

    private func stats<T: BinaryFloatingPoint>(_ v: [T], _ format: String) -> String {
        guard !v.isEmpty else { return "no data" }
        let s = v.sorted()
        return String(format: "median \(format), min \(format), max \(format)", Double(s[s.count / 2]), Double(s[0]), Double(s[s.count - 1]))
    }

    var lines: [String] {
        [
            "RAW: format \(pixelFormat), buffer \(bufferSize), image area \(crop), levels \(levels)",
            "Levels: \(levelsNote); darkest raw value (0.1 %): \(rawDarkest.map { String(format: "%.0f", $0) } ?? "?")",
            "Intrinsics: \(intrinsics)",
            "Actual ISO (EXIF): \(stats(isoValues, "%.0f"))",
            "Actual exposure (EXIF): \(stats(exposureValues, "%.3f s"))",
            "Raw background (0–1 of full scale): \(stats(rawBackground, "%.4f")); frame noise: \(stats(rawNoise, "%.5f"))",
            String(format: "Sky drift: max %.1f px", maxSkyDrift),
        ]
    }
}

struct LiveStats: Equatable {
    var captured = 0
    var accepted = 0
    var rejected = 0
    /// Frames shot with the wrong exposure (iOS reset the camera to auto) – never stacked.
    var wrongExposure = 0
    var dropped = 0
    var integration: Double = 0
    var stars = 0
    var matched = 0
    var rms: Double = 0
    var poleFitted = false
    var poleFitRMS: Double?
    var poleOffsetFromPrior: Double?
    var focalScale: Double = 1
    var focusFWHM: Double?
    /// Σ peak S/N of the brightest stars (FocusSweep metric).
    var focusScore: Double = 0
    var noiseSigma: Double = 0
    var darkFrames = 0
    var masterDark = false
    var lastFrameMillis: Double = 0
    var actualISO: Float?
    var actualExposure: Double?
}

enum ProcessingMode: Equatable {
    case framing
    case darks(target: Int)
    case stacking
}

struct ProcessorUpdate {
    var preview: CGImage?
    var stats: LiveStats
    var mode: ProcessingMode
    var message: String?
}

/// Everything that happens to a sub-exposure, on one serial queue:
/// RAW → GPU binning → luma → noise model → star detection → alignment (pole model + rigid drift)
/// → GPU robust merge of the sky + static merge of the foreground → provisional occlusion mask → preview.
final class FrameProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "astral.processing", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = 0
    private var droppedFrames = 0
    private let stacker: MetalStacker

    private var mode: ProcessingMode = .framing
    private var levels: RawLevels?
    private var levelsAttempted = false
    private var colorIndex: SIMD4<UInt32>?
    private var useDNGFallback = false
    private var engine: AlignmentEngine?
    private var priorPole: SIMD3<Double>?
    private var groundDirection: ImageDirection?
    private var poleElevation: PoleElevationConstraint?
    private var previousLuma: PlanarImage?
    private var noise = NoiseModel(lambdaS: 1e-4, lambdaR: 1e-6)
    private var noiseHistory: [Double] = []
    private var detectionMask: PlanarImage?
    private var weighting = RobustWeighting()
    private var stats = LiveStats()
    private var diagnostics = SessionDiagnostics()
    private var lastCrop: RawCrop?
    private var detector: StarDetector = {
        var c = StarDetector.Configuration()
        c.maxStars = 150
        return StarDetector(configuration: c)
    }()

    var zoom = false
    var onUpdate: ((ProcessorUpdate) -> Void)?

    init() throws {
        stacker = try MetalStacker()
    }

    /// The camera asks before each capture whether DNG data must be attached.
    var needsDNG: Bool {
        lock.lock(); defer { lock.unlock() }
        return !levelsAttempted || useDNGFallback
    }

    func submit(_ frame: CapturedFrame) {
        lock.lock()
        if pending >= 2 {
            droppedFrames += 1
            lock.unlock()
            return
        }
        pending += 1
        lock.unlock()
        queue.async {
            self.process(frame)
            self.lock.lock()
            self.pending -= 1
            self.lock.unlock()
        }
    }

    func setZoom(_ value: Bool) { queue.async { self.zoom = value } }

    func startFraming() {
        queue.async { self.mode = .framing }
    }

    func startDarks(count: Int) {
        queue.async {
            self.stacker.clearDark()
            self.stats.darkFrames = 0
            self.stats.masterDark = false
            self.mode = .darks(target: count)
        }
    }

    func clearDarks() {
        queue.async {
            self.stacker.clearDark()
            self.stats.masterDark = false
            self.stats.darkFrames = 0
        }
    }

    func startStacking(priorPole: SIMD3<Double>?, groundDirection: ImageDirection?, poleElevation: PoleElevationConstraint?) {
        queue.async {
            self.poleElevation = poleElevation
            self.priorPole = priorPole
            self.groundDirection = groundDirection
            self.engine = nil
            self.stacker.resetStack()
            self.detectionMask = nil
            self.noiseHistory = []
            let darks = self.stats
            self.stats = LiveStats()
            self.lock.lock()
            self.droppedFrames = 0
            self.lock.unlock()
            self.stats.darkFrames = darks.darkFrames
            self.stats.masterDark = darks.masterDark
            self.diagnostics.isoValues = []
            self.diagnostics.exposureValues = []
            self.diagnostics.rawBackground = []
            self.diagnostics.rawNoise = []
            self.diagnostics.groundMask = nil
            self.diagnostics.maxSkyDrift = 0
            self.mode = .stacking
        }
    }

    /// Stops stacking and hands back the accumulated stacks.
    func finish(completion: @escaping (StackResult?, LiveStats, AlignmentEngine?, SessionDiagnostics) -> Void) {
        queue.async {
            self.mode = .framing
            let result = self.stacker.readStack()
            completion(result, self.stats, self.engine, self.diagnostics)
        }
    }

    // MARK: - Pipeline

    private func process(_ frame: CapturedFrame) {
        let start = CACurrentMediaTime()
        do {
            try load(frame)
        } catch {
            emit(preview: nil, message: String(localized: "RAW decoding error: \(String(describing: error))"))
            return
        }
        stats.captured += 1
        stats.actualISO = frame.exifISO
        stats.actualExposure = frame.exifExposure
        let luma = stacker.currentLuma()
        if let previous = previousLuma, stats.captured % 5 == 0,
           let estimate = NoiseModelEstimator().estimate(current: luma, previous: previous) {
            noise = estimate
        }
        previousLuma = luma
        stats.noiseSigma = noise.variance(at: 0).squareRoot()

        var preview: CGImage?
        var message: String?
        switch mode {
        case .framing:
            let detection = detector.detect(in: luma)
            stats.stars = detection.stars.count
            let bright = detection.stars.prefix(30).map(\.fwhm).sorted()
            stats.focusFWHM = bright.isEmpty ? nil : bright[bright.count / 2]
            stats.focusScore = FocusSweep.score(stars: detection.stars, noise: detection.noise)
            preview = makePreview(source: .frame)

        case .darks(let target):
            stacker.accumulateDark()
            stats.darkFrames = stacker.darkFrames
            if stacker.darkFrames >= target {
                let level = stacker.finalizeDark()
                mode = .framing
                // Fourth night: a "dark" with sky in it wiped the sky background to zero.
                if level > 0.0008 {
                    stacker.clearDark()
                    stats.masterDark = false
                    stats.darkFrames = 0
                    message = String(localized: "The dark frames contain light (level \(String(format: "%.4f", level))). Cover the lens completely and try again.")
                } else {
                    stats.masterDark = true
                    message = String(localized: "Master dark ready (\(target) frames).")
                }
            }
            preview = makePreview(source: .frame)

        case .stacking:
            message = stack(frame: frame, luma: luma)
            preview = makePreview(source: .stack)
        }
        stats.lastFrameMillis = (CACurrentMediaTime() - start) * 1000
        emit(preview: preview, message: message)
    }

    private func load(_ frame: CapturedFrame) throws {
        if !levelsAttempted, let dng = frame.dng {
            levelsAttempted = true
            levels = Self.rawLevels(fromDNG: dng)
            if levels == nil {
                // No DNG levels: assume a zero black level; the background offset is removed later
                // by gradient removal and the stretch black point.
                levels = RawLevels(black: SIMD4(repeating: 0), white: 16383)
                emit(preview: nil, message: String(localized: "No black level in the DNG – assuming 0."))
            }
            if let raw = frame.raw, var lv = levels {
                let dngLevels = String(format: "%.0f/%.0f", lv.black.x, lv.white)
                lv = Self.reconcile(lv, bufferBits: Self.bitDepth(for: raw.pixelFormat))
                levels = lv
                diagnostics.rawDarkest = Self.darkestRawValue(raw, crop: lv.crop)
                diagnostics.levelsNote = "DNG \(dngLevels) → buffer \(String(format: "%.0f/%.0f", lv.black.x, lv.white))"
            }
        }
        if let raw = frame.raw {
            diagnostics.pixelFormat = CameraController.fourCC(raw.pixelFormat)
            diagnostics.bufferSize = "\(raw.width)×\(raw.height), \(raw.rowBytes) B/row"
        }
        if let lv = levels {
            diagnostics.levels = String(format: "black %.0f, white %.0f", lv.black.x, lv.white)
            if let c = lv.crop { diagnostics.crop = "x \(c.x), y \(c.y), \(c.width)×\(c.height)" }
        }
        if !useDNGFallback, let raw = frame.raw, let cfa = Self.colorIndex(for: raw.pixelFormat) {
            colorIndex = cfa
            let lv = levels ?? RawLevels(black: SIMD4(repeating: 0), white: 16383)
            try stacker.load(bayer: raw, colorIndex: cfa, levels: lv)
            return
        }
        useDNGFallback = true
        guard let dng = frame.dng else { throw StackerError.rawDecodeFailed }
        try stacker.load(dng: dng)
    }

    private func stack(frame: CapturedFrame, luma: PlanarImage) -> String? {
        if engine == nil {
            let w = stacker.width, h = stacker.height
            let intrinsics: CameraIntrinsics
            var distortion: LensDistortion?
            if let cal = frame.calibration {
                intrinsics = cal.intrinsics.scaled(toWidth: w, height: h)
                distortion = cal.distortion?.scaled(toWidth: w, height: h)
            } else {
                intrinsics = CameraIntrinsics(horizontalFieldOfViewDegrees: frame.fieldOfView, width: w, height: h)
            }
            engine = AlignmentEngine(intrinsics: intrinsics, distortion: distortion, priorPole: priorPole,
                                     poleElevation: poleElevation)
            diagnostics.intrinsics = String(format: "%@, fx %.1f px, cx %.1f, cy %.1f, %d×%d, distortion LUT: %@",
                                            frame.calibration == nil ? "from field of view \(String(format: "%.1f°", frame.fieldOfView))" : "AVCameraCalibrationData",
                                            intrinsics.fx, intrinsics.cx, intrinsics.cy, w, h, distortion == nil ? "no" : "yes")
        }
        guard let engine else { return nil }

        if frame.exposureMismatch {
            stats.wrongExposure += 1
            stats.rejected += 1
            return String(localized: "iOS changed the exposure to \(String(format: "%.3f", frame.exifExposure ?? 0)) s – restoring manual settings; these frames are skipped.")
        }
        let detection = detector.detect(in: luma, mask: detectionMask)
        stats.stars = detection.stars.count
        if let iso = frame.exifISO { diagnostics.isoValues.append(iso) }
        if let t = frame.exifExposure { diagnostics.exposureValues.append(t) }
        diagnostics.rawBackground.append(detection.background)
        diagnostics.rawNoise.append(detection.noise)
        let alignment = engine.process(stars: detection.stars, timestamp: frame.timestamp)
        stats.matched = alignment.matchedStars
        stats.rms = alignment.rmsResidual.isFinite ? alignment.rmsResidual : 0
        stats.poleFitted = engine.poleFitted
        stats.poleFitRMS = engine.lastFit?.rms
        stats.focalScale = engine.focalScale
        if let prior = priorPole, let pole = engine.pole, engine.poleFitted {
            stats.poleOffsetFromPrior = acos(min(max(simd_dot(simd_normalize(prior), pole), -1), 1)) * 180 / .pi
        }
        guard alignment.accepted else {
            stats.rejected += 1
            return alignment.matchedStars < 8 ? String(localized: "Too few stars to match (\(alignment.matchedStars)).") : nil
        }

        // Frame weight ∝ 1/σ² relative to the session's typical noise (haze, twilight, moonlight).
        noiseHistory.append(detection.noise)
        let typical = noiseHistory.sorted()[noiseHistory.count / 2]
        let frameWeight = Float(min(1, max(0.1, pow(typical / max(detection.noise, 1e-12), 2))))

        stacker.accumulateForeground()
        // Unweighted mask statistics only while the sky has drifted little (no horizon contamination yet).
        let drift = CPUStacker.maxDisplacement(alignment.homography, width: stacker.width, height: stacker.height)
        if drift.isFinite { diagnostics.maxSkyDrift = max(diagnostics.maxSkyDrift, drift) }
        stacker.accumulateSky(homography: alignment.homography, distortion: engine.distortion,
                              noise: noise, weighting: weighting, frameWeight: frameWeight,
                              accumulatePlain: drift < CPUStacker.plainWindowPixels)
        stats.accepted += 1
        stats.integration += frame.exposure

        // Provisional ground mask: keeps sky samples that rotated behind the horizon out of the sky stack
        // and foreground lights out of the star detector. Not needed until the sky has actually moved
        // (the Finisher then uses the registered stack everywhere).
        if stats.accepted % 30 == 0, diagnostics.maxSkyDrift >= FinishingOptions.maskFreeDrift,
           let result = stacker.readStack() {
            let builder = SkyMaskBuilder(groundDirection: groundDirection, groundPrior: diagnostics.groundMask)
            // The previous mask is only a weak prior: once occluded sky samples are skipped the ground
            // produces less fresh evidence, but a union of all masks (tried) locked in early mistakes.
            diagnostics.groundMask = builder.occlusionMask(from: result)
            stacker.setOcclusion(diagnostics.groundMask)
            detectionMask = diagnostics.groundMask.map { $0.map { 1 - $0 } }
        }
        return nil
    }

    private func makePreview(source: MetalStacker.PreviewSource) -> CGImage? {
        guard let linear = stacker.preview(source: source, maxDimension: 720, zoom: zoom) else { return nil }
        let stretch = AsinhStretch.automatic(luma: linear.luminance, mask: nil, backgroundLevel: 0.12)
        return ImageExport.makeCGImage8(stretch.apply(linear))
    }

    private func emit(preview: CGImage?, message: String?) {
        lock.lock()
        stats.dropped = droppedFrames
        lock.unlock()
        onUpdate?(ProcessorUpdate(preview: preview, stats: stats, mode: mode, message: message))
    }

    // MARK: - RAW metadata

    static func bitDepth(for format: OSType) -> Int {
        switch format {
        case kCVPixelFormatType_14Bayer_RGGB, kCVPixelFormatType_14Bayer_GRBG,
             kCVPixelFormatType_14Bayer_GBRG, kCVPixelFormatType_14Bayer_BGGR: 14
        default: 16
        }
    }

    /// The iPhone 17 Pro DNG states 12-bit levels (black 528, white 4095) while the `bgg4` buffer holds
    /// 14-bit samples, i.e. the same data ×4. Unscaled, the true black (2112) read as a constant
    /// 44 % "sky" in every frame regardless of ISO and exposure – seen on all three field nights.
    static func reconcile(_ levels: RawLevels, bufferBits: Int) -> RawLevels {
        let full = Float((1 << bufferBits) - 1)
        guard levels.white > 0, levels.white * 1.5 < full else { return levels }
        let ratio = (full + 1) / (levels.white + 1)
        let scale = Float(1 << Int(log2(Double(ratio)).rounded()))
        guard scale > 1 else { return levels }
        var out = levels
        out.black = levels.black * scale
        out.white = (levels.white + 1) * scale - 1
        return out
    }

    /// 0.1 % quantile of raw samples in the image area – a dark sky sits just above the true black.
    static func darkestRawValue(_ raw: RawImage, crop: RawCrop?) -> Float? {
        raw.data.withUnsafeBytes { buffer -> Float? in
            guard let base = buffer.baseAddress else { return nil }
            let w = crop?.width ?? raw.width, h = crop?.height ?? raw.height
            let x0 = crop?.x ?? 0, y0 = crop?.y ?? 0
            var samples: [Float] = []
            samples.reserveCapacity(w * h / 289 + 1)
            var y = 0
            while y < h {
                let row = base.advanced(by: (y0 + y) * raw.rowBytes).assumingMemoryBound(to: UInt16.self)
                var x = 0
                while x < w { samples.append(Float(row[x0 + x])); x += 17 }
                y += 17
            }
            return Statistics.percentile(samples, 0.001)
        }
    }

    /// CFA colour at positions (0,0) (1,0) (0,1) (1,1) for the 14-bit-in-16 Bayer formats.
    static func colorIndex(for format: OSType) -> SIMD4<UInt32>? {
        switch format {
        case kCVPixelFormatType_14Bayer_RGGB: SIMD4(0, 1, 1, 2)
        case kCVPixelFormatType_14Bayer_GRBG: SIMD4(1, 0, 2, 1)
        case kCVPixelFormatType_14Bayer_GBRG: SIMD4(1, 2, 0, 1)
        case kCVPixelFormatType_14Bayer_BGGR: SIMD4(2, 1, 1, 0)
        default: nil
        }
    }

    static func rawLevels(fromDNG data: Data) -> RawLevels? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dng = props[kCGImagePropertyDNGDictionary] as? [CFString: Any] else { return nil }
        let black = numbers(dng[kCGImagePropertyDNGBlackLevel])
        let white = numbers(dng[kCGImagePropertyDNGWhiteLevel]).first
        guard let white, !black.isEmpty else { return nil }
        let b: SIMD4<Float> = black.count >= 4 ? SIMD4(black[0], black[1], black[2], black[3]) : SIMD4(repeating: black[0])
        return RawLevels(black: b, white: white, crop: imageArea(dng: dng, properties: props))
    }

    /// Image area in sensor-buffer pixels: ActiveArea [top, left, bottom, right] + DefaultCropOrigin/Size
    /// (DNG spec), falling back to the DNG's final pixel size anchored at the origin.
    static func imageArea(dng: [CFString: Any], properties: [CFString: Any]) -> RawCrop? {
        var x = 0, y = 0, width = 0, height = 0
        let active = numbers(dng[kCGImagePropertyDNGActiveArea]).map(Int.init)
        if active.count == 4 {
            y = active[0]; x = active[1]
            height = active[2] - active[0]; width = active[3] - active[1]
        }
        let origin = numbers(dng[kCGImagePropertyDNGDefaultCropOrigin]).map { Int($0.rounded()) }
        let size = numbers(dng[kCGImagePropertyDNGDefaultCropSize]).map { Int($0.rounded()) }
        if origin.count == 2, size.count == 2, size[0] > 0, size[1] > 0 {
            x += origin[0]; y += origin[1]
            width = size[0]; height = size[1]
        }
        if width == 0 || height == 0,
           let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int {
            width = w; height = h
        }
        guard width > 0, height > 0 else { return nil }
        // Even sizes keep the 2×2 binning grid whole.
        return RawCrop(x: x, y: y, width: width & ~1, height: height & ~1)
    }

    private static func numbers(_ value: Any?) -> [Float] {
        if let n = value as? NSNumber { return [n.floatValue] }
        if let a = value as? [NSNumber] { return a.map(\.floatValue) }
        return []
    }
}
