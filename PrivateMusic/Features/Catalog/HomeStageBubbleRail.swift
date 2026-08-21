import SwiftUI

/// Horizontal context shortcuts under the Home hero. Tint resolution bumps
/// `BubbleTintCache.revision` — keeping the rail in its own view stops
/// that work from invalidating the chip, headline, and transport row.
struct HomeStageBubbleRail: View {
    @Environment(HomeCatalogStore.self) private var homeCatalog
    @Environment(ListeningHistoryStore.self) private var history
    @Environment(PlaybackHighlightModel.self) private var highlight
    @Environment(AppSettings.self) private var settings

    @State private var tintCache = BubbleTintCache.shared

    let width: CGFloat
    let horizontalPadding: CGFloat
    let startingContextID: String?
    let onStart: (HomeStageContext) -> Void

    private var contexts: [HomeStageContext] {
        HomeStageContextBuilder.resolveRailContexts(
            hasCurrentTrack: highlight.currentTrackID != nil,
            queueSource: highlight.queueSource,
            currentArtist: highlight.currentArtist,
            mixes: homeCatalog.mixes,
            historyEntries: history.entries,
            selectedMood: settings.mixMoodPreference,
            stationTitle: L10n.text("selena.name")
        )
    }

    var body: some View {
        if contexts.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .center, spacing: BubbleSpacing.m) {
                    ForEach(contexts) { context in
                        bubble(context)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.leading, horizontalPadding, for: .scrollContent)
            .contentMargins(
                .trailing,
                horizontalPadding + BubbleMetrics.railTrailingInset(for: width),
                for: .scrollContent
            )
            .frame(height: HomeStageMetrics.railHeight(for: width))
            .padding(.bottom, HomeStageMetrics.railShadowPadding)
            .padding(.horizontal, -horizontalPadding)
        }
    }

    private func bubble(_ context: HomeStageContext) -> some View {
        let tileHeight = HomeStageMetrics.railHeight(for: width)
        let tileWidth = BubbleMetrics.contextTileWidth(
            for: width,
            priority: context.priority
        )
        let glyphSize = BubbleMetrics.contextGlyphSize(for: tileHeight)
        let shape = RoundedRectangle(
            cornerRadius: BubbleRadius.contextTile,
            style: .continuous
        )
        let _ = tintCache.revision
        let fill = BubblePalette.surface(
            context.kind.role,
            tint: tintCache.cached(for: context.avatarURL)
        )
        return Button {
            onStart(context)
        } label: {
            HStack(spacing: BubbleSpacing.s) {
                bubbleGlyph(context, size: glyphSize)
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.kind.kicker)
                        .font(BubbleType.bubbleKicker)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    Text(context.displayName)
                        .font(BubbleType.bubbleTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.88)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BubbleSpacing.m)
            .frame(width: tileWidth, height: tileHeight, alignment: .leading)
            .bubbleSurface(shape, fill: .solid(fill), elevation: .resting)
            .overlay {
                if startingContextID == context.id {
                    ZStack {
                        shape.fill(.black.opacity(0.28))
                        ProgressView().tint(.white)
                    }
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(BubblePressStyle())
        .frame(minHeight: BubbleMetrics.minimumTapTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(context.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func bubbleGlyph(
        _ context: HomeStageContext,
        size: CGFloat
    ) -> some View {
        if let avatarURL = context.avatarURL {
            CachedRemoteImage(url: avatarURL, maxPixelSize: size * 3) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                glyphFallback(context, size: size)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay { Circle().stroke(.white.opacity(0.18), lineWidth: 1) }
        } else {
            glyphFallback(context, size: size)
        }
    }

    private func glyphFallback(
        _ context: HomeStageContext,
        size: CGFloat
    ) -> some View {
        Image(systemName: context.kind.symbol)
            .font(.system(size: size * 0.6, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: size, height: size)
    }
}
