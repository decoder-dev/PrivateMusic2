import SwiftUI

/// Bubble UI tokens. These extend the existing `PremiumLayout` /
/// `PremiumPressStyle` vocabulary rather than replacing it — the app
/// already has a working surface language and a second parallel framework
/// would only mean two things to keep in sync.
///
/// The system has exactly three tiers, and the tier carries meaning:
///
/// - `hero` — a musical context you can enter (station, artist, mood, mix)
/// - `action` — a verb applied to what is playing (play, like, shuffle)
/// - `glass` — chrome you steer with (navigation, chips, status)
///
/// A reader should be able to learn "big round thing = somewhere to go,
/// small round thing = something to do" without being told.
enum BubbleTier: String, Hashable, Sendable {
    case hero
    case action
    case glass
}

/// One spacing ramp for the whole system. Values off this ramp are the
/// reason a layout drifts into 13 / 17 / 23 pt over time.
enum BubbleSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let section: CGFloat = 32
}

enum BubbleRadius {
    /// Squircle for artwork and cards; circles are handled by `Circle()`.
    static func artwork(for size: CGFloat) -> CGFloat {
        min(28, max(10, size * 0.22))
    }

    static let card = PremiumLayout.cardRadius
    static let compact = PremiumLayout.compactRadius
    /// The context rail's own radius family — a shortcut tile, not a card,
    /// so it doesn't borrow `card`'s meaning.
    static let contextTile: CGFloat = 20
}

/// Weight carries hierarchy; size carries structure. The screens were
/// reading as a wall of bold because every level reached for `.bold`.
enum BubbleType {
    /// Bold, not heavy — heavy read as shouting at every width once the
    /// headline band widened past a phone's largest artist credits.
    static func hero(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }

    static let section = Font.title3.weight(.semibold)
    static let cardTitle = Font.system(size: 18, weight: .semibold)
    static let body = Font.subheadline
    static let metadata = Font.footnote
    static let micro = Font.caption2.weight(.medium)
    /// Status chips: readable at a glance without competing with the
    /// headline above it.
    static let chip = Font.system(size: 13, weight: .medium)
    /// The small label above a hero bubble's name (e.g. "Вайб", "Микс").
    static let bubbleKicker = Font.system(size: 11, weight: .medium)
    /// A hero bubble's own name. Sized to survive a two-line wrap inside a
    /// ~94–128pt circle without either truncating or filling it edge to
    /// edge.
    static let bubbleTitle = Font.system(size: 15, weight: .semibold)
}

/// Motion is short, damped and optional. Nothing in Bubble UI floats on
/// its own: ambient animation on a screen that is always on display is
/// what put this app on the heat-and-battery path once already.
enum BubbleMotion {
    static let pressScale: CGFloat = 0.97

    static var press: Animation {
        .spring(response: 0.22, dampingFraction: 0.86)
    }

    static var state: Animation {
        .spring(response: 0.28, dampingFraction: 0.88)
    }

    /// Returns `nil` under Reduce Motion so callers can pass it straight
    /// into `.animation(_:value:)` without branching at every call site.
    static func state(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : state
    }

    static func press(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : press
    }
}

/// Press feedback for bubbles. Slightly softer than `PremiumPressStyle`
/// because a circle reads a scale change more strongly than a card does.
struct BubblePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                reduceMotion || !configuration.isPressed
                    ? 1
                    : BubbleMotion.pressScale
            )
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(
                BubbleMotion.press(reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}
