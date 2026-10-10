import AstralCore
import CoreGraphics
import Foundation
import SwiftUI
import UIKit
import simd

struct SessionResult {
    var image: CGImage?
    var orientation: Image.Orientation
    var export: ExportedSession?
    var notes: [String]
}

@MainActor
final class SessionModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        case framing
        case darks
        case focusing
        case stacking
        case finishing
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var preview: CGImage?
    @Published private(set) var stats = LiveStats()
    @Published var message: String?
    @Published private(set) var capabilities: CameraCapabilities?
    @Published private(set) var thermal = ProcessInfo.processInfo.thermalState
    @Published private(set) var result: SessionResult?
    @Published private(set) var stackStart: Date?
    @Published private(set) var focusProgress: Double = 0
    @Published private(set) var lenses: [LensOption] = []
    @Published var zoom = false {
        didSet { processor?.setZoom(zoom) }
    }
    @Published var lens: LensChoice {
        didSet {
            defaults.set(lens.rawValue, forKey: "lens")
            focus = Self.storedFocus(for: lens, defaults: defaults)
            Task { await reconfigure() }
        }
    }
    @Published var iso: Float {
        didSet { defaults.set(iso, forKey: "iso") }
    }
    /// Remembered per lens – infinity differs between lenses and iPhone models.
    /// Also saves both raw stacks (≈ 100 MB) so the processing can be tuned on real data.
    @Published var saveDiagnostics: Bool {
        didSet { defaults.set(saveDiagnostics, forKey: "saveDiagnostics") }
    }
    @Published var focus: Float {
        didSet { defaults.set(focus, forKey: "focus.\(lens.rawValue)") }
    }

    let motion = MotionProvider()
    private let camera = CameraController()
    private var processor: FrameProcessor?
    private var orientation: UInt32 = 6
    private var focusSweep: FocusSweep?
    private var priorPole: SIMD3<Double>?
    private var startGravity: SIMD3<Double>?
    private var captureErrors: [String] = []
    private var lastErrorSummary: String?
    private var repeatedErrors = 0
    private var warnedISO: Float?
    private var focusBeforeSweep: Float = 0.8
    private var thermalObserver: NSObjectProtocol?
    private let defaults = UserDefaults.standard
    static let darkFrameCount = 16

    init() {
        lens = LensChoice(rawValue: defaults.string(forKey: "lens") ?? "") ?? .wide
        iso = defaults.object(forKey: "iso") as? Float ?? 1600
        saveDiagnostics = defaults.object(forKey: "saveDiagnostics") as? Bool ?? true
        let initialLens = LensChoice(rawValue: defaults.string(forKey: "lens") ?? "") ?? .wide
        focus = Self.storedFocus(for: initialLens, defaults: defaults)
    }

    /// lensPosition 1.0 is not infinity; ≈ 0.8 was measured on older iPhones – use Auto-focus to measure.
    private static func storedFocus(for lens: LensChoice, defaults: UserDefaults) -> Float {
        defaults.object(forKey: "focus.\(lens.rawValue)") as? Float ?? defaults.object(forKey: "focus") as? Float ?? 0.8
    }

    /// Gravity direction in the sensor buffer for the sky mask (from the locked EXIF orientation).
    private var groundDirection: ImageDirection? { ImageDirection(exifOrientation: orientation) }


    func start() async {
        guard phase == .starting else { return }
        motion.start()
        guard await CameraController.requestAccess() else {
            phase = .failed(String(localized: "No camera access. Turn it on in Settings."))
            return
        }
        do {
            let processor = try FrameProcessor()
            self.processor = processor
            processor.onUpdate = { [weak self] update in
                Task { @MainActor in self?.apply(update) }
            }
            camera.onFrame = { frame in processor.submit(frame) }
            camera.wantsDNG = { processor.needsDNG }
            camera.onError = { [weak self] info in
                Task { @MainActor in
                    guard let self else { return }
                    // Collapse bursts of the same error into one line with a count.
                    if info.summary == self.lastErrorSummary, !self.captureErrors.isEmpty {
                        self.repeatedErrors += 1
                        self.captureErrors[self.captureErrors.count - 1] = self.captureErrors[self.captureErrors.count - 1]
                            .components(separatedBy: " ×").first! + " ×\(self.repeatedErrors + 1)"
                    } else if self.captureErrors.count < 50 {
                        self.lastErrorSummary = info.summary
                        self.repeatedErrors = 0
                        self.captureErrors.append("\(Date().formatted(date: .omitted, time: .standard)) \(info.summary)")
                    }
                    self.message = String(localized: "Capture error: \(info.summary)")
                }
            }
        } catch {
            phase = .failed(String(localized: "Metal is not available on this device."))
            return
        }
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.thermalChanged() }
        }
        lenses = LensOption.available()
        if !lenses.isEmpty, !lenses.contains(where: { $0.choice == lens }) {
            lens = .wide   // e.g. telephoto remembered from another iPhone
        }
        await reconfigure()
        camera.startLoop()
        if case .failed = phase { return }
        phase = .framing
    }

    func reconfigure() async {
        do {
            capabilities = try await camera.configure(lens: lens, iso: iso, focus: focus)
            if let caps = capabilities {
                iso = min(max(iso, caps.minISO), caps.maxISO)
                message = caps.usesProRAW
                    ? String(localized: "Bayer RAW unavailable – using ProRAW (\(caps.rawDescription)). Frames decode more slowly.")
                    : caps.rawDescription
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func applyExposureSettings() {
        camera.apply(iso: iso, focus: focus)
    }

    /// On-screen shutter, volume buttons and Camera Control: start the stack, or finish it (like video).
    func shutter() {
        switch phase {
        case .framing: startStacking()
        case .stacking: finish()
        default: break
        }
    }

    func startDarks() {
        guard phase == .framing else { return }
        phase = .darks
        processor?.startDarks(count: Self.darkFrameCount)
    }

    // MARK: - Autofocus on stars

    func startAutofocus() {
        guard phase == .framing else { return }
        var sweep = FocusSweep()
        focusBeforeSweep = focus
        zoom = false
        phase = .focusing
        message = String(localized: "Autofocus: point the camera at the stars and keep the tripod still (about 1.5 min).")
        handle(sweep.start())
        focusSweep = sweep
        focusProgress = 0
    }

    func cancelAutofocus() {
        guard phase == .focusing else { return }
        focusSweep = nil
        focus = focusBeforeSweep
        applyExposureSettings()
        phase = .framing
        message = String(localized: "Autofocus cancelled.")
    }

    private func advanceFocusSweep(score: Double) {
        guard var sweep = focusSweep else { return }
        let step = sweep.frame(score: score)
        focusSweep = sweep
        focusProgress = sweep.progress
        handle(step)
    }

    private func handle(_ step: FocusSweep.Step) {
        switch step {
        case .move(let position):
            focus = position
            applyExposureSettings()
        case .wait:
            break
        case .finished(let position):
            focus = position
            applyExposureSettings()
            focusSweep = nil
            phase = .framing
            message = String(localized: "Focus set on the stars: \(String(format: "%.3f", position)) (saved for this lens).")
        case .failed:
            focusSweep = nil
            focus = focusBeforeSweep
            applyExposureSettings()
            phase = .framing
            message = String(localized: "Autofocus found no stars. Check ISO, clouds and that the camera faces the sky.")
        }
    }

    func clearDarks() {
        processor?.clearDarks()
    }

    func startStacking() {
        guard phase == .framing else { return }
        if let g = motion.gravity { orientation = DeviceAxes.exifOrientation(gravityInDevice: g) }
        var prior: SIMD3<Double>?
        if let snapshot = motion.snapshot(), let latitude = motion.latitude {
            prior = DeviceAxes.poleInCamera(latitudeDegrees: latitude, attitudeRows: snapshot.attitudeRows,
                                            gravityInDevice: snapshot.gravity)
        }
        priorPole = prior
        startGravity = motion.gravity
        captureErrors = []
        lastErrorSummary = nil
        // Gravity + latitude fix the pole's altitude whatever the compass says (it reported ±89°).
        var elevation: PoleElevationConstraint?
        if let g = motion.gravity, let latitude = motion.latitude, simd_length(g) > 0.5 {
            elevation = PoleElevationConstraint(up: DeviceAxes.backCameraFromDevice * (-g), latitudeDegrees: latitude)
        }
        processor?.startStacking(priorPole: prior, groundDirection: groundDirection, poleElevation: elevation)
        stackStart = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        phase = .stacking
        message = prior == nil
            ? String(localized: "No compass or location – the sky's rotation axis will be found from the stars alone.")
            : nil
    }

    func finish() {
        guard phase == .stacking, let processor else { return }
        phase = .finishing
        let orientation = self.orientation
        let groundDirection = self.groundDirection
        let lens = self.lens, iso = self.iso, focus = self.focus
        let lensLabel = lenses.first { $0.choice == lens }?.zoomLabel ?? ""
        let saveDiagnostics = self.saveDiagnostics
        var context: [String] = []
        if let g = startGravity { context.append(String(format: "Gravity (device): (%.3f, %.3f, %.3f), EXIF orientation %d", g.x, g.y, g.z, orientation)) }
        context.append(motion.latitude.map { String(format: "Latitude: %.2f°", $0) } ?? "Latitude: unavailable")
        context.append(motion.headingAccuracy.map { String(format: "Compass accuracy: %.0f°", $0) } ?? "Compass accuracy: unavailable")
        context.append(priorPole.map { String(format: "Axis from sensors (camera): (%.4f, %.4f, %.4f)", $0.x, $0.y, $0.z) } ?? "Axis from sensors: unavailable")
        context.append(captureErrors.isEmpty ? "Capture errors: none" : "Capture errors (\(captureErrors.count)):")
        context += captureErrors
        processor.finish { [weak self] stack, stats, engine, diagnostics in
            let pole = engine?.pole
            let poleFitted = engine?.poleFitted ?? false
            let fit = engine?.lastFit
            Task.detached(priority: .userInitiated) {
                guard let stack, stack.frameCount > 0 else {
                    await self?.finished(nil, message: String(localized: "No accepted frames – nothing to save."))
                    return
                }
                var options = FinishingOptions()
                options.groundDirection = groundDirection
                options.groundPrior = diagnostics.groundMask
                options.skyDrift = diagnostics.maxSkyDrift
                let finished = Finisher.finish(stack, options: options)
                var summary = [
                    "AstralCamera – \(Date().formatted())",
                    "Lens: \(lens.rawValue) \(lensLabel), ISO \(Int(iso)), focus \(String(format: "%.3f", focus))",
                    "Frames: \(stats.accepted) accepted / \(stats.captured) captured, rejected \(stats.rejected) (wrong exposure \(stats.wrongExposure)), dropped \(stats.dropped)",
                    String(format: "Total exposure: %.0f s", stats.integration),
                    "Master dark: \(stats.masterDark ? "yes" : "no")",
                ]
                if poleFitted, let pole, let fit {
                    summary.append(String(format: "Sky rotation axis (camera): (%.4f, %.4f, %.4f), RMS %.2f px, focal scale %.4f",
                                          pole.x, pole.y, pole.z, fit.rms, fit.focalScale))
                }
                if let offset = stats.poleOffsetFromPrior {
                    summary.append(String(format: "Axis difference from sensors: %.1f°", offset))
                }
                summary += diagnostics.lines + context
                do {
                    let exported = try await ExportService.export(finished, stack: saveDiagnostics ? stack : nil, stats: stats,
                                                              orientation: orientation, summary: summary)
                    let image = ImageExport.makeCGImage8(finished.display)
                    await self?.finished(SessionResult(image: image, orientation: Self.imageOrientation(orientation),
                                                       export: exported, notes: summary + finished.notes), message: nil)
                } catch {
                    await self?.finished(nil, message: String(localized: "Saving failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func finished(_ result: SessionResult?, message: String?) {
        UIApplication.shared.isIdleTimerDisabled = false
        self.result = result
        self.message = message
        phase = result == nil ? .framing : .done
    }

    func newSession() {
        result = nil
        stackStart = nil
        processor?.startFraming()
        phase = .framing
    }

    private func apply(_ update: ProcessorUpdate) {
        if let p = update.preview { preview = p }
        stats = update.stats
        if let m = update.message { message = m }
        // iOS may silently override manual ISO (reported for iPhone 17 Pro in third-party apps).
        if let actual = update.stats.actualISO, phase == .framing || phase == .stacking,
           abs(actual - iso) / max(iso, 1) > 0.15, warnedISO != iso {
            warnedISO = iso
            message = String(localized: "Note: the camera is using ISO \(Int(actual)) instead of the \(Int(iso)) you set.")
        }
        if phase == .darks, update.mode == .framing { phase = .framing }
        if phase == .focusing, update.mode == .framing, update.preview != nil {
            advanceFocusSweep(score: update.stats.focusScore)
        }
    }

    private func thermalChanged() {
        thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical, phase == .stacking {
            message = String(localized: "The phone is critically hot – finishing and saving the session.")
            finish()
        }
    }

    static func imageOrientation(_ exif: UInt32) -> Image.Orientation {
        switch exif {
        case 3: .down
        case 6: .right
        case 8: .left
        default: .up
        }
    }
}
