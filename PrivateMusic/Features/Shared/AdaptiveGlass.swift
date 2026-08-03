import SwiftUI
import UIKit

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
    let tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            // Liquid Glass samples its own shape; clipping the content
            // before handing it to glassEffect(in:) fights that sampling
            // and is a documented source of rendering artifacts. The
            // `in: shape` parameter already constrains the glass region.
            if let tint {
                content
                    .glassEffect(
                        .regular
                            .tint(tint)
                            .interactive(interactive),
                        in: shape
                    )
                    .contentShape(shape)
            } else {
                content
                    .glassEffect(
                        .regular.interactive(interactive),
                        in: shape
                    )
                    .contentShape(shape)
            }
        } else {
            content
                .clipShape(shape)
                .background {
                    if reduceTransparency {
                        shape.fill(Color(uiColor: .secondarySystemBackground))
                    } else {
                        shape.fill(.ultraThinMaterial)
                    }
                }
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *), !reduceTransparency {
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
        tint: Color? = nil
    ) -> some View {
        modifier(
            AdaptiveGlassModifier(
                shape: shape,
                interactive: interactive,
                tint: tint
            )
        )
    }
}
