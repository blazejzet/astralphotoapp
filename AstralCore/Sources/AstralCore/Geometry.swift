import Foundation
import simd

// MARK: - Sidereal motion

public enum Sidereal {
    /// Mean angular velocity of the Earth relative to the stars (IERS conventional value), rad/s.
    /// Equivalent to 15.041″/s; 1/ω ≈ 13 713 s is the constant in the NPF rule.
    public static let angularRate: Double = 7.2921150e-5

    /// Direction of the Earth's rotation axis (towards the north celestial pole) expressed in
    /// CoreMotion's `xTrueNorthZVertical` frame: x → true north, y → west, z → up.
    /// For the southern hemisphere (φ < 0) the vector points below the northern horizon, which is
    /// still the correct rotation axis.
    public static func poleInNorthWestUp(latitudeDegrees: Double) -> SIMD3<Double> {
        let phi = latitudeDegrees * .pi / 180
        return SIMD3(cos(phi), 0, sin(phi))
    }

    /// Star trail length in pixels during an exposure (small-angle approximation at the image centre).
    public static func trailLength(exposure: Double, declinationDegrees: Double, focalPixels: Double) -> Double {
        angularRate * exposure * cos(declinationDegrees * .pi / 180) * focalPixels
    }

    /// NPF rule (Michaud, Société d'Astronomie du Havre), simplified form: t = k·(35N + 30p)/f,
    /// N – f-number, p – pixel pitch [µm], f – physical focal length [mm].
    public static func npfMaxExposure(fNumber: Double, pixelPitchMicrons: Double, focalLengthMM: Double,
                                      declinationDegrees: Double = 0, k: Double = 1) -> Double {
        k * (35 * fNumber + 30 * pixelPitchMicrons) / (focalLengthMM * cos(declinationDegrees * .pi / 180))
    }
}

/// Rodrigues rotation matrix; a positive angle is a right-handed rotation about `axis`.
public func rotationMatrix(axis: SIMD3<Double>, angle: Double) -> simd_double3x3 {
    let k = simd_normalize(axis)
    let c = cos(angle), s = sin(angle), t = 1 - c
    return simd_double3x3(rows: [
        SIMD3(t * k.x * k.x + c, t * k.x * k.y - s * k.z, t * k.x * k.z + s * k.y),
        SIMD3(t * k.x * k.y + s * k.z, t * k.y * k.y + c, t * k.y * k.z - s * k.x),
        SIMD3(t * k.x * k.z - s * k.y, t * k.y * k.z + s * k.x, t * k.z * k.z + c),
    ])
}

// MARK: - Homography

public struct Homography: Sendable, Equatable {
    public var matrix: simd_double3x3

    public init(_ matrix: simd_double3x3) { self.matrix = matrix }

    public static let identity = Homography(matrix_identity_double3x3)

    public static func translation(_ t: SIMD2<Double>) -> Homography {
        Homography(simd_double3x3(rows: [SIMD3(1, 0, t.x), SIMD3(0, 1, t.y), SIMD3(0, 0, 1)]))
    }

    /// Maps a point; returns nil when it lands behind the camera (w ≤ 0).
    @inlinable
    public func apply(_ p: SIMD2<Double>) -> SIMD2<Double>? {
        let h = matrix * SIMD3(p.x, p.y, 1)
        guard h.z > 1e-12 else { return nil }
        return SIMD2(h.x / h.z, h.y / h.z)
    }

    public var inverse: Homography { Homography(matrix.inverse) }

    /// `a * b` applies `b` first, then `a`.
    public static func * (a: Homography, b: Homography) -> Homography { Homography(a.matrix * b.matrix) }

    public var floatMatrix: simd_float3x3 {
        simd_float3x3(columns: (SIMD3<Float>(matrix.columns.0), SIMD3<Float>(matrix.columns.1), SIMD3<Float>(matrix.columns.2)))
    }
}

// MARK: - Camera intrinsics

/// Pinhole intrinsics in pixels; pixel centres lie on integer coordinates, origin top-left.
public struct CameraIntrinsics: Sendable, Equatable {
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    public var width: Int
    public var height: Int

    public init(fx: Double, fy: Double, cx: Double, cy: Double, width: Int, height: Int) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.width = width; self.height = height
    }

    /// Fallback when calibration data is unavailable: f = (W/2)/tan(HFOV/2).
    public init(horizontalFieldOfViewDegrees hfov: Double, width: Int, height: Int) {
        let f = (Double(width) / 2) / tan(hfov * .pi / 360)
        self.init(fx: f, fy: f, cx: Double(width - 1) / 2, cy: Double(height - 1) / 2, width: width, height: height)
    }

    public var matrix: simd_double3x3 {
        simd_double3x3(rows: [SIMD3(fx, 0, cx), SIMD3(0, fy, cy), SIMD3(0, 0, 1)])
    }

    public var inverseMatrix: simd_double3x3 {
        simd_double3x3(rows: [SIMD3(1 / fx, 0, -cx / fx), SIMD3(0, 1 / fy, -cy / fy), SIMD3(0, 0, 1)])
    }

    /// Rescales to another buffer size (e.g. 2×2 Bayer binning) keeping pixel-centre conventions.
    public func scaled(toWidth newWidth: Int, height newHeight: Int) -> CameraIntrinsics {
        let sx = Double(newWidth) / Double(width), sy = Double(newHeight) / Double(height)
        return CameraIntrinsics(fx: fx * sx, fy: fy * sy,
                                cx: (cx + 0.5) * sx - 0.5, cy: (cy + 0.5) * sy - 0.5,
                                width: newWidth, height: newHeight)
    }

    public func withFocalScale(_ s: Double) -> CameraIntrinsics {
        CameraIntrinsics(fx: fx * s, fy: fy * s, cx: cx, cy: cy, width: width, height: height)
    }

    public func ray(through p: SIMD2<Double>) -> SIMD3<Double> {
        simd_normalize(SIMD3((p.x - cx) / fx, (p.y - cy) / fy, 1))
    }

    public func project(_ d: SIMD3<Double>) -> SIMD2<Double>? {
        guard d.z > 1e-12 else { return nil }
        return SIMD2(fx * d.x / d.z + cx, fy * d.y / d.z + cy)
    }
}

// MARK: - Sky rotation model  H(Δt) = K · R_p(−ωΔt) · K⁻¹

public struct SkyRotationModel: Sendable {
    /// Unit vector of the rotation axis in the camera frame (x right, y down, z forward).
    public var pole: SIMD3<Double>
    public var intrinsics: CameraIntrinsics
    public var angularRate: Double

    public init(pole: SIMD3<Double>, intrinsics: CameraIntrinsics, angularRate: Double = Sidereal.angularRate) {
        self.pole = simd_normalize(pole)
        self.intrinsics = intrinsics
        self.angularRate = angularRate
    }

    /// Camera-frame rotation of star directions after `dt` seconds.
    public func rotation(dt: Double) -> simd_double3x3 {
        rotationMatrix(axis: pole, angle: -angularRate * dt)
    }

    /// Maps reference-epoch (undistorted) pixels to their position `dt` seconds later.
    public func homography(dt: Double) -> Homography {
        Homography(intrinsics.matrix * rotation(dt: dt) * intrinsics.inverseMatrix)
    }

    /// Image of the celestial pole (fixed point of every H). May lie outside the frame.
    public var poleImage: SIMD2<Double>? { intrinsics.project(pole) ?? intrinsics.project(-pole) }
}

// MARK: - Device attitude → camera frame

public enum DeviceAxes {
    /// UIKit device frame (portrait: x right, y up, z out of the screen) → back-camera frame of the
    /// sensor-native landscape buffer (x right, y down, z forward along the optical axis).
    /// Derived from ARKit's camera-axis description; to be confirmed on device (the pole fit absorbs errors).
    public static let backCameraFromDevice = simd_double3x3(rows: [
        SIMD3(0, -1, 0),
        SIMD3(-1, 0, 0),
        SIMD3(0, 0, -1),
    ])

    /// Apple does not document whether `CMAttitude.rotationMatrix` maps reference→device or the reverse.
    /// The gravity vector (reference: (0,0,−1)) disambiguates. `attitudeRows` holds m11…m33 by rows.
    public static func referenceToDevice(attitudeRows m: simd_double3x3, gravityInDevice g: SIMD3<Double>) -> simd_double3x3 {
        let down = SIMD3<Double>(0, 0, -1)
        let gn = simd_length(g) > 0 ? simd_normalize(g) : down
        let asIs = simd_dot(m * down, gn)
        let transposed = simd_dot(m.transpose * down, gn)
        return asIs >= transposed ? m : m.transpose
    }

    /// Prior for the rotation axis in the camera frame: p_cam = C · A · p_ref.
    public static func poleInCamera(latitudeDegrees: Double, attitudeRows: simd_double3x3,
                                    gravityInDevice: SIMD3<Double>) -> SIMD3<Double> {
        let a = referenceToDevice(attitudeRows: attitudeRows, gravityInDevice: gravityInDevice)
        let p = backCameraFromDevice * a * Sidereal.poleInNorthWestUp(latitudeDegrees: latitudeDegrees)
        return simd_normalize(p)
    }

    /// EXIF orientation (1, 3, 6, 8) that displays the sensor-native buffer upright, from gravity.
    public static func exifOrientation(gravityInDevice g: SIMD3<Double>) -> UInt32 {
        let gc = backCameraFromDevice * g
        if abs(gc.x) > abs(gc.y) { return gc.x > 0 ? 6 : 8 }
        return gc.y >= 0 ? 1 : 3
    }
}

// MARK: - Small dense linear algebra

/// Gaussian elimination with partial pivoting. Returns nil for singular systems.
public func solveLinearSystem(_ a: [[Double]], _ b: [Double]) -> [Double]? {
    let n = b.count
    var m = a
    var v = b
    for col in 0..<n {
        var pivot = col
        for row in (col + 1)..<max(n, col + 1) where abs(m[row][col]) > abs(m[pivot][col]) { pivot = row }
        guard abs(m[pivot][col]) > 1e-300 else { return nil }
        if pivot != col { m.swapAt(pivot, col); v.swapAt(pivot, col) }
        for row in (col + 1)..<max(n, col + 1) {
            let f = m[row][col] / m[col][col]
            if f == 0 { continue }
            for k in col..<n { m[row][k] -= f * m[col][k] }
            v[row] -= f * v[col]
        }
    }
    var x = [Double](repeating: 0, count: n)
    for row in stride(from: n - 1, through: 0, by: -1) {
        var s = v[row]
        for k in (row + 1)..<max(n, row + 1) { s -= m[row][k] * x[k] }
        x[row] = s / m[row][row]
    }
    return x
}

// MARK: - Lens zoom factors

public enum LensZoom {
    /// Magnification of a lens relative to the reference (wide, "1×") from horizontal fields of view.
    public static func factor(referenceFOVDegrees: Double, lensFOVDegrees: Double) -> Double {
        let ref = tan(referenceFOVDegrees * .pi / 360), lens = tan(lensFOVDegrees * .pi / 360)
        guard ref > 0, lens > 0 else { return 1 }
        return ref / lens
    }

    /// Camera-app style label: 0.5×, 1×, 2×, 3×, 4×, 5× – nearest half step, decimal only when needed.
    public static func label(_ factor: Double) -> String {
        let rounded = factor < 1 ? (factor * 10).rounded() / 10 : (factor * 2).rounded() / 2
        let text = rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
        return text + "×"
    }
}
