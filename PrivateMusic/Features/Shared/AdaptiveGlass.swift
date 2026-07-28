import SwiftUI

struct ThemeBackground: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        LinearGradient(
            colors: settings.theme.colors,
            startPoint: .top,
            endPoint: .bottom
        )
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
                    .tint(.primary.opacity(0.06))
                    .interactive(interactive),
                in: shape
            )
        } else if settings.liquidGlassEnabled {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(
                        Color.primary.opacity(0.11),
                        lineWidth: 0.8
                    )
                }
        } else {
            content
                .background(
                    settings.theme.surface,
                    in: shape
                )
                .overlay {
                    shape.stroke(.primary.opacity(0.08), lineWidth: 0.7)
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
