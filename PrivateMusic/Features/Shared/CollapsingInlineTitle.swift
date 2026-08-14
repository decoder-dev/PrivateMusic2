import SwiftUI
import UIKit

/// Reports the global minY of a hero title so the nav bar can reveal
/// its own title only after the hero title has scrolled away.
struct HeroTitleMinYKey: PreferenceKey {
    static var defaultValue: CGFloat { .greatestFiniteMagnitude }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

extension View {
    /// Attach to the large in-content title. Pair with
    /// `collapsingInlineNavigationTitle`.
    func heroTitleScrollAnchor() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: HeroTitleMinYKey.self,
                    value: geometry.frame(in: .global).minY
                )
            }
        }
    }

    /// Inline nav title that fades in once the hero title scrolls under
    /// the navigation bar. Keeps `.navigationTitle("")` so the back
    /// chevron layout stays stable.
    func collapsingInlineNavigationTitle(
        _ title: String,
        isVisible: Binding<Bool>
    ) -> some View {
        navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .opacity(isVisible.wrappedValue ? 1 : 0)
                        .accessibilityHidden(!isVisible.wrappedValue)
                }
            }
            .onPreferenceChange(HeroTitleMinYKey.self) { minY in
                let threshold = CollapsingNavMetrics.titleRevealThreshold
                let shouldShow = minY < threshold
                guard shouldShow != isVisible.wrappedValue else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    isVisible.wrappedValue = shouldShow
                }
            }
    }
}

private enum CollapsingNavMetrics {
    /// Status bar + inline nav bar — hero title crossing this line
    /// means the large in-content title is no longer readable.
    static var titleRevealThreshold: CGFloat {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let inset = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top
            ?? scenes.first?.windows.first?.safeAreaInsets.top
            ?? 47
        return inset + 52
    }
}
