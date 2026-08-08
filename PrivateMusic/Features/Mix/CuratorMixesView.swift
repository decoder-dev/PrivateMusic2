import SwiftUI

/// Social / listen-together mixes for one curator already present in catalog.
struct CuratorMixesView: View {
    let curator: MixCurator
    let mixes: [MusicMix]
    let onPlay: (MusicMix) -> Void

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AsyncArtwork(url: curator.photoURL, size: 56)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(curator.displayName)
                            .font(.headline)
                        Text(
                            L10n.format(
                                "%d миксов со вкусом",
                                mixes.count
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
            }

            Section(L10n.text("Слушайте друг друга")) {
                ForEach(mixes) { mix in
                    Button {
                        onPlay(mix)
                    } label: {
                        HStack(spacing: 12) {
                            MixArtworkView(
                                mix: mix,
                                tracks: [],
                                size: 48
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mix.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                if let percent = mix.matchPercent {
                                    Text(
                                        L10n.format(
                                            "совпадение %d%%",
                                            percent
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                } else if !mix.subtitle.isEmpty {
                                    Text(mix.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "play.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle(curator.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
