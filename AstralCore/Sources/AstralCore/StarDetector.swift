import Foundation

public struct Star: Sendable, Equatable {
    /// Intensity-weighted centroid, pixel centres on integer coordinates.
    public var position: SIMD2<Double>
    /// Background-subtracted flux inside the centroid window.
    public var flux: Double
    /// Background-subtracted peak value.
    public var peak: Double
    /// FWHM from second moments (Gaussian approximation).
    public var fwhm: Double

    public init(position: SIMD2<Double>, flux: Double, peak: Double, fwhm: Double) {
        self.position = position
        self.flux = flux
        self.peak = peak
        self.fwhm = fwhm
    }
}

public struct StarDetection: Sendable {
    public var stars: [Star]
    /// Global sky background (median of mesh modes).
    public var background: Double
    /// Per-pixel noise σ of the *input* image (white-noise estimate).
    public var noise: Double
}

/// SExtractor-style detection: mesh background (κσ-clipped mode = 2.5·med − 1.5·mean),
/// matched filter (≈ Gaussian σ = 1 px), threshold at kσ, local maxima, weighted centroids.
/// Bertin & Arnouts 1996 (A&AS 117, 393); SEP – Barbary 2016 (JOSS 1(6), 58).
public struct StarDetector: Sendable {
    public struct Configuration: Sendable {
        public var meshSize = 64
        public var thresholdSigma: Float = 5
        public var maxStars = 150
        public var minPixelsAboveThreshold = 3
        public var centroidRadius = 3
        public var edgeMargin = 6
        public init() {}
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func detect(in image: PlanarImage, mask: PlanarImage? = nil) -> StarDetection {
        let w = image.width, h = image.height
        let smooth = gaussianBlur5(image)
        let mesh = BackgroundMesh(image: smooth, meshSize: configuration.meshSize)
        let thr = configuration.thresholdSigma
        let margin = max(configuration.edgeMargin, configuration.centroidRadius + 2)
        let r = configuration.centroidRadius
        let globalFloor = mesh.minimumThreshold(kappa: thr)
        var candidates: [Star] = []

        guard w > 2 * margin, h > 2 * margin else {
            return StarDetection(stars: [], background: Double(mesh.globalBackground),
                                 noise: Double(mesh.globalSigma / gaussianBlur5NoiseFactor))
        }

        smooth.pixels.withUnsafeBufferPointer { s in
            image.pixels.withUnsafeBufferPointer { src in
                for y in margin..<(h - margin) {
                    for x in margin..<(w - margin) {
                        let i = y * w + x
                        let v = s[i]
                        if v <= globalFloor { continue }
                        let (bg, sigma) = mesh.value(x: x, y: y)
                        let t = bg + thr * sigma
                        if v <= t { continue }
                        // Strict local maximum in a 5×5 window (ties broken by scan order).
                        var isMax = true
                        scan: for dy in -2...2 {
                            for dx in -2...2 where dx != 0 || dy != 0 {
                                let n = s[i + dy * w + dx]
                                if n > v || (n == v && (dy < 0 || (dy == 0 && dx < 0))) { isMax = false; break scan }
                            }
                        }
                        if !isMax { continue }
                        var area = 0
                        for dy in -1...1 { for dx in -1...1 where s[i + dy * w + dx] > t { area += 1 } }
                        if area < configuration.minPixelsAboveThreshold { continue }
                        if let mask, mask.pixels[i] < 0.5 { continue }

                        var sw = 0.0, sx = 0.0, sy = 0.0, sr2 = 0.0
                        var peak: Float = -.greatestFiniteMagnitude
                        for dy in -r...r {
                            for dx in -r...r {
                                let raw = src[i + dy * w + dx]
                                peak = max(peak, raw)
                                let val = Double(raw - bg)
                                if val > 0 {
                                    sw += val
                                    sx += val * Double(dx)
                                    sy += val * Double(dy)
                                    sr2 += val * Double(dx * dx + dy * dy)
                                }
                            }
                        }
                        guard sw > 0 else { continue }
                        let mx = sx / sw, my = sy / sw
                        let perAxisVariance = max(sr2 / sw - mx * mx - my * my, 0) / 2
                        candidates.append(Star(position: SIMD2(Double(x) + mx, Double(y) + my),
                                               flux: sw, peak: Double(peak - bg),
                                               fwhm: 2.3548 * perAxisVariance.squareRoot()))
                    }
                }
            }
        }
        candidates.sort { $0.flux > $1.flux }
        if candidates.count > configuration.maxStars { candidates.removeLast(candidates.count - configuration.maxStars) }
        return StarDetection(stars: candidates, background: Double(mesh.globalBackground),
                             noise: Double(mesh.globalSigma / gaussianBlur5NoiseFactor))
    }
}

/// Coarse background/noise grid, bilinearly interpolated between mesh centres.
struct BackgroundMesh {
    let nx: Int
    let ny: Int
    let meshSize: Int
    var background: [Float]
    var sigma: [Float]

    init(image: PlanarImage, meshSize: Int) {
        let size = max(8, min(meshSize, min(image.width, image.height)))
        self.meshSize = size
        nx = max(1, image.width / size)
        ny = max(1, image.height / size)
        background = [Float](repeating: 0, count: nx * ny)
        sigma = [Float](repeating: 0, count: nx * ny)
        let stepX = image.width / nx, stepY = image.height / ny
        var samples: [Float] = []
        samples.reserveCapacity(stepX * stepY / 4 + 1)
        for ty in 0..<ny {
            for tx in 0..<nx {
                samples.removeAll(keepingCapacity: true)
                let x0 = tx * stepX, y0 = ty * stepY
                let x1 = tx == nx - 1 ? image.width : x0 + stepX
                let y1 = ty == ny - 1 ? image.height : y0 + stepY
                var y = y0
                while y < y1 {
                    var x = x0
                    while x < x1 { samples.append(image.pixels[y * image.width + x]); x += 2 }
                    y += 2
                }
                let st = Statistics.sigmaClipped(samples, kappa: 3, iterations: 4)
                let mode: Float
                if st.sigma > 0, abs(st.mean - st.median) / st.sigma < 0.3 {
                    mode = 2.5 * st.median - 1.5 * st.mean
                } else {
                    mode = st.median
                }
                background[ty * nx + tx] = mode
                sigma[ty * nx + tx] = max(st.sigma, 1e-9)
            }
        }
        self.stepX = Float(stepX)
        self.stepY = Float(stepY)
    }

    private let stepX: Float
    private let stepY: Float

    var globalBackground: Float { Statistics.median(background) }
    var globalSigma: Float { Statistics.median(sigma) }

    func minimumThreshold(kappa: Float) -> Float {
        var m = Float.greatestFiniteMagnitude
        for i in 0..<background.count { m = min(m, background[i] + kappa * sigma[i]) }
        return m
    }

    @inline(__always)
    func value(x: Int, y: Int) -> (Float, Float) {
        let gx = min(max((Float(x) + 0.5) / stepX - 0.5, 0), Float(nx - 1))
        let gy = min(max((Float(y) + 0.5) / stepY - 0.5, 0), Float(ny - 1))
        let x0 = min(Int(gx), max(nx - 2, 0)), y0 = min(Int(gy), max(ny - 2, 0))
        let x1 = min(x0 + 1, nx - 1), y1 = min(y0 + 1, ny - 1)
        let fx = gx - Float(x0), fy = gy - Float(y0)
        func lerp(_ a: [Float]) -> Float {
            let top = a[y0 * nx + x0] * (1 - fx) + a[y0 * nx + x1] * fx
            let bottom = a[y1 * nx + x0] * (1 - fx) + a[y1 * nx + x1] * fx
            return top * (1 - fy) + bottom * fy
        }
        return (lerp(background), lerp(sigma))
    }
}
