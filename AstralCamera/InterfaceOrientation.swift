import SwiftUI
import UIKit

/// Interface orientation of the app's window scene. Observing `effectiveGeometry` also catches
/// 180° turns (landscape left ↔ right), which leave the view size unchanged.
@MainActor
final class InterfaceOrientation: ObservableObject {
    @Published private(set) var value: UIInterfaceOrientation = .portrait
    private var observation: NSKeyValueObservation?

    func attach() {
        guard observation == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        observation = scene.observe(\.effectiveGeometry, options: [.initial, .new]) { [weak self] scene, _ in
            MainActor.assumeIsolated { self?.update(scene.effectiveGeometry.interfaceOrientation) }
        }
    }

    private func update(_ orientation: UIInterfaceOrientation) {
        if orientation != .unknown, orientation != value { value = orientation }
    }

    /// How to turn the back camera's sensor-native (landscape) buffer so it is upright on screen.
    /// Follows the interface, not gravity: pointing at the zenith no longer flips the preview.
    static func previewOrientation(_ orientation: UIInterfaceOrientation) -> Image.Orientation {
        switch orientation {
        case .landscapeRight: .up
        case .landscapeLeft: .down
        case .portraitUpsideDown: .left
        default: .right
        }
    }
}
