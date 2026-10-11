import SwiftUI

struct SavedLyricsResults: View {
    let records: [SavedLyricsRecord]
    let resolve: (Track) -> Track

    var body: some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                PremiumSectionHeader("search.saved_lyrics", subtitle: "search.saved_lyrics_hint")
                AppGroupedSurface {
                    ForEach(records) { record in
                        let track = resolve(record.track)
                        TrackRow(track: track, queue: records.map { resolve($0.track) })
                    }
                }
            }
            .padding(.horizontal, PremiumLayout.screenPadding)
            .padding(.bottom, 16)
        }
    }
}
