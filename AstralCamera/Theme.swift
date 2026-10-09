import SwiftUI

/// Red-on-black UI that preserves dark adaptation at night.
enum Theme {
    static let background = Color.black
    static let primary = Color(red: 1.0, green: 0.27, blue: 0.2)
    static let secondary = Color(red: 0.62, green: 0.16, blue: 0.13)
    static let dim = Color(red: 0.32, green: 0.08, blue: 0.07)
    static let surface = Color(red: 0.09, green: 0.02, blue: 0.02)
}

struct NightButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .foregroundStyle(prominent ? Color.black : Theme.primary)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(prominent ? Theme.primary : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.dim, lineWidth: prominent ? 0 : 1)
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
