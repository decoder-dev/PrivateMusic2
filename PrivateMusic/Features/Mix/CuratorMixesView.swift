import SwiftUI

/// Social / listen-together mixes for one curator already present in catalog.
struct CuratorMixesView: View {
    private enum SortOption: String, CaseIterable, Identifiable {
        case `default`
        case match
        case trackCount

        var id: String { rawValue }

        var title: String {
            switch self {
            case .default: L10n.text("По умолчанию")
            case .match: L10n.text("По совпадению")
            case .trackCount: L10n.text("По числу треков")
            }
        }
    }

    let curator: MixCurator
    let mixes: [MusicMix]
    var trackCache: [String: [Track]] = [:]
    let onPlay: (MusicMix) -> Void

    @State private var sortOption: SortOption = .default

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AsyncArtwork(url: curator.photoURL, size: 56)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(curator.displayName)
                            .font(.headline)
                            .lineLimit(2)
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

            Section {
                Picker(L10n.text("Сортировка"), selection: $sortOption) {
                    ForEach(SortOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .padding(.vertical, 4)
            }

            Section(L10n.text("Слушайте друг друга")) {
                ForEach(sortedMixes) { mix in
                    Button {
                        onPlay(mix)
                    } label: {
                        HStack(spacing: 12) {
                            MixArtworkView(
                                mix: mix,
                                tracks: trackCache[mix.id] ?? [],
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
                                if let info = trackInfo(for: mix) {
                                    Text(info)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
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

    private var sortedMixes: [MusicMix] {
        switch sortOption {
        case .default:
            return mixes
        case .match:
            return mixes.sorted {
                ($0.matchPercent ?? -1) > ($1.matchPercent ?? -1)
            }
        case .trackCount:
            return mixes.sorted {
                (trackCache[$0.id]?.count ?? 0)
                    > (trackCache[$1.id]?.count ?? 0)
            }
        }
    }

    private func trackInfo(for mix: MusicMix) -> String? {
        guard let cached = trackCache[mix.id], !cached.isEmpty else {
            return nil
        }
        let duration = cached.reduce(0) { $0 + max(0, $1.duration) }
        return "\(L10n.trackCount(cached.count)) · \(duration.formattedDuration)"
    }
}
