import SwiftUI

/// Legacy connect-screen entry point. Colour tokens live in `BubbleGamut`.
enum Brand {
    static var accent: Color { BubbleGamut.accentColor(for: .dark) }
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
