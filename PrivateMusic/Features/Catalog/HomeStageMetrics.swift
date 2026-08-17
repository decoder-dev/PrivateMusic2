import CoreGraphics

/// Geometry for the Home stage. Resolved up front from the container
/// width, the way the library shelves and the player already do it, so the
/// sizes are checkable and the stage cannot quietly grow past a screen.
///
/// The stage is a hero block on a page, not a second player: its whole job
/// is to fit inside the first viewport with the next shelf already
/// starting to show underneath.
enum HomeStageMetrics {
    /// 34–42 pt. Large enough to carry the screen, small enough that two
    /// lines of a long feature credit still fit above the fold.
    static func headlineSize(for width: CGFloat) -> CGFloat {
        BubbleMetrics.clamp(width * 0.105, minimum: 34, maximum: 42)
    }

    /// 120–145 pt. The artwork anchors the hero; past this it starts
    /// behaving like the full player's.
    static func artworkSize(for width: CGFloat) -> CGFloat {
        BubbleMetrics.clamp(width * 0.34, minimum: 120, maximum: 145)
    }

    static func controlHeight(for width: CGFloat) -> CGFloat {
        BubbleMetrics.clamp(width * 0.135, minimum: 50, maximum: 54)
    }

    static func railHeight(for width: CGFloat) -> CGFloat {
        BubbleMetrics.heroRailHeight(for: width)
    }

    /// Vertical rhythm, straight off the spacing ramp.
    static let chipHeight: CGFloat = 30
    static let belowChip = BubbleSpacing.m
    static let belowHeadline = BubbleSpacing.m
    static let belowArtwork = BubbleSpacing.l - 2
    static let belowTransport = BubbleSpacing.l

    static var fixedSpacing: CGFloat {
        chipHeight + belowChip + belowHeadline + belowArtwork
            + belowTransport
    }

    /// Total height of the stage, so "does it leave room for the next
    /// shelf" is arithmetic instead of a screenshot.
    static func stageHeight(
        for width: CGFloat,
        headlineLines: Int = 1
    ) -> CGFloat {
        headlineSize(for: width) * CGFloat(headlineLines)
            + artworkSize(for: width)
            + controlHeight(for: width)
            + railHeight(for: width)
            + fixedSpacing
    }

    /// The atmosphere fades out level with the transport row, so the hero
    /// dissolves into the page instead of ending on a visible seam and
    /// reading as a separate screen.
    static func atmosphereHeight(for width: CGFloat) -> CGFloat {
        stageHeight(for: width) - railHeight(for: width) * 0.35
    }
}
