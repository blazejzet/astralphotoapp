import SwiftUI

struct ContentView: View {
    @StateObject private var model = SessionModel()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch model.phase {
            case .done:
                ResultView(model: model)
            case .failed(let text):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(text).multilineTextAlignment(.center)
                }
                .foregroundStyle(Theme.primary)
                .padding()
            default:
                CaptureView(model: model)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.primary)
        .task { await model.start() }
    }
}

// MARK: - Capture

struct CaptureView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject private var motion: MotionProvider

    init(model: SessionModel) {
        self.model = model
        motion = model.motion
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            preview
            StatsGrid(model: model, motion: motion)
            if let message = model.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { model.message = nil }
            }
            Spacer(minLength: 0)
            controls
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .foregroundStyle(Theme.primary)
    }

    private var header: some View {
        HStack {
            Text("AstralCamera").font(.system(.title2, design: .rounded).weight(.bold))
            Spacer()
            if model.thermal == .serious || model.thermal == .critical {
                Label("Hot", systemImage: "thermometer.high").font(.caption)
            }
            Label(motion.isStill ? LocalizedStringKey("Tripod") : LocalizedStringKey("Moving"),
                  systemImage: motion.isStill ? "camera.on.rectangle" : "hand.raised")
                .font(.caption)
                .foregroundStyle(motion.isStill ? Theme.primary : Theme.secondary)
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Theme.surface)
            if let image = model.preview {
                Image(decorative: image, scale: 1, orientation: model.zoom ? .up : model.displayOrientation)
                    .resizable()
                    .interpolation(model.zoom ? .none : .medium)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ProgressView().tint(Theme.primary)
            }
            VStack {
                HStack {
                    Text(phaseTitle).font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                    Spacer()
                    if model.phase == .framing {
                        Button { model.zoom.toggle() } label: {
                            Image(systemName: model.zoom ? "minus.magnifyingglass" : "plus.magnifyingglass")
                                .padding(8).background(Circle().fill(Color.black.opacity(0.6)))
                        }
                    }
                }
                Spacer()
            }
            .padding(8)
        }
        .frame(maxHeight: .infinity)
    }

    private var phaseTitle: LocalizedStringKey {
        switch model.phase {
        case .starting: "Starting…"
        case .framing: model.zoom ? "Loupe 1:1 – set focus" : "Framing (single frame)"
        case .darks: "Darks \(model.stats.darkFrames)/\(SessionModel.darkFrameCount) – lens covered"
        case .focusing: "Autofocus \(Int(model.focusProgress * 100))% – focus \(String(format: "%.3f", model.focus))"
        case .stacking: "Exposing (stack)"
        case .finishing: "Processing…"
        default: ""
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .framing:
            VStack(spacing: 10) {
                Picker("Lens", selection: $model.lens) {
                    ForEach(model.lenses) { option in
                        Text(verbatim: option.zoomLabel)
                            .accessibilityLabel(Text(option.choice.name))
                            .tag(option.choice)
                    }
                }
                .pickerStyle(.segmented)
                if let caps = model.capabilities {
                    SliderRow(title: "ISO", value: Binding(get: { Double(model.iso) }, set: { model.iso = Float($0) }),
                              range: Double(caps.minISO)...Double(caps.maxISO), format: "%.0f") {
                        model.applyExposureSettings()
                    }
                }
                HStack(spacing: 8) {
                    SliderRow(title: "Focus", value: Binding(get: { Double(model.focus) }, set: { model.focus = Float($0) }),
                              range: 0.5...1.0, format: "%.3f") {
                        model.applyExposureSettings()
                    }
                    Button { model.startAutofocus() } label: {
                        Label("Auto", systemImage: "scope").font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                HStack(spacing: 10) {
                    Button(model.stats.masterDark ? LocalizedStringKey("Darks ✓") : LocalizedStringKey("Darks")) { model.startDarks() }
                        .buttonStyle(NightButtonStyle())
                        .contextMenu {
                            Button("Delete master dark", role: .destructive) { model.clearDarks() }
                        }
                    Button("Start") { model.startStacking() }
                        .buttonStyle(NightButtonStyle(prominent: true))
                }
                Toggle("Save diagnostic data (stacks, ~150 MB)", isOn: $model.saveDiagnostics)
                    .font(.caption)
                    .tint(Theme.secondary)
                Text("Darks: cover the lens at the same ISO and exposure. On a tripod you need no self-timer – you can leave the screen on.")
                    .font(.caption2)
                    .foregroundStyle(Theme.dim)
            }
        case .focusing:
            VStack(spacing: 10) {
                ProgressView(value: model.focusProgress).tint(Theme.primary)
                Text("Sweeping focus and measuring star peak brightness (highest = sharpest). Keep the phone still.")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                Button("Cancel") { model.cancelAutofocus() }
                    .buttonStyle(NightButtonStyle())
            }
        case .stacking:
            Button("Finish and save") { model.finish() }
                .buttonStyle(NightButtonStyle(prominent: true))
        case .finishing:
            HStack(spacing: 12) {
                ProgressView().tint(Theme.primary)
                Text("Sky mask, gradient, deconvolution, colour, saving…").font(.footnote)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        default:
            EmptyView()
        }
    }
}

struct SliderRow: View {
    var title: LocalizedStringKey
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: String
    var onCommit: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.footnote).frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range) { editing in
                if !editing { onCommit() }
            }
            Text(String(format: format, value)).font(.footnote.monospacedDigit()).frame(width: 56, alignment: .trailing)
        }
    }
}

struct StatsGrid: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var motion: MotionProvider

    var body: some View {
        let s = model.stats
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            if model.phase == .stacking || model.phase == .finishing {
                StatCell(title: "Time", value: Self.duration(s.integration))
                StatCell(title: "Frames", value: "\(s.accepted)/\(s.captured)")
                StatCell(title: "Stars", value: "\(s.matched)/\(s.stars)")
                StatCell(title: "Residual", value: String(format: "%.2f px", s.rms))
                StatCell(title: "Sky axis", value: s.poleFitted ? String(format: "✓ %.2f px", s.poleFitRMS ?? 0) : String(localized: "searching…"))
                StatCell(title: "Compass Δ", value: s.poleOffsetFromPrior.map { String(format: "%.1f°", $0) } ?? "–")
            } else {
                StatCell(title: "Stars", value: "\(s.stars)")
                StatCell(title: "Focus (S/N)", value: String(format: "%.0f", s.focusScore))
                StatCell(title: "Exposure", value: model.capabilities.map { String(format: "%.2f s", $0.exposure) } ?? "–")
                StatCell(title: "Latitude", value: motion.latitude.map { String(format: "%.1f°", $0) } ?? "–")
                StatCell(title: "Compass ±", value: motion.headingAccuracy.map { $0 < 0 ? String(localized: "none") : String(format: "%.0f°", $0) } ?? "–")
                StatCell(title: "Actual ISO", value: s.actualISO.map { String(format: "%.0f", $0) } ?? "–")
            }
        }
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct StatCell: View {
    var title: LocalizedStringKey
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(Theme.secondary)
            Text(value).font(.system(.callout, design: .rounded).monospacedDigit().weight(.semibold))
        }
    }
}

// MARK: - Result

struct ResultView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        VStack(spacing: 12) {
            if let result = model.result {
                if let image = result.image {
                    Image(decorative: image, scale: 1, orientation: result.orientation)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.notes, id: \.self) { Text($0) }
                        if let export = result.export {
                            Text(export.savedToPhotos ? LocalizedStringKey("Saved to Photos.")
                                                      : LocalizedStringKey("No Photos access – the file is in the Files app."))
                            Text("Files: \(export.folder.lastPathComponent) (JPEG + 32-bit linear TIFF)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    if let export = result.export {
                        ShareLink(item: export.jpeg) { Text("Share") }
                            .buttonStyle(NightButtonStyle())
                    }
                    Button("New session") { model.newSession() }
                        .buttonStyle(NightButtonStyle(prominent: true))
                }
            }
        }
        .padding(16)
        .foregroundStyle(Theme.primary)
    }
}
