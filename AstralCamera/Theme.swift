import SwiftUI

/// Red-on-black UI that preserves dark adaptation at night.
enum Theme {
    static let background = Color.black
    static let primary = Color(red: 1.0, green: 0.27, blue: 0.2)
    static let secondary = Color(red: 0.62, green: 0.16, blue: 0.13)
    static let dim = Color(red: 0.32, green: 0.08, blue: 0.07)
    static let surface = Color(red: 0.09, green: 0.02, blue: 0.02)
    /// Glass tints: a faint red cast keeps the glass from going grey over the black sky.
    static let glassTint = Color(red: 0.25, green: 0.03, blue: 0.02).opacity(0.35)
    static let glassProminentTint = primary.opacity(0.75)
}

extension View {
    /// Liquid Glass on iOS 26+, a dark red material below that.
    @ViewBuilder
    func nightGlass<S: Shape>(_ shape: S, prominent: Bool = false, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.tint(prominent ? Theme.glassProminentTint : Theme.glassTint).interactive(interactive),
                        in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(prominent ? Theme.primary.opacity(0.8) : Theme.surface.opacity(0.6))
                }
            }
            .overlay(shape.stroke(Theme.dim, lineWidth: 0.5))
        }
    }
}

/// Lets neighbouring glass shapes blend and morph into each other (iOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Round glass icon button (secondary controls around the shutter and in the top bar).
struct GlassIconButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(prominent ? Color.black : Theme.primary)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .nightGlass(Circle(), prominent: prominent, interactive: true)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// Capsule glass button with icon and text (result screen, toasts).
struct GlassCapsuleButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(prominent ? Color.black : Theme.primary)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
            .nightGlass(Capsule(), prominent: prominent, interactive: true)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}
