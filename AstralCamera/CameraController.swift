import AVFoundation
import AstralCore
import CoreVideo
import ImageIO
import QuartzCore
import SwiftUI

enum LensChoice: String, CaseIterable, Identifiable {
    case ultraWide
    case wide
    case telephoto

    var id: String { rawValue }

    /// Spoken name (VoiceOver); the picker shows the zoom factor like the Camera app.
    var name: LocalizedStringKey {
        switch self {
        case .ultraWide: "Ultra Wide"
        case .wide: "Wide"
        case .telephoto: "Telephoto"
        }
    }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: .builtInUltraWideCamera
        case .wide: .builtInWideAngleCamera
        case .telephoto: .builtInTelephotoCamera
        }
    }
}

struct LensOption: Identifiable, Equatable {
    var choice: LensChoice
    /// "0.5×", "1×", "4×" – the telephoto factor differs between iPhone models, so it is measured.
    var zoomLabel: String

    var id: String { choice.rawValue }

    /// Back cameras this iPhone actually has, in Camera-app order.
    static func available() -> [LensOption] {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: LensChoice.allCases.map(\.deviceType), mediaType: .video, position: .back).devices
        func device(_ c: LensChoice) -> AVCaptureDevice? { devices.first { $0.deviceType == c.deviceType } }
        let wideFOV = device(.wide).map { Double($0.activeFormat.videoFieldOfView) } ?? 0
        return LensChoice.allCases.compactMap { choice in
            guard let d = device(choice) else { return nil }
            let factor = choice == .wide || wideFOV == 0 ? 1
                : LensZoom.factor(referenceFOVDegrees: wideFOV, lensFOVDegrees: Double(d.activeFormat.videoFieldOfView))
            return LensOption(choice: choice, zoomLabel: LensZoom.label(factor))
        }
    }
}

struct CameraCapabilities {
    var minISO: Float
    var maxISO: Float
    var exposure: Double
    var fieldOfView: Double
    var photoDimensions: CMVideoDimensions
    var calibrationSupported: Bool
    /// True when Bayer RAW was unavailable and Apple ProRAW (decoded via CIRAWFilter) is used instead.
    var usesProRAW: Bool
    var rawDescription: String
}

/// Intrinsics and distortion as delivered by `AVCameraCalibrationData` (reference dimensions).
struct CalibrationInfo {
    var intrinsics: CameraIntrinsics
    var distortion: LensDistortion?

    init(_ data: AVCameraCalibrationData) {
        let m = data.intrinsicMatrix   // column-major
        let ref = data.intrinsicMatrixReferenceDimensions
        intrinsics = CameraIntrinsics(fx: Double(m.columns.0.x), fy: Double(m.columns.1.y),
                                      cx: Double(m.columns.2.x), cy: Double(m.columns.2.y),
                                      width: Int(ref.width), height: Int(ref.height))
        func floats(_ d: Data?) -> [Float] {
            guard let d else { return [] }
            return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let forward = floats(data.lensDistortionLookupTable)
        let inverse = floats(data.inverseLensDistortionLookupTable)
        if forward.count > 1, inverse.count > 1 {
            distortion = LensDistortion(forward: forward, inverse: inverse,
                                        center: SIMD2(Double(data.lensDistortionCenter.x), Double(data.lensDistortionCenter.y)),
                                        width: Int(ref.width), height: Int(ref.height))
        }
    }
}

/// One RAW sub-exposure. `dng` is attached when the processor asked for metadata (or needs the fallback decoder).
struct CapturedFrame: @unchecked Sendable {
    var raw: RawImage?
    var dng: Data?
    var timestamp: Double
    var exposure: Double
    var iso: Float
    var calibration: CalibrationInfo?
    var fieldOfView: Double
    /// What the sensor actually used (EXIF of the RAW) – iOS may override manual settings.
    var exifISO: Float?
    var exifExposure: Double?
    /// Exposure the app asked for; frames far below it were taken after iOS reset the camera to auto.
    var targetExposure: Double

    var exposureMismatch: Bool {
        guard let actual = exifExposure else { return false }
        return actual < 0.8 * targetExposure
    }
}

struct CaptureErrorInfo {
    var domain: String
    var code: Int
    var text: String

    var summary: String { "\(text) [\(domain) \(code)]" }
}

enum CameraError: LocalizedError {
    case noCamera
    case noRawSupport(String)
    case configuration(String)

    var errorDescription: String? {
        switch self {
        case .noCamera: String(localized: "No rear camera found (the Simulator has no camera – run on an iPhone).")
        case .noRawSupport(let details): String(localized: "This lens does not offer RAW capture. \(details)")
        case .configuration(let m): m
        }
    }
}

/// Manual RAW capture loop: longest exposure the format allows, fixed ISO and focus, no fusion
/// (`.speed`), no geometric distortion correction (required for calibration data and the K·R·K⁻¹ model).
final class CameraController: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "astral.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var rawFormat: OSType = 0
    private var looping = false
    private var inFlight = false
    private var fieldOfView = 70.0
    private var targetISO: Float = 1600
    private var targetFocus: Float = 0.8
    private var targetExposure: Double = 1
    private var consecutiveErrors = 0
    private var lastHeal: CFTimeInterval = 0
    private var observersInstalled = false

    /// Called on the session queue for every RAW frame.
    var onFrame: ((CapturedFrame) -> Void)?
    var onError: ((CaptureErrorInfo) -> Void)?
    private let stateLock = NSLock()
    private var lastReconfigure: CFTimeInterval = 0
    /// Set by the processor when it needs DNG data with the next frame(s).
    var wantsDNG: () -> Bool = { false }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func configure(lens: LensChoice, iso: Float, focus: Float) async throws -> CameraCapabilities {
        try await withCheckedThrowingContinuation { cont in
            sessionQueue.async {
                do { cont.resume(returning: try self.configureOnQueue(lens: lens, iso: iso, focus: focus)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func configureOnQueue(lens: LensChoice, iso: Float, focus: Float) throws -> CameraCapabilities {
        let wasLooping = looping
        looping = false
        targetISO = iso
        targetFocus = focus
        installObservers()
        markReconfigure()
        defer { markReconfigure() }
        guard let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) else {
            throw CameraError.noCamera
        }
        // RAW is only offered with the .photo preset: setting `activeFormat` directly – even to the very
        // format the preset would choose – empties `availableRawPhotoPixelFormatTypes` (Apple DTS, forum 68589).
        session.beginConfiguration()
        session.sessionPreset = .photo
        for input in session.inputs { session.removeInput(input) }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw error
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.configuration(String(localized: "Cannot add the camera input."))
        }
        session.addInput(input)
        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else {
                session.commitConfiguration()
                throw CameraError.configuration(String(localized: "Cannot add the photo output."))
            }
            session.addOutput(photoOutput)
        }
        session.commitConfiguration()

        // The RAW format list reflects the committed configuration only.
        if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = false }
        var usesProRAW = false
        var raw = photoOutput.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
            ?? photoOutput.availableRawPhotoPixelFormatTypes.first { !AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        if raw == nil, photoOutput.isAppleProRAWSupported {
            // Fallback: ProRAW is demosaiced and may be multi-frame, but it is linear and goes through
            // the DNG → CIRAWFilter path of the processor.
            photoOutput.isAppleProRAWEnabled = true
            raw = photoOutput.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
            usesProRAW = raw != nil
        }
        guard let raw else {
            let available = photoOutput.availableRawPhotoPixelFormatTypes.map(Self.fourCC).joined(separator: ", ")
            throw CameraError.noRawSupport("RAW formats: [\(available)], preset: \(session.sessionPreset.rawValue), ProRAW: \(photoOutput.isAppleProRAWSupported ? "yes" : "no").")
        }

        // Manual exposure, focus and geometry only after the preset has chosen the active format.
        let format = device.activeFormat
        self.device = device
        try applyDeviceSettingsOnQueue()

        // Third-party Bayer RAW runs on the 12 MP pipeline anyway; 48 MP would also force fusion.
        let dims = format.supportedMaxPhotoDimensions.filter { Int($0.width) * Int($0.height) <= 12_600_000 }
            .max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
            ?? format.supportedMaxPhotoDimensions.first ?? photoOutput.maxPhotoDimensions
        photoOutput.maxPhotoDimensions = dims
        photoOutput.maxPhotoQualityPrioritization = .speed

        rawFormat = raw
        self.device = device
        // Allocate RAW buffers up front instead of lazily on every capture (shorter gaps between frames).
        photoOutput.setPreparedPhotoSettingsArray([makeSettings()], completionHandler: nil)
        fieldOfView = Double(format.videoFieldOfView)
        if !session.isRunning { session.startRunning() }
        looping = wasLooping
        if looping && !inFlight { captureNext() }
        return CameraCapabilities(minISO: format.minISO, maxISO: format.maxISO,
                                  exposure: format.maxExposureDuration.seconds, fieldOfView: fieldOfView,
                                  photoDimensions: dims,
                                  calibrationSupported: photoOutput.isCameraCalibrationDataDeliverySupported,
                                  usesProRAW: usesProRAW,
                                  rawDescription: "\(usesProRAW ? "ProRAW" : "Bayer RAW") \(Self.fourCC(raw)), \(dims.width)×\(dims.height), max \(String(format: "%.2f", format.maxExposureDuration.seconds)) s")
    }

    static func exifISO(_ metadata: [String: Any]) -> Float? {
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        return (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.floatValue
    }

    static func exifExposure(_ metadata: [String: Any]) -> Double? {
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        return (exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
    }

    static func fourCC(_ code: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(decoding: bytes, as: UTF8.self) }
        return String(code)
    }

    /// Exposure/ISO/focus changes take a few frames to settle – never change them mid-stack.
    func apply(iso: Float, focus: Float) {
        sessionQueue.async {
            self.targetISO = iso
            self.targetFocus = focus
            try? self.applyDeviceSettingsOnQueue()
        }
    }

    /// The single place that puts the device into the app's manual state. iOS drops it back to auto
    /// exposure after an interruption (e.g. the built-in Camera app took the camera) – third night in
    /// the field: every frame came back at 1/15 s – so this runs again whenever that can have happened.
    private func applyDeviceSettingsOnQueue() throws {
        guard let device else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let format = device.activeFormat
        if device.isGeometricDistortionCorrectionSupported { device.isGeometricDistortionCorrectionEnabled = false }
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = false }
        targetExposure = format.maxExposureDuration.seconds
        device.setExposureModeCustom(duration: format.maxExposureDuration,
                                     iso: min(max(targetISO, format.minISO), format.maxISO), completionHandler: nil)
        if device.isLockingFocusWithCustomLensPositionSupported {
            device.setFocusModeLocked(lensPosition: min(max(targetFocus, 0), 1), completionHandler: nil)
        }
    }

    /// Re-applies manual settings at most every 2 s (several frames may report the stale state).
    private func healSettings() {
        sessionQueue.async {
            let now = CACurrentMediaTime()
            guard now - self.lastHeal > 2 else { return }
            self.lastHeal = now
            try? self.applyDeviceSettingsOnQueue()
        }
    }

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                self.markReconfigure()
                try? self.applyDeviceSettingsOnQueue()
                if self.looping && !self.inFlight { self.captureNext() }
            }
        }
        center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.markReconfigure()
        }
        center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            self.markReconfigure()
            let code = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code
            self.sessionQueue.async {
                // Media services were reset or the session died: restart and restore the manual state.
                if code == AVError.Code.mediaServicesWereReset.rawValue || !self.session.isRunning {
                    self.session.startRunning()
                }
                try? self.applyDeviceSettingsOnQueue()
                self.inFlight = false
                if self.looping { self.captureNext() }
            }
        }
    }

    func startLoop() {
        sessionQueue.async {
            self.looping = true
            if !self.inFlight { self.captureNext() }
        }
    }

    func stopLoop() {
        sessionQueue.async { self.looping = false }
    }

    func stopSession() {
        sessionQueue.async {
            self.looping = false
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func makeSettings() -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        settings.photoQualityPrioritization = .speed
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.flashMode = .off
        // One shutter click per second for an hour is unbearable; allowed where the law permits (iOS 18+).
        if photoOutput.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = true
        }
        if photoOutput.isCameraCalibrationDataDeliverySupported {
            settings.isCameraCalibrationDataDeliveryEnabled = true
        }
        return settings
    }

    private func captureNext() {
        guard looping, session.isRunning, rawFormat != 0 else { return }
        let settings = makeSettings()
        inFlight = true
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    private func markReconfigure() {
        stateLock.lock(); lastReconfigure = CACurrentMediaTime(); stateLock.unlock()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            // A capture in flight while the session is reconfigured (lens switch) fails by design.
            stateLock.lock()
            let duringReconfigure = CACurrentMediaTime() - lastReconfigure < 3
            stateLock.unlock()
            stateLock.lock(); consecutiveErrors += 1; stateLock.unlock()
            guard !duringReconfigure else { return }
            let ns = error as NSError
            let reason = ns.localizedFailureReason.map { " – \($0)" } ?? ""
            onError?(CaptureErrorInfo(domain: ns.domain, code: ns.code, text: ns.localizedDescription + reason))
            return
        }
        guard photo.isRawPhoto else { return }
        stateLock.lock(); consecutiveErrors = 0; stateLock.unlock()
        let frame = CapturedFrame(raw: photo.pixelBuffer.flatMap(RawImage.init(copying:)),
                                  dng: wantsDNG() ? photo.fileDataRepresentation() : nil,
                                  timestamp: photo.timestamp.seconds,
                                  exposure: device?.exposureDuration.seconds ?? 1,
                                  iso: device?.iso ?? 0,
                                  calibration: photo.cameraCalibrationData.map(CalibrationInfo.init),
                                  fieldOfView: fieldOfView,
                                  exifISO: Self.exifISO(photo.metadata),
                                  exifExposure: Self.exifExposure(photo.metadata),
                                  targetExposure: targetExposure)
        if frame.exposureMismatch { healSettings() }
        onFrame?(frame)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        stateLock.lock(); let errors = consecutiveErrors; stateLock.unlock()
        // Back off after failures instead of hammering a broken pipeline (50 errors in one second seen).
        let delay = errors == 0 ? 0 : min(0.25 * pow(2, Double(min(errors, 4) - 1)), 2)
        sessionQueue.asyncAfter(deadline: .now() + delay) {
            self.inFlight = false
            if errors > 0 { try? self.applyDeviceSettingsOnQueue() }
            self.captureNext()
        }
    }
}
