import SwiftUI

struct ThemeBackground: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        LinearGradient(
            colors: settings.theme.colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            RadialGradient(
                colors: [
                    settings.theme.accent.opacity(0.22),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

private struct AdaptiveGlassModifier<S: Shape>: ViewModifier {
    @EnvironmentObject private var settings: AppSettings
    let shape: S
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), settings.liquidGlassEnabled {
            content.glassEffect(
                .regular
                    .tint(settings.theme.accent.opacity(0.13))
                    .interactive(interactive),
                in: shape
            )
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(
                        settings.theme.accent.opacity(0.16),
                        lineWidth: 0.8
                    )
                }
        }
    }
}

extension View {
    func adaptiveGlass<S: Shape>(
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        modifier(
            AdaptiveGlassModifier(
                shape: shape,
                interactive: interactive
            )
        )
    }
}
