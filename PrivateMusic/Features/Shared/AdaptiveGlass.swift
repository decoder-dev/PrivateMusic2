import SwiftUI
import UIKit

struct ThemeBackground: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        LinearGradient(
            colors: settings.theme.colors,
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

private struct ClassicChromeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set on a subtree that the user has pinned to the pre-iOS 26 look.
    /// Without it the surfaces built from `adaptiveGlass` would keep their
    /// Liquid Glass while the hand-written branches around them fell back,
    /// leaving isolated glass pills floating over flat chrome.
    var prefersClassicChrome: Bool {
        get { self[ClassicChromeKey.self] }
        set { self[ClassicChromeKey.self] = newValue }
    }
}

private struct AdaptiveGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.prefersClassicChrome) private var prefersClassicChrome

    private var flattensGlass: Bool {
        ContrastPolicy.flattensCustomGlass(
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased,
            prefersClassicChrome: prefersClassicChrome
        )
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !flattensGlass {
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
            let increased = colorSchemeContrast == .increased
            content
                .clipShape(shape)
                .background {
                    if reduceTransparency || increased {
                        shape.fill(Color(uiColor: .secondarySystemBackground))
                    } else {
                        shape.fill(.ultraThinMaterial)
                    }
                }
                .overlay {
                    shape.stroke(
                        Color.primary.opacity(
                            ContrastPolicy.strokeOpacity(
                                increased: increased,
                                reduceTransparency: reduceTransparency
                            )
                        ),
                        lineWidth: ContrastPolicy.strokeWidth(increased: increased)
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
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.prefersClassicChrome) private var prefersClassicChrome

    init(
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *),
           !ContrastPolicy.flattensCustomGlass(
               reduceTransparency: reduceTransparency,
               increaseContrast: colorSchemeContrast == .increased,
               prefersClassicChrome: prefersClassicChrome
           ) {
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
