import Foundation

public struct PlanarImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height, "pixel count mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, repeating value: Float = 0) {
        self.init(width: width, height: height, pixels: [Float](repeating: value, count: width * height))
    }

    @inlinable
    public subscript(x: Int, y: Int) -> Float {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Bilinear sample; nil outside the valid interpolation domain.
    @inlinable
    public func bilinear(_ p: SIMD2<Double>) -> Float? {
        guard p.x >= 0, p.y >= 0, p.x <= Double(width - 1), p.y <= Double(height - 1) else { return nil }
        let x0 = min(Int(p.x), width - 2), y0 = min(Int(p.y), height - 2)
        let fx = Float(p.x - Double(x0)), fy = Float(p.y - Double(y0))
        let i = y0 * width + x0
        let top = pixels[i] * (1 - fx) + pixels[i + 1] * fx
        let bottom = pixels[i + width] * (1 - fx) + pixels[i + width + 1] * fx
        return top * (1 - fy) + bottom * fy
    }

    public func map(_ f: (Float) -> Float) -> PlanarImage {
        PlanarImage(width: width, height: height, pixels: pixels.map(f))
    }
}

/// Linear camera-RGB image (2×2 Bayer "super-pixel" in the app).
public struct RGBImage: Sendable {
    public let width: Int
    public let height: Int
    public var r: [Float]
    public var g: [Float]
    public var b: [Float]

    public init(width: Int, height: Int, repeating value: Float = 0) {
        self.width = width
        self.height = height
        let plane = [Float](repeating: value, count: width * height)
        r = plane; g = plane; b = plane
    }

    public init(width: Int, height: Int, r: [Float], g: [Float], b: [Float]) {
        precondition(r.count == width * height && g.count == r.count && b.count == r.count)
        self.width = width; self.height = height
        self.r = r; self.g = g; self.b = b
    }

    public init(gray: PlanarImage) {
        self.init(width: gray.width, height: gray.height, r: gray.pixels, g: gray.pixels, b: gray.pixels)
    }

    /// Luma used everywhere for detection and robust weighting: mean of the 4 Bayer samples = (R + 2G + B)/4.
    public var luminance: PlanarImage {
        var out = [Float](repeating: 0, count: r.count)
        for i in 0..<r.count { out[i] = (r[i] + 2 * g[i] + b[i]) * 0.25 }
        return PlanarImage(width: width, height: height, pixels: out)
    }

    public func channel(_ c: Int) -> PlanarImage {
        PlanarImage(width: width, height: height, pixels: c == 0 ? r : (c == 1 ? g : b))
    }

    public mutating func setChannel(_ c: Int, _ plane: PlanarImage) {
        switch c {
        case 0: r = plane.pixels
        case 1: g = plane.pixels
        default: b = plane.pixels
        }
    }
}

// MARK: - Statistics

public enum Statistics {
    public static func median(_ values: [Float]) -> Float {
        percentile(values, 0.5)
    }

    public static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }

    /// Iterative κ-σ clipping around the median.
    public static func sigmaClipped(_ values: [Float], kappa: Float = 3, iterations: Int = 3)
        -> (median: Float, mean: Float, sigma: Float) {
        var current = values.sorted()
        guard !current.isEmpty else { return (0, 0, 0) }
        var med: Float = 0, mean: Float = 0, sigma: Float = 0
        for _ in 0...iterations {
            med = current[current.count / 2]
            var s: Double = 0, s2: Double = 0
            for v in current { s += Double(v); s2 += Double(v) * Double(v) }
            let n = Double(current.count)
            mean = Float(s / n)
            sigma = Float(max(s2 / n - (s / n) * (s / n), 0).squareRoot())
            let lo = med - kappa * sigma, hi = med + kappa * sigma
            let clipped = current.filter { $0 >= lo && $0 <= hi }
            if clipped.count == current.count || clipped.count < 3 { break }
            current = clipped
        }
        return (med, mean, sigma)
    }

    /// Strided subsample of an image's pixels (optionally restricted by a mask ≥ 0.5).
    public static func sample(_ image: PlanarImage, stride: Int, mask: PlanarImage? = nil) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(image.pixels.count / max(stride * stride, 1) + 1)
        var y = 0
        while y < image.height {
            var x = 0
            while x < image.width {
                let i = y * image.width + x
                if mask == nil || mask!.pixels[i] >= 0.5 {
                    let v = image.pixels[i]
                    if v.isFinite { out.append(v) }
                }
                x += stride
            }
            y += stride
        }
        return out
    }

    /// Robust background level and noise (MAD·1.4826).
    public static func backgroundAndNoise(_ image: PlanarImage, mask: PlanarImage? = nil) -> (background: Float, noise: Float) {
        let stride = max(1, Int((Double(image.pixels.count) / 200_000).squareRoot()))
        var values = sample(image, stride: stride, mask: mask)
        if values.count < 16 { values = sample(image, stride: stride) }
        let med = median(values)
        let mad = median(values.map { abs($0 - med) })
        return (med, mad * 1.4826)
    }
}

// MARK: - Filters

/// Separable box blur with edge renormalisation (mean over the in-bounds window).
public func boxBlur(_ image: PlanarImage, radius: Int) -> PlanarImage {
    guard radius > 0 else { return image }
    let w = image.width, h = image.height
    var tmp = [Float](repeating: 0, count: w * h)
    var out = [Float](repeating: 0, count: w * h)
    var prefix = [Double](repeating: 0, count: max(w, h) + 1)
    image.pixels.withUnsafeBufferPointer { src in
        for y in 0..<h {
            let row = y * w
            for x in 0..<w { prefix[x + 1] = prefix[x] + Double(src[row + x]) }
            for x in 0..<w {
                let a = max(0, x - radius), b = min(w - 1, x + radius)
                tmp[row + x] = Float((prefix[b + 1] - prefix[a]) / Double(b - a + 1))
            }
        }
    }
    for x in 0..<w {
        for y in 0..<h { prefix[y + 1] = prefix[y] + Double(tmp[y * w + x]) }
        for y in 0..<h {
            let a = max(0, y - radius), b = min(h - 1, y + radius)
            out[y * w + x] = Float((prefix[b + 1] - prefix[a]) / Double(b - a + 1))
        }
    }
    return PlanarImage(width: w, height: h, pixels: out)
}

/// Separable [1 4 6 4 1]/16 smoothing (≈ Gaussian σ = 1 px) with clamped edges.
public func gaussianBlur5(_ image: PlanarImage) -> PlanarImage {
    let w = image.width, h = image.height
    let k: [Float] = [1 / 16, 4 / 16, 6 / 16, 4 / 16, 1 / 16]
    var tmp = [Float](repeating: 0, count: w * h)
    var out = [Float](repeating: 0, count: w * h)
    image.pixels.withUnsafeBufferPointer { src in
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                var s: Float = 0
                for j in -2...2 { s += k[j + 2] * src[row + min(max(x + j, 0), w - 1)] }
                tmp[row + x] = s
            }
        }
    }
    for y in 0..<h {
        for x in 0..<w {
            var s: Float = 0
            for j in -2...2 { s += k[j + 2] * tmp[min(max(y + j, 0), h - 1) * w + x] }
            out[y * w + x] = s
        }
    }
    return PlanarImage(width: w, height: h, pixels: out)
}

/// Noise reduction factor of `gaussianBlur5` for white noise: sqrt(Σk²)² over 2-D = 70/256.
public let gaussianBlur5NoiseFactor: Float = 70.0 / 256.0
