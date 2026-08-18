import SwiftUI
import UIKit

/// The app's colour vocabulary — every semantic token lives here so context
/// tiles, accents, status colours and theme settings never drift apart.
///
/// **Context legend** (Home rail, mix artwork): four hues spaced ~90° on
/// the wheel at matched luminance — amber station, rose artist, teal mood,
/// violet mix.
///
/// **Interaction**: one accent blue in every theme for CTAs, tabs, hearts,
/// sliders and badges.
///
/// **Status**: success, warning and destructive for meters, banners and
/// swipe actions.
enum BubbleGamut {
    // MARK: - Context legend

    static let station = BubbleColorComponents(
        red: 0.85,
        green: 0.55,
        blue: 0.24
    )
    static let artist = BubbleColorComponents(
        red: 0.82,
        green: 0.38,
        blue: 0.48
    )
    static let mood = BubbleColorComponents(
        red: 0.20,
        green: 0.58,
        blue: 0.50
    )
    static let mix = BubbleColorComponents(
        red: 0.52,
        green: 0.34,
        blue: 0.78
    )

    // MARK: - Interaction

    static let accentDark = BubbleColorComponents(
        red: 0.20,
        green: 0.52,
        blue: 0.98
    )
    static let accentLight = BubbleColorComponents(
        red: 0.10,
        green: 0.42,
        blue: 0.88
    )

    // MARK: - Status & chrome

    static let recommendation = accentDark
    static let neutral = BubbleColorComponents(
        red: 0.34,
        green: 0.36,
        blue: 0.40
    )
    static let success = BubbleColorComponents(
        red: 0.22,
        green: 0.64,
        blue: 0.44
    )
    static let warning = BubbleColorComponents(
        red: 0.94,
        green: 0.62,
        blue: 0.20
    )
    static let destructive = BubbleColorComponents(
        red: 0.84,
        green: 0.32,
        blue: 0.36
    )

    static func accent(for theme: AppTheme) -> BubbleColorComponents {
        theme == .dark ? accentDark : accentLight
    }

    static func accentColor(for theme: AppTheme) -> Color {
        accent(for: theme).color
    }

    /// Liked / saved / in-library — always the accent, never system red on
    /// one screen and theme blue on another.
    static func liked(for theme: AppTheme) -> Color {
        accentColor(for: theme)
    }

    static func components(for role: BubbleRole) -> BubbleColorComponents {
        switch role {
        case .station: station
        case .artist: artist
        case .mood: mood
        case .mix: mix
        case .recommendation: recommendation
        case .neutral: neutral
        case .accent: accentDark
        case .success: success
        case .destructive: destructive
        }
    }
}

extension BubbleColorComponents {
    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: 1)
    }
}
