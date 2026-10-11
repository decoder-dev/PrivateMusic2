import SwiftUI

/// The one chip style Explore uses for moods, artists and mix tuning —
/// a soft tinted capsule, icon in the tint and text in the primary colour
/// so it keeps its contrast on every accent and in both appearances.
struct ExploreChip: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var iconSize: CGFloat = 18
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let title: String
    let systemImage: String
    var tint: Color?
    var isFlexible = false
    /// Shows a spinner in place of the icon and ignores further taps — the
    /// tap started something that takes a moment (loading a mix).
    var isLoading = false
    let action: () -> Void

    var body: some View {
        let color = tint ?? settings.accent
        Button(action: action) {
            HStack(spacing: 7) {
                // Same box either way: swapping the icon for a spinner must
                // not change the chip's width.
                Group {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(color)
                    } else {
                        Image(systemName: systemImage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(color)
                    }
                }
                .frame(width: iconSize, height: iconSize)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : (isFlexible ? 2 : 1))
                    .fixedSize(horizontal: false, vertical: true)
                if isFlexible { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(
                maxWidth: isFlexible ? .infinity : nil,
                minHeight: isFlexible ? 64 : PremiumLayout.minimumTapTarget
            )
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(colorSchemeContrast == .increased ? 0.22 : 0.14))
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        color.opacity(colorSchemeContrast == .increased ? 0.7 : 0.18),
                        lineWidth: colorSchemeContrast == .increased ? 1.5 : 0.75
                    )
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PremiumPressStyle())
        .disabled(isLoading)
        .accessibilityAddTraits(isLoading ? .updatesFrequently : [])
    }
}

extension MixMoodPreference {
    /// One hue per mood, so the strip reads as a palette, not a grey row.
    func tint(for theme: AppTheme, on palette: AppPalette) -> Color {
        let accent: AppAccent
        switch self {
        case .any:
            return BubbleGamut.neutral.ensuringContrast(
                against: palette.luminances(for: theme),
                towardWhite: theme == .dark
            ).color
        case .energetic: accent = .orange
        case .calm: accent = .teal
        case .sad: accent = .indigo
        case .joyful: accent = .banana
        case .love: accent = .pink
        }
        return accent.components(for: theme, on: palette).color
    }
}
