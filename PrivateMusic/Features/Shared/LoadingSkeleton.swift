import SwiftUI

/// Loading uses the same artwork and row rhythm as the finished content.
/// These are native shapes, independent of the reference app's assets.
struct SkeletonBlock: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorSchemeContrast) private var contrast
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var cornerRadius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.primary.opacity(contrast == .increased ? 0.18 : 0.07))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(settings.accent.opacity(0.035))
            }
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

struct LoadingTrackRow: View {
    @ScaledMetric(relativeTo: .callout) private var titleHeight: CGFloat = 14
    @ScaledMetric(relativeTo: .caption) private var subtitleHeight: CGFloat = 11
    var artworkSize: CGFloat = 48

    var body: some View {
        HStack(spacing: BubbleSpacing.m) {
            SkeletonBlock(width: artworkSize, height: artworkSize,
                          cornerRadius: PremiumLayout.artworkRadius(for: artworkSize))
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBlock(height: titleHeight).frame(maxWidth: 190)
                SkeletonBlock(height: subtitleHeight).frame(maxWidth: 120)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 48)
        .padding(.vertical, BubbleSpacing.xs)
    }
}

struct LoadingTrackList: View {
    var count = 5
    var label = "loading_tracks"

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<max(count, 0), id: \.self) { _ in LoadingTrackRow() }
        }
        .skeletonLoading(label: label)
    }
}

struct LoadingShelf: View {
    let width: CGFloat
    var captionHeight: CGFloat = LibraryShelfMetrics.captionHeight
    var label = "loading_playlists"

    var body: some View {
        let cardWidth = LibraryShelfMetrics.cardWidth(for: width)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: LibraryShelfMetrics.cardSpacing) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: LibraryShelfMetrics.captionSpacing) {
                        SkeletonBlock(width: cardWidth, height: cardWidth,
                                      cornerRadius: PremiumLayout.artworkRadius(for: cardWidth))
                        VStack(alignment: .leading, spacing: 7) {
                            SkeletonBlock(width: cardWidth * 0.82)
                            SkeletonBlock(width: cardWidth * 0.55, height: 11)
                        }
                        .frame(height: captionHeight, alignment: .top)
                    }
                    .frame(width: cardWidth)
                }
            }
            .padding(.vertical, LibraryShelfMetrics.shelfPadding)
        }
        .frame(height: LibraryShelfMetrics.shelfHeight(for: width, captionHeight: captionHeight))
        .scrollDisabled(true)
        .skeletonLoading(label: label)
    }
}

private struct SkeletonLoadingModifier: ViewModifier {
    let label: String

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text(label))
    }
}

extension View {
    func skeletonLoading(label: String) -> some View {
        modifier(SkeletonLoadingModifier(label: label))
    }
}
