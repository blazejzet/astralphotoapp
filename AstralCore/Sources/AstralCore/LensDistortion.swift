import Foundation

/// Radial lens distortion in Apple's `AVCameraCalibrationData` representation: a 1-D table of
/// magnifications sampled from `center` (r = 0) to the farthest corner (r = r_max).
/// `forward` maps undistorted → distorted points (`lensDistortionLookupTable`),
/// `inverse` maps distorted → undistorted (`inverseLensDistortionLookupTable`).
public struct LensDistortion: Sendable, Equatable {
    public var forward: [Float]
    public var inverse: [Float]
    public var center: SIMD2<Double>
    public var width: Int
    public var height: Int

    public init(forward: [Float], inverse: [Float], center: SIMD2<Double>, width: Int, height: Int) {
        self.forward = forward
        self.inverse = inverse
        self.center = center
        self.width = width
        self.height = height
    }

    public var maxRadius: Double {
        let dx = max(center.x, Double(width) - center.x)
        let dy = max(center.y, Double(height) - center.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Reference algorithm from the AVCameraCalibrationData header.
    @inlinable
    static func map(_ p: SIMD2<Double>, table: [Float], center: SIMD2<Double>, maxRadius: Double) -> SIMD2<Double> {
        guard table.count > 1 else { return p }
        let v = p - center
        let r = (v.x * v.x + v.y * v.y).squareRoot()
        let position = r * Double(table.count - 1) / maxRadius
        let index = Int(position)
        let magnification: Double
        if index >= table.count - 1 {
            magnification = Double(table[table.count - 1])
        } else {
            let frac = position - Double(index)
            magnification = Double(table[index]) * (1 - frac) + Double(table[index + 1]) * frac
        }
        return center + v * (1 + magnification)
    }

    public func distort(_ p: SIMD2<Double>) -> SIMD2<Double> {
        Self.map(p, table: forward, center: center, maxRadius: maxRadius)
    }

    public func undistort(_ p: SIMD2<Double>) -> SIMD2<Double> {
        Self.map(p, table: inverse, center: center, maxRadius: maxRadius)
    }

    /// Same pixel-centre convention as `CameraIntrinsics.scaled`. Tables are radius-normalised, so they carry over.
    public func scaled(toWidth newWidth: Int, height newHeight: Int) -> LensDistortion {
        let sx = Double(newWidth) / Double(width), sy = Double(newHeight) / Double(height)
        return LensDistortion(forward: forward, inverse: inverse,
                              center: SIMD2((center.x + 0.5) * sx - 0.5, (center.y + 0.5) * sy - 0.5),
                              width: newWidth, height: newHeight)
    }
}

/// Output pixel (reference epoch, raw/distorted grid) → source pixel in frame k:
/// u_k = D( H_k · D⁻¹(u) ). The Metal kernel implements the same mapping.
public struct WarpMapper: Sendable {
    public var homography: Homography
    public var distortion: LensDistortion?

    public init(homography: Homography, distortion: LensDistortion?) {
        self.homography = homography
        self.distortion = distortion
    }

    @inlinable
    public func sourcePosition(forOutput u: SIMD2<Double>) -> SIMD2<Double>? {
        let uu = distortion?.undistort(u) ?? u
        guard let v = homography.apply(uu) else { return nil }
        return distortion?.distort(v) ?? v
    }
}
