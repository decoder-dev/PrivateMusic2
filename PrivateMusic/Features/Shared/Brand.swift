import SwiftUI

enum Brand {
    static let background = Color(
        red: 0.025,
        green: 0.03,
        blue: 0.075
    )
    static let surface = Color(
        red: 0.075,
        green: 0.085,
        blue: 0.16
    )
    static let accent = Color(
        red: 0.30,
        green: 0.45,
        blue: 1.0
    )
    static let violet = Color(
        red: 0.52,
        green: 0.30,
        blue: 1.0
    )
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 15)
            .padding(.horizontal, 18)
            .foregroundStyle(settings.theme.buttonForeground)
            .background(settings.theme.accent)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: PremiumLayout.compactRadius,
                    style: .continuous
                )
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: PremiumLayout.compactRadius,
                    style: .continuous
                )
            )
            .scaleEffect(
                reduceMotion || !configuration.isPressed ? 1 : 0.98
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}
