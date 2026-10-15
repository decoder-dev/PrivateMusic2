import SwiftUI

struct ArtistHeaderCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let name: String
    let photoURL: URL?
    let subtitle: String
    let playbackAction: QueueSourcePlaybackAction?
    var onPlay: () -> Void = {}
    var onShuffle: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: BubbleSpacing.l) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: BubbleSpacing.m))
                : AnyLayout(HStackLayout(alignment: .center, spacing: BubbleSpacing.l))
            layout {
                ArtistArtwork(name: name, url: photoURL, size: 88)
                VStack(alignment: .leading, spacing: BubbleSpacing.xs) {
                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            let actionLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: BubbleSpacing.s))
                : AnyLayout(HStackLayout(spacing: BubbleSpacing.s))
            actionLayout {
                Button(action: onPlay) {
                    Label(L10n.text(playbackAction == .pause ? "pause" : "listen"),
                          systemImage: (playbackAction ?? .start).systemImage)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(PremiumProminentButtonStyle())
                .disabled(playbackAction == nil)

                Button(action: onShuffle) {
                    if dynamicTypeSize.isAccessibilitySize {
                        Label(L10n.text("shuffle"), systemImage: "shuffle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Image(systemName: "shuffle")
                            .frame(minWidth: PremiumLayout.minimumTapTarget)
                    }
                }
                .buttonStyle(PremiumSecondaryButtonStyle())
                .accessibilityLabel(L10n.text("shuffle"))
                .disabled(playbackAction == nil)
            }
        }
        .padding(PremiumLayout.screenPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }
}
