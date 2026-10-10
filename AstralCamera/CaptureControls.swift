import SwiftUI

/// The setting the slider panel above the parameter bar is editing.
enum Adjuster {
    case iso
    case focus
}

// MARK: - Top bar

struct TopBar: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var motion: MotionProvider

    var body: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                PhasePill(model: model)
                Spacer(minLength: 0)
                if model.thermal == .serious || model.thermal == .critical {
                    GlassIcon(symbol: "thermometer.high", size: 36)
                        .accessibilityLabel("Hot")
                }
                GlassIcon(symbol: motion.isStill ? "camera.on.rectangle" : "hand.raised", size: 36, dimmed: !motion.isStill)
                    .accessibilityLabel(motion.isStill ? LocalizedStringKey("Tripod") : LocalizedStringKey("Moving"))
                if model.phase == .framing {
                    Button { model.zoom.toggle() } label: {
                        Image(systemName: model.zoom ? "minus.magnifyingglass" : "plus.magnifyingglass")
                    }
                    .buttonStyle(GlassIconButtonStyle(size: 36, prominent: model.zoom))
                    .accessibilityLabel("Loupe 1:1")
                    SettingsMenu(model: model)
                }
            }
        }
    }
}

struct PhasePill: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .symbolEffect(.pulse, isActive: model.phase == .stacking)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 12)
        .frame(height: 36)
        .nightGlass(Capsule())
    }

    private var symbol: String {
        switch model.phase {
        case .framing: model.zoom ? "plus.magnifyingglass" : "viewfinder"
        case .darks: "moon.fill"
        case .focusing: "scope"
        case .stacking: "record.circle"
        case .finishing: "gearshape.2"
        default: "hourglass"
        }
    }

    private var title: LocalizedStringKey {
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
}

struct SettingsMenu: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        Menu {
            Toggle(isOn: $model.saveDiagnostics) {
                Label("Save diagnostic data (stacks, ~150 MB)", systemImage: "externaldrive")
            }
            Button(role: .destructive) { model.clearDarks() } label: {
                Label("Delete master dark", systemImage: "trash")
            }
            .disabled(!model.stats.masterDark)
            Section {
                Text("Darks: cover the lens at the same ISO and exposure. On a tripod you need no self-timer – you can leave the screen on.")
            }
        } label: {
            GlassIcon(symbol: "ellipsis", size: 36)
        }
        .accessibilityLabel("More")
    }
}

struct GlassIcon: View {
    var symbol: String
    var size: CGFloat = 44
    var dimmed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(dimmed ? Theme.secondary : Theme.primary)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size, height: size)
            .nightGlass(Circle())
    }
}

// MARK: - Live statistics

/// Icon + value chips in a fixed grid, so changing numbers never shift the layout.
/// Tap to show the names under the values.
struct StatsHUD: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var motion: MotionProvider
    var axis: Axis
    @AppStorage("hud.showTitles") private var showTitles = false

    private struct Item {
        var title: LocalizedStringKey
        var symbol: String
        var value: String
    }

    var body: some View {
        let items = self.items
        Group {
            if axis == .vertical {
                VStack(alignment: .leading, spacing: showTitles ? 8 : 12) {
                    ForEach(items.indices, id: \.self) { chip(items[$0]) }
                }
                .frame(minWidth: 84, alignment: .leading)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow { ForEach(0..<3, id: \.self) { chip(items[$0]) } }
                    GridRow { ForEach(3..<6, id: \.self) { chip(items[$0]) } }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .nightGlass(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { withAnimation(.snappy) { showTitles.toggle() } }
    }

    private func chip(_ item: Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: item.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.value)
                    .font(.system(.footnote, design: .rounded).monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                if showTitles {
                    Text(item.title)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .frame(maxWidth: axis == .horizontal ? .infinity : nil, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.title))
        .accessibilityValue(Text(item.value))
    }

    private var items: [Item] {
        let s = model.stats
        if model.phase == .stacking || model.phase == .finishing {
            return [
                Item(title: "Time", symbol: "clock", value: Self.duration(s.integration)),
                Item(title: "Frames", symbol: "square.stack.3d.up", value: "\(s.accepted)/\(s.captured)"),
                Item(title: "Stars", symbol: "sparkles", value: "\(s.matched)/\(s.stars)"),
                Item(title: "Residual", symbol: "target", value: String(format: "%.2f px", s.rms)),
                Item(title: "Sky axis", symbol: "rotate.3d",
                     value: s.poleFitted ? String(format: "✓ %.2f px", s.poleFitRMS ?? 0) : String(localized: "searching…")),
                Item(title: "Compass Δ", symbol: "safari", value: s.poleOffsetFromPrior.map { String(format: "%.1f°", $0) } ?? "–"),
            ]
        }
        return [
            Item(title: "Stars", symbol: "sparkles", value: "\(s.stars)"),
            Item(title: "Focus (S/N)", symbol: "dot.scope", value: String(format: "%.0f", s.focusScore)),
            Item(title: "Exposure", symbol: "timer", value: model.capabilities.map { String(format: "%.2f s", $0.exposure) } ?? "–"),
            Item(title: "Latitude", symbol: "location", value: motion.latitude.map { String(format: "%.1f°", $0) } ?? "–"),
            Item(title: "Compass ±", symbol: "location.north.line",
                 value: motion.headingAccuracy.map { $0 < 0 ? String(localized: "none") : String(format: "%.0f°", $0) } ?? "–"),
            Item(title: "Actual ISO", symbol: "camera.aperture", value: s.actualISO.map { String(format: "%.0f", $0) } ?? "–"),
        ]
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Messages

struct Toast: View {
    var text: String
    var onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "info.circle")
                Text(text)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                Spacer(minLength: 0)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.secondary)
            }
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nightGlass(RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Dismiss")
    }
}

struct StatusCard: View {
    var text: LocalizedStringKey
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress {
                ProgressView(value: progress)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if progress == nil { ProgressView().controlSize(.small) }
                Text(text).font(.caption)
            }
        }
        .tint(Theme.primary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Settings

/// ISO · lens · focus, like the Camera app's zoom row. Tapping ISO or focus opens the slider panel.
struct ParameterBar: View {
    @ObservedObject var model: SessionModel
    @Binding var adjuster: Adjuster?

    var body: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                ParameterChip(title: "ISO", symbol: nil, value: "\(Int(model.iso))", active: adjuster == .iso) {
                    toggle(.iso)
                }
                if !model.lenses.isEmpty {
                    LensSwitcher(model: model)
                }
                ParameterChip(title: "Focus", symbol: "mountain.2", value: String(format: "%.3f", model.focus),
                              active: adjuster == .focus) {
                    toggle(.focus)
                }
            }
        }
    }

    private func toggle(_ value: Adjuster) {
        adjuster = adjuster == value ? nil : value
    }
}

struct ParameterChip: View {
    var title: LocalizedStringKey
    var symbol: String?
    var value: String
    var active: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.caption.weight(.bold))
                } else {
                    Text(title).font(.caption2.weight(.heavy))
                }
                Text(value)
                    .font(.system(.subheadline, design: .rounded).monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(active ? Color.black : Theme.primary)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Capsule())
            .nightGlass(Capsule(), prominent: active, interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct LensSwitcher: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.lenses) { option in
                let selected = option.choice == model.lens
                Button {
                    if !selected { model.lens = option.choice }
                } label: {
                    Text(verbatim: option.zoomLabel)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(selected ? Color.black : Theme.primary)
                        .frame(width: 38, height: 38)
                        .background { if selected { Circle().fill(Theme.primary) } }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(option.choice.name))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .nightGlass(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lens")
    }
}

/// Slider with fine steps. ISO moves on a log scale (⅓ stop per step), focus by 0.002.
struct AdjusterPanel: View {
    @ObservedObject var model: SessionModel
    var adjuster: Adjuster

    var body: some View {
        HStack(spacing: 6) {
            step(-1, symbol: "minus")
            Slider(value: binding, in: range) { editing in
                if !editing { model.applyExposureSettings() }
            }
            .accessibilityLabel(adjuster == .iso ? Text("ISO") : Text("Focus"))
            step(1, symbol: "plus")
            Text(valueText)
                .font(.system(.footnote, design: .rounded).monospacedDigit().weight(.semibold))
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.leading, 6)
        .padding(.trailing, 16)
        .frame(height: 52)
        .nightGlass(Capsule())
    }

    private var isoRange: ClosedRange<Double> {
        let caps = model.capabilities
        return Double(caps?.minISO ?? 50)...Double(caps?.maxISO ?? 3200)
    }

    private var range: ClosedRange<Double> {
        switch adjuster {
        case .iso: log2(isoRange.lowerBound)...log2(isoRange.upperBound)
        case .focus: 0.5...1.0
        }
    }

    private var binding: Binding<Double> {
        switch adjuster {
        case .iso:
            Binding(get: { log2(Double(model.iso)) }, set: { model.iso = Float(exp2($0).rounded()) })
        case .focus:
            Binding(get: { Double(model.focus) }, set: { model.focus = Float($0) })
        }
    }

    private var valueText: String {
        switch adjuster {
        case .iso: "\(Int(model.iso))"
        case .focus: String(format: "%.3f", model.focus)
        }
    }

    private func step(_ direction: Double, symbol: String) -> some View {
        Button {
            switch adjuster {
            case .iso:
                let next = (Double(model.iso) * exp2(direction / 3)).rounded()
                model.iso = Float(min(max(next, isoRange.lowerBound), isoRange.upperBound))
            case .focus:
                model.focus = Float(min(max(Double(model.focus) + direction * 0.002, 0.5), 1.0))
            }
            model.applyExposureSettings()
        } label: {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(direction < 0 ? Text("Decrease") : Text("Increase"))
    }
}

// MARK: - Shutter

/// Darks · shutter · autofocus. Fixed slots keep the shutter in place whatever the phase.
struct ShutterBar: View {
    @ObservedObject var model: SessionModel
    var axis: Axis

    var body: some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        GlassGroup {
            layout {
                slot { darksButton }
                Spacer(minLength: 16)
                ShutterButton(model: model)
                Spacer(minLength: 16)
                slot { trailingButton }
            }
        }
    }

    private func slot(@ViewBuilder _ content: () -> some View) -> some View {
        content().frame(width: 52, height: 52)
    }

    @ViewBuilder
    private var darksButton: some View {
        if model.phase == .framing {
            let ready = model.stats.masterDark
            Button { model.startDarks() } label: {
                Image(systemName: ready ? "moon.fill" : "moon")
                    .overlay(alignment: .topTrailing) {
                        if ready {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                                .offset(x: 9, y: -7)
                        }
                    }
            }
            .buttonStyle(GlassIconButtonStyle(size: 52))
            .contextMenu {
                Button(role: .destructive) { model.clearDarks() } label: {
                    Label("Delete master dark", systemImage: "trash")
                }
            }
            .accessibilityLabel(ready ? LocalizedStringKey("Darks ✓") : LocalizedStringKey("Darks"))
            .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        switch model.phase {
        case .framing:
            Button { model.startAutofocus() } label: { Image(systemName: "scope") }
                .buttonStyle(GlassIconButtonStyle(size: 52))
                .accessibilityLabel("Autofocus")
                .transition(.scale.combined(with: .opacity))
        case .focusing:
            Button { model.cancelAutofocus() } label: { Image(systemName: "xmark") }
                .buttonStyle(GlassIconButtonStyle(size: 52))
                .accessibilityLabel("Cancel")
                .transition(.scale.combined(with: .opacity))
        default:
            EmptyView()
        }
    }
}

/// Camera-style shutter: a circle starts the stack, a square finishes it (like video recording).
/// The ring shows darks / autofocus progress. No haptics – a vibration would shake the tripod.
struct ShutterButton: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        let phase = model.phase
        let recording = phase == .stacking
        let enabled = phase == .framing || phase == .stacking
        Button { model.shutter() } label: {
            ZStack {
                Circle().stroke(Theme.dim, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(Theme.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                RoundedRectangle(cornerRadius: recording ? 8 : 30, style: .continuous)
                    .fill(enabled ? Theme.primary : Theme.surface)
                    .frame(width: recording ? 30 : 60, height: recording ? 30 : 60)
                if phase == .finishing || phase == .starting {
                    ProgressView().tint(Theme.primary)
                }
            }
            .frame(width: 76, height: 76)
            .contentShape(Circle())
        }
        .buttonStyle(ShutterPressStyle())
        .disabled(!enabled)
        .accessibilityLabel(recording ? LocalizedStringKey("Finish and save") : LocalizedStringKey("Start"))
    }

    private var ringProgress: Double {
        switch model.phase {
        case .darks: Double(model.stats.darkFrames) / Double(SessionModel.darkFrameCount)
        case .focusing: model.focusProgress
        case .framing, .stacking: 1
        default: 0
        }
    }
}

private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
