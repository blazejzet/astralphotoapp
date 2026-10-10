import AVKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = SessionModel()
    @StateObject private var interface = InterfaceOrientation()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch model.phase {
            case .done:
                ResultView(model: model)
            case .failed(let text):
                FailureView(text: text)
            default:
                CaptureView(model: model, interfaceOrientation: interface.value)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.primary)
        .onAppear { interface.attach() }
        .task { await model.start() }
    }
}

// MARK: - Capture

/// The preview sits on its own full-screen layer; every control floats above it on glass,
/// so messages, panels and phase changes never resize or move the image.
struct CaptureView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject private var motion: MotionProvider
    var interfaceOrientation: UIInterfaceOrientation
    @State private var adjuster: Adjuster?

    init(model: SessionModel, interfaceOrientation: UIInterfaceOrientation) {
        self.model = model
        self.interfaceOrientation = interfaceOrientation
        motion = model.motion
    }

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height
            ZStack {
                PreviewLayer(image: model.preview,
                             orientation: InterfaceOrientation.previewOrientation(interfaceOrientation),
                             pixelated: model.zoom)
                Group {
                    if landscape { landscapeChrome } else { portraitChrome }
                }
                .animation(.snappy(duration: 0.3), value: adjuster)
                .animation(.snappy(duration: 0.3), value: model.phase)
                .animation(.snappy(duration: 0.3), value: model.message)
            }
        }
        .foregroundStyle(Theme.primary)
        // Volume buttons, Camera Control and Bluetooth remotes act as the shutter – no touching the tripod.
        .onCameraCaptureEvent { event in
            if event.phase == .ended { model.shutter() }
        }
        .onChange(of: model.phase) { _, phase in
            if phase != .framing { adjuster = nil }
        }
    }

    private var portraitChrome: some View {
        VStack(spacing: 10) {
            TopBar(model: model, motion: motion)
            StatsHUD(model: model, motion: motion, axis: .horizontal)
            Spacer(minLength: 0)
            bottomPanels
            ShutterBar(model: model, axis: .horizontal)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var landscapeChrome: some View {
        HStack(alignment: .top, spacing: 12) {
            StatsHUD(model: model, motion: motion, axis: .vertical)
                .frame(maxHeight: .infinity, alignment: .top)
            VStack(spacing: 10) {
                TopBar(model: model, motion: motion)
                Spacer(minLength: 0)
                bottomPanels
                    .frame(maxWidth: 480)
            }
            ShutterBar(model: model, axis: .vertical)
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var bottomPanels: some View {
        VStack(spacing: 10) {
            if let message = model.message {
                Toast(text: message) { model.message = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            switch model.phase {
            case .framing:
                if let adjuster {
                    AdjusterPanel(model: model, adjuster: adjuster)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                ParameterBar(model: model, adjuster: $adjuster)
                    .transition(.opacity)
            case .focusing:
                StatusCard(text: "Sweeping focus and measuring star peak brightness (highest = sharpest). Keep the phone still.",
                           progress: model.focusProgress)
                    .transition(.opacity)
            case .finishing:
                StatusCard(text: "Sky mask, gradient, deconvolution, colour, saving…", progress: nil)
                    .transition(.opacity)
            default:
                EmptyView()
            }
        }
    }
}

/// Live image, fitted into the whole view. Its frame depends only on the screen, never on the controls.
struct PreviewLayer: View {
    var image: CGImage?
    var orientation: Image.Orientation
    var pixelated: Bool

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1, orientation: orientation)
                    .resizable()
                    .interpolation(pixelated ? .none : .medium)
                    .scaledToFit()
            } else {
                ProgressView().tint(Theme.primary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { $0.animation = nil }
        .accessibilityHidden(true)
    }
}

// MARK: - Failure

struct FailureView: View {
    var text: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text(text).multilineTextAlignment(.center)
        }
        .foregroundStyle(Theme.primary)
        .padding(24)
        .nightGlass(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding()
    }
}
