import SwiftUI

enum AdaptiveGlassVariant {
    case regular
    case clear
}

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
    let shape: S
    let interactive: Bool
    let variant: AdaptiveGlassVariant
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            switch variant {
            case .regular:
                content
                    .clipShape(shape)
                    .glassEffect(
                        .regular
                            .tint(tint ?? .primary.opacity(0.06))
                            .interactive(interactive),
                        in: shape
                    )
                    .contentShape(shape)
            case .clear:
                content
                    .clipShape(shape)
                    .glassEffect(
                        .clear.interactive(interactive),
                        in: shape
                    )
                    .contentShape(shape)
            }
        } else {
            content
                .clipShape(shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(
                        Color.primary.opacity(0.11),
                        lineWidth: 0.8
                    )
                }
                .contentShape(shape)
        }
    }
}

struct AdaptiveGlassContainer<Content: View>: View {
    let spacing: CGFloat?
    private let content: Content

    init(
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    func adaptiveGlass<S: Shape>(
        in shape: S,
        interactive: Bool = false,
        variant: AdaptiveGlassVariant = .regular,
        tint: Color? = nil
    ) -> some View {
        modifier(
            AdaptiveGlassModifier(
                shape: shape,
                interactive: interactive,
                variant: variant,
                tint: tint
            )
        )
    }
}
