import SwiftUI

/// The one chip style Explore uses for moods, artists and mix tuning —
/// a soft tinted capsule, icon in the tint and text in the primary colour
/// so it keeps its contrast on every accent and in both appearances.
struct ExploreChip: View {
    @Environment(AppSettings.self) private var settings
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
                .frame(width: 18, height: 18)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if isFlexible { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 14)
            .frame(
                maxWidth: isFlexible ? .infinity : nil,
                minHeight: PremiumLayout.minimumTapTarget
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
    var tint: Color {
        switch self {
        case .any: .gray
        case .energetic: .orange
        case .calm: .teal
        case .sad: .indigo
        case .joyful: .yellow
        case .love: .pink
        }
    }
}
