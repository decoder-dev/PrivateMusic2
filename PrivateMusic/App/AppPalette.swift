import SwiftUI

/// A colour theme for the page and its surfaces, layered on top of the
/// light / dark choice (which keeps driving every structural decision).
/// `banana` is taken from the BananaGram themes (Graphite / Cream); the rest
/// follow the same recipe: a tinted page, a slightly lifted surface and an
/// accent the palette ships with.
enum AppPalette: String, CaseIterable, Identifiable {
    case classic
    case banana
    case midnight
    case forest
    case rose
    case mocha

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: L10n.text("palette.classic")
        case .banana: L10n.text("palette.banana")
        case .midnight: L10n.text("palette.midnight")
        case .forest: L10n.text("palette.forest")
        case .rose: L10n.text("palette.rose")
        case .mocha: L10n.text("palette.mocha")
        }
    }

    /// The accent applied together with the palette. The listener can still
    /// pick another one afterwards.
    var accent: AppAccent {
        switch self {
        case .classic: .blue
        case .banana: .banana
        case .midnight: .indigo
        case .forest: .green
        case .rose: .pink
        case .mocha: .orange
        }
    }

    /// Top and bottom stops of the page gradient.
    func background(for theme: AppTheme) -> [BubbleColorComponents] {
        let dark = theme == .dark
        switch self {
        case .classic:
            return dark
                ? [Self.gray(0), Self.gray(0.055)]
                : [Self.gray(1), Self.gray(0.965)]
        case .banana:
            return dark
                ? [Self.rgb(0x181B20), Self.rgb(0x14171B)]
                : [Self.rgb(0xF6F3EB), Self.rgb(0xF1EDE2)]
        case .midnight:
            return dark
                ? [Self.rgb(0x0B1020), Self.rgb(0x090D1A)]
                : [Self.rgb(0xEEF2FA), Self.rgb(0xE6ECF8)]
        case .forest:
            return dark
                ? [Self.rgb(0x0D1511), Self.rgb(0x0A110D)]
                : [Self.rgb(0xEEF4EE), Self.rgb(0xE5EFE6)]
        case .rose:
            return dark
                ? [Self.rgb(0x1A1115), Self.rgb(0x140C10)]
                : [Self.rgb(0xFBF1F3), Self.rgb(0xF7E8EC)]
        case .mocha:
            return dark
                ? [Self.rgb(0x19130F), Self.rgb(0x130E0B)]
                : [Self.rgb(0xF4ECE4), Self.rgb(0xEDE2D7)]
        }
    }

    /// Cards, fields and covers' placeholders sit on this.
    func surface(for theme: AppTheme) -> BubbleColorComponents {
        let dark = theme == .dark
        switch self {
        case .classic: return dark ? Self.gray(0.075) : Self.gray(0.955)
        case .banana: return dark ? Self.rgb(0x23272E) : Self.rgb(0xFFFCF5)
        case .midnight: return dark ? Self.rgb(0x141B33) : Self.rgb(0xFFFFFF)
        case .forest: return dark ? Self.rgb(0x16221B) : Self.rgb(0xFBFFFB)
        case .rose: return dark ? Self.rgb(0x261A20) : Self.rgb(0xFFFAFB)
        case .mocha: return dark ? Self.rgb(0x251C16) : Self.rgb(0xFFF9F2)
        }
    }

    /// Luminances an accent has to stand out from: the page and the surface.
    func luminances(for theme: AppTheme) -> [Double] {
        (background(for: theme) + [surface(for: theme)]).map(\.relativeLuminance)
    }

    private static func gray(_ value: Double) -> BubbleColorComponents {
        BubbleColorComponents(red: value, green: value, blue: value)
    }

    private static func rgb(_ hex: UInt32) -> BubbleColorComponents {
        BubbleColorComponents(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum ContrastRatio {
    static func between(_ lhs: Double, _ rhs: Double) -> Double {
        (max(lhs, rhs) + 0.05) / (min(lhs, rhs) + 0.05)
    }
}

extension BubbleColorComponents {
    func mixed(towardWhite: Bool, amount: Double) -> BubbleColorComponents {
        let target = towardWhite ? 1.0 : 0.0
        return BubbleColorComponents(
            red: red + (target - red) * amount,
            green: green + (target - green) * amount,
            blue: blue + (target - blue) * amount
        )
    }

    /// Nudges the colour toward white (dark pages) or black (light pages)
    /// until it reads at `minimum`:1 on every given background luminance.
    func ensuringContrast(
        against backgrounds: [Double],
        minimum: Double = 4.5,
        towardWhite: Bool
    ) -> BubbleColorComponents {
        var result = self
        // Small steps: a colour that is nearly there should barely move.
        for _ in 0..<120 {
            let worst = backgrounds
                .map { ContrastRatio.between(result.relativeLuminance, $0) }
                .min() ?? minimum
            if worst >= minimum { break }
            result = result.mixed(towardWhite: towardWhite, amount: 0.02)
        }
        return result
    }
}
