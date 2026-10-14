import SwiftUI

/// Legacy connect-screen entry point. Colour tokens live in `BubbleGamut`.
enum Brand {
    static var accent: Color { BubbleGamut.accentColor(for: .dark) }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(AppSettings.self) private var settings

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 15)
            .padding(.horizontal, 18)
            .foregroundStyle(settings.onAccent)
            .background(settings.accent)
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
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
