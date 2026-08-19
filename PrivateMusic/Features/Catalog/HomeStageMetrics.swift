import CoreGraphics

/// Geometry for the Home stage. Resolved up front from the container
/// width, the way the library shelves and the player already do it, so the
/// sizes are checkable and the stage cannot quietly grow past a screen.
///
/// The stage is a hero block on a page, not a second player: its whole job
/// is to fit inside the first viewport with the next shelf already
/// starting to show underneath.
enum HomeStageMetrics {
    /// Clear breathing room between the compact navigation title band and the
    /// first Hero foreground element. Applied through the resolved foreground
    /// origin, not as an extra independent padding layer.
    static let navigationGap = BubbleSpacing.l

    /// Home underlaps the top chrome with the atmospheric background, but its
    /// foreground must still start below the effective navigation/header
    /// boundary plus one consistent breathing gap. On some hierarchies the
    /// stage's `GeometryReader` can report zero after the parent ignores the
    /// top safe area; in that case fall back to the window's current top inset
    /// rather than collapsing the hero upward.
    ///
    /// The boundary is the *bottom of the inline title band*, not the safe
    /// area alone: Home carries a `.inline` navigation title, so clearing
    /// only the status bar left the status chip sitting underneath
    /// "Главная" instead of below it.
    @MainActor
    static func resolvedForegroundTopOrigin(
        reportedTopSafeAreaInset: CGFloat,
        windowTopSafeAreaInset: CGFloat? = nil
    ) -> CGFloat {
        NavigationChromeMetrics.inlineTitleRegionBottom(
            reportedTopSafeAreaInset: reportedTopSafeAreaInset,
            windowTopSafeAreaInset: windowTopSafeAreaInset
        ) + navigationGap
    }

    /// 32–38 pt, bold. A short name at the top of this band used to read
    /// as shouting; the band leans on two lines and a tighter scale factor
    /// before it ever reaches for a bigger font.
    static func headlineSize(for width: CGFloat) -> CGFloat {
        BubbleMetrics.clamp(width * 0.093, minimum: 32, maximum: 38)
    }

    /// 125–145 pt. The artwork anchors the hero; past this it starts
    /// behaving like the full player's.
    static func artworkSize(for width: CGFloat) -> CGFloat {
        BubbleMetrics.clamp(width * 0.34, minimum: 125, maximum: 145)
    }

    static func controlHeight(for width: CGFloat) -> CGFloat {
        BubbleMetrics.clamp(width * 0.135, minimum: 48, maximum: 52)
    }

    static func railHeight(for width: CGFloat) -> CGFloat {
        BubbleMetrics.heroRailHeight(for: width)
    }

    /// Vertical rhythm, straight off the spacing ramp. The gaps around the
    /// headline and before the rail used to sit under their target bands —
    /// tight enough that the stage read as one dense block rather than
    /// status, artist, artwork and controls as distinct beats.
    /// Default-size floor for the status chip. Large Dynamic Type grows
    /// the chip past this; the stage layout uses `minHeight`, not a pin.
    static let chipHeight: CGFloat = 34
    static let belowChip = BubbleSpacing.xl
    static let belowHeadline = BubbleSpacing.xxl
    static let belowArtwork = BubbleSpacing.xxl
    static let belowTransport = BubbleSpacing.xxl

    static var fixedSpacing: CGFloat {
        chipHeight + belowChip + belowHeadline + belowArtwork
            + belowTransport
    }

    /// Total height of the stage at the default text size, so "does it
    /// leave room for the next shelf" is arithmetic instead of a
    /// screenshot. Large Dynamic Type grows the chip and now-playing
    /// title past the floors below; tests that use this value are
    /// asserting the default-size composition, not the accessibility one.
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
    ///
    /// `topSafeAreaInset` extends the same band up behind the status bar /
    /// nav bar instead of stopping at the safe-area boundary — the stage
    /// used to leave that strip flat black, the one clean seam this hero
    /// was supposed not to have.
    static func atmosphereHeight(
        for width: CGFloat,
        topSafeAreaInset: CGFloat = 0
    ) -> CGFloat {
        stageHeight(for: width) - railHeight(for: width) * 0.35
            + topSafeAreaInset
    }
}
