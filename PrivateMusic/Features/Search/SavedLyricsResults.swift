import SwiftUI

struct SavedLyricsResults: View {
    let records: [SavedLyricsRecord]
    var query: String = ""
    let resolve: (Track) -> Track
    @State private var selectedRecord: SavedLyricsRecord?

    var body: some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                PremiumSectionHeader("search.saved_lyrics", subtitle: "search.saved_lyrics_hint")
                AppGroupedSurface(isLazy: true) {
                    ForEach(records) { record in
                        let track = resolve(record.track)
                        TrackRow(track: track, queue: records.map { resolve($0.track) })
                        Button {
                            selectedRecord = record
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "text.alignleft")
                                    .foregroundStyle(.tint)
                                Text(excerpt(from: record.lyrics))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("lyrics"))
                        .accessibilityValue(excerpt(from: record.lyrics))
                        .padding(.bottom, 8)
                    }
                }
            }
            .padding(.horizontal, PremiumLayout.screenPadding)
            .padding(.bottom, 16)
            .sheet(item: $selectedRecord) { record in
                LyricsView(track: resolve(record.track), initialLyrics: record.lyrics)
            }
        }
    }

    private func excerpt(from lyrics: Lyrics) -> String {
        let lines = lyrics.text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return lines.first { line in
            words.contains { line.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        } ?? lines.first ?? L10n.text("lyrics")
    }
}
