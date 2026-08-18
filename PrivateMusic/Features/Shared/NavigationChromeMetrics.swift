import CoreGraphics
import UIKit

/// Shared measurements for inline navigation chrome. Views that deliberately
/// underlap the top safe area can still resolve the foreground clearance they
/// need without guessing per device.
@MainActor
enum NavigationChromeMetrics {
    /// The compact inline navigation bar band used across the app.
    static let inlineNavigationBarHeight: CGFloat = 52
    /// Fallback when the app has no key window yet. This matches the
    /// smallest modern iPhone status-bar / Dynamic Island reservation the
    /// design supports, so the foreground never collapses to zero.
    static let fallbackTopSafeAreaInset: CGFloat = 47

    static var currentTopSafeAreaInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for window in scene.windows where window.isKeyWindow {
                return window.safeAreaInsets.top
            }
        }
        if let fallback = scenes.first?.windows.first {
            return fallback.safeAreaInsets.top
        }
        return fallbackTopSafeAreaInset
    }

    /// Use the measured inset when it is valid; otherwise fall back to the
    /// app's current window chrome. This keeps background underlap possible
    /// while guaranteeing the foreground still sees a non-zero top band.
    static func resolvedTopSafeAreaInset(
        reportedTopSafeAreaInset: CGFloat,
        windowTopSafeAreaInset: CGFloat? = nil
    ) -> CGFloat {
        max(
            reportedTopSafeAreaInset,
            windowTopSafeAreaInset ?? currentTopSafeAreaInset
        )
    }

    /// Status bar / Dynamic Island + the inline nav bar band below it.
    static func inlineTitleRegionBottom(
        reportedTopSafeAreaInset: CGFloat,
        windowTopSafeAreaInset: CGFloat? = nil
    ) -> CGFloat {
        resolvedTopSafeAreaInset(
            reportedTopSafeAreaInset: reportedTopSafeAreaInset,
            windowTopSafeAreaInset: windowTopSafeAreaInset
        ) + inlineNavigationBarHeight
    }
}
