import SwiftUI

/// How custom chrome reacts to Increase Contrast and Reduce Transparency.
///
/// System bars adapt on their own. Hand-rolled Liquid Glass does not, so
/// the custom surfaces have to flatten to an opaque fill and a harder
/// stroke — the same thing the system does to tab bars and toolbars when
/// those settings are on.
enum ContrastPolicy {
    static func flattensCustomGlass(
        reduceTransparency: Bool,
        increaseContrast: Bool,
        prefersClassicChrome: Bool
    ) -> Bool {
        reduceTransparency || increaseContrast || prefersClassicChrome
    }

    static func strokeWidth(increased: Bool) -> CGFloat {
        increased ? 1.2 : 0.8
    }

    static func strokeOpacity(
        increased: Bool,
        reduceTransparency: Bool,
        base: Double = 0.11
    ) -> Double {
        if increased {
            return 0.22
        }
        if reduceTransparency {
            return 0.18
        }
        return base
    }
}

enum PlaybackDockMetrics {
    static func tabRowMinHeight(isAccessibilitySize: Bool) -> CGFloat {
        isAccessibilitySize ? 68 : BubbleMetrics.minimumTapTarget + 4
    }

    static func searchControlSize(isAccessibilitySize: Bool) -> CGFloat {
        isAccessibilitySize ? 64 : 58
    }
}

enum PlayerAccessibilityPolicy {
    /// 0 at standard sizes, 1...5 across the accessibility Dynamic Type
    /// steps. Layout uses this to grow metadata/progress, not just a bool.
    static func step(for size: DynamicTypeSize) -> Int {
        switch size {
        case .accessibility1: 1
        case .accessibility2: 2
        case .accessibility3: 3
        case .accessibility4: 4
        case .accessibility5: 5
        default: 0
        }
    }
}
