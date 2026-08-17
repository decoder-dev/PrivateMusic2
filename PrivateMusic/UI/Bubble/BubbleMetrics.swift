import CoreGraphics

/// How prominent a hero bubble is. Size follows meaning, not position:
/// sizing by `index % 4` made the rail look hand-placed but told the
/// listener nothing, and re-ordering the data silently re-sized it.
enum BubblePriority: Int, Hashable, Sendable, CaseIterable {
    case primary
    case secondary
    case tertiary

    var scale: CGFloat {
        switch self {
        case .primary: 1
        case .secondary: 0.9
        case .tertiary: 0.82
        }
    }
}

/// Sizing for the three tiers. Pure arithmetic, so the "does the hero fit
/// on an SE" question is a test rather than a screenshot.
enum BubbleMetrics {
    /// Everything a finger touches, per HIG and §33.
    static let minimumTapTarget: CGFloat = PremiumLayout.minimumTapTarget

    // MARK: - Context tile

    /// A contextual shortcut — station, mood, artist, mix — not a second
    /// hero. A literal 118–128pt circle read as competing with the artwork
    /// above it; a compact tile reads as a shortcut you can glance past.
    /// Height stays uniform across the rail so it scans as one row; width
    /// is what carries priority, and only subtly.
    static func contextTileHeight(for width: CGFloat) -> CGFloat {
        clamp(width * 0.205, minimum: 72, maximum: 88)
    }

    static func contextTileWidth(
        for width: CGFloat,
        priority: BubblePriority = .primary
    ) -> CGFloat {
        let base = clamp(width * 0.37, minimum: 120, maximum: 155)
        return (base * priority.scale).rounded()
    }

    /// The icon/avatar inside a context tile.
    static func contextGlyphSize(for tileHeight: CGFloat) -> CGFloat {
        (tileHeight * 0.36).rounded()
    }

    // MARK: - Action

    /// Play/pause and friends. Bounded at both ends: 44 is the floor a
    /// finger needs, 64 is where a control starts competing with the
    /// artwork for attention.
    static func action(for width: CGFloat, prominent: Bool = false) -> CGFloat {
        let fraction = prominent ? 0.126 : 0.118
        let ceiling: CGFloat = prominent ? 52 : 50
        return clamp(
            width * fraction,
            minimum: minimumTapTarget,
            maximum: ceiling
        )
    }

    // MARK: - Glass

    static func chipHeight(for width: CGFloat) -> CGFloat {
        clamp(width * 0.085, minimum: 30, maximum: 36)
    }

    // MARK: - Rails

    /// A rail is exactly as tall as its tiles. Nothing is clipped
    /// vertically — a previous rail shrank its own frame to fake bubbles
    /// rising off the bottom edge, which read as a layout bug on a real
    /// device.
    static func heroRailHeight(for width: CGFloat) -> CGFloat {
        contextTileHeight(for: width)
    }

    /// Enough trailing room that the last bubble clears the screen edge
    /// instead of resting against it.
    static func railTrailingInset(for width: CGFloat) -> CGFloat {
        clamp(width * 0.12, minimum: 24, maximum: 56)
    }

    static func clamp(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}

/// One place that answers "how much room does the floating chrome need at
/// the bottom of a scroll view". Screens were each guessing, which is how
/// the first shelf ended up under the dock.
enum BottomAccessoryMetrics {
    /// The dock measures itself and publishes its height; this is only the
    /// floor used before that measurement lands, so content never starts
    /// out underneath it on first paint.
    static let estimatedDockHeight: CGFloat = 74
    /// Matches MiniPlayerLayoutMetrics.minHeight (58) plus a hairline of
    /// rounding slack, so the estimate still clears the real bar.
    static let estimatedMiniPlayerHeight: CGFloat = 59

    /// Breathing room between the last row of content and the chrome.
    static let contentClearance: CGFloat = BubbleSpacing.l

    static func inset(
        measuredDockHeight: CGFloat,
        hasMiniPlayer: Bool
    ) -> CGFloat {
        let dock = measuredDockHeight > 0
            ? measuredDockHeight
            : estimatedDockHeight
                + (hasMiniPlayer ? estimatedMiniPlayerHeight : 0)
        return dock + contentClearance
    }
}
