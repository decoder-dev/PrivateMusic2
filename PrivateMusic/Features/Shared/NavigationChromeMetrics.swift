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
                // A window that has not been laid out yet reports `0`, which
                // is a missing measurement rather than a real edge-to-edge
                // screen. Taking it at face value collapsed the Hero under
                // the Dynamic Island on the first frame.
                if window.safeAreaInsets.top > 0 {
                    return window.safeAreaInsets.top
                }
            }
        }
        for scene in scenes {
            for window in scene.windows where window.safeAreaInsets.top > 0 {
                return window.safeAreaInsets.top
            }
        }
        return fallbackTopSafeAreaInset
    }

    /// Use the largest *measured* inset available; otherwise fall back to the
    /// app's window chrome. This keeps background underlap possible while
    /// guaranteeing the foreground still sees a non-zero top band.
    ///
    /// Zero is treated as "not measured yet" at every level, not as a real
    /// edge-to-edge screen: a `GeometryReader` under a parent that ignores the
    /// top safe area reports `0`, and so does a window before its first
    /// layout. Taking either literally is what collapsed the Hero under the
    /// Dynamic Island.
    static func resolvedTopSafeAreaInset(
        reportedTopSafeAreaInset: CGFloat,
        windowTopSafeAreaInset: CGFloat? = nil
    ) -> CGFloat {
        let measured = max(
            reportedTopSafeAreaInset,
            windowTopSafeAreaInset ?? currentTopSafeAreaInset
        )
        return measured > 0 ? measured : fallbackTopSafeAreaInset
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
