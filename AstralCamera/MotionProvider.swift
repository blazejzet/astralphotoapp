import CoreLocation
import CoreMotion
import Foundation
import simd

struct MotionSnapshot {
    var attitudeRows: simd_double3x3
    var gravity: SIMD3<Double>
    var trueNorth: Bool
}

/// Device attitude (CoreMotion, true-north frame when available), latitude and tripod stillness.
/// The attitude only seeds the rotation-axis estimate; the stars decide (compass errors are degrees).
@MainActor
final class MotionProvider: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var latitude: Double?
    @Published private(set) var isStill = false
    @Published private(set) var headingAccuracy: Double?

    private let motion = CMMotionManager()
    private let location = CLLocationManager()
    private var lastMotion: CMDeviceMotion?
    private var usingTrueNorth = false
    private var quietSince: Date?

    func start() {
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyKilometer
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { location.startUpdatingHeading() }

        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.1
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame = frames.contains(.xTrueNorthZVertical) ? .xTrueNorthZVertical : .xArbitraryCorrectedZVertical
        usingTrueNorth = frame == .xTrueNorthZVertical
        motion.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            MainActor.assumeIsolated { self.handle(data) }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        location.stopUpdatingLocation()
        location.stopUpdatingHeading()
    }

    private func handle(_ data: CMDeviceMotion) {
        lastMotion = data
        let r = data.rotationRate
        let rate = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
        if rate < 0.01 {
            if quietSince == nil { quietSince = Date() }
        } else {
            quietSince = nil
        }
        let still = quietSince.map { Date().timeIntervalSince($0) > 2 } ?? false
        if still != isStill { isStill = still }
    }

    /// Snapshot for the pole prior. Without true north the heading is arbitrary → no prior.
    func snapshot() -> MotionSnapshot? {
        guard let m = lastMotion, usingTrueNorth else { return nil }
        let r = m.attitude.rotationMatrix
        return MotionSnapshot(attitudeRows: simd_double3x3(rows: [SIMD3(r.m11, r.m12, r.m13),
                                                                   SIMD3(r.m21, r.m22, r.m23),
                                                                   SIMD3(r.m31, r.m32, r.m33)]),
                              gravity: SIMD3(m.gravity.x, m.gravity.y, m.gravity.z),
                              trueNorth: usingTrueNorth)
    }

    var gravity: SIMD3<Double>? {
        lastMotion.map { SIMD3($0.gravity.x, $0.gravity.y, $0.gravity.z) }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        latitude = loc.coordinate.latitude
        manager.stopUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        headingAccuracy = newHeading.headingAccuracy
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
