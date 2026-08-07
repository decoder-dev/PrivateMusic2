import SwiftUI

/// Reports the global minY of a hero title so the nav bar can reveal
/// its own title only after the hero title has scrolled away.
struct HeroTitleMinYKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude

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
        isVisible: Binding<Bool>,
        threshold: CGFloat = 96
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
                let shouldShow = minY < threshold
                guard shouldShow != isVisible.wrappedValue else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    isVisible.wrappedValue = shouldShow
                }
            }
    }
}
