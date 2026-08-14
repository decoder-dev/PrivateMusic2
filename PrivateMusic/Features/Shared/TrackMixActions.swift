import SwiftUI

/// Shared mix actions used from TrackRow, home cards, and the player sheet.
enum TrackMixActions {
    @MainActor @ViewBuilder
    static func menuButtons(
        for track: Track,
        environment: AppEnvironment,
        includeDislike: Bool = true
    ) -> some View {
        Button {
            Task { await environment.startMixFromTrack(track) }
        } label: {
            Label(L10n.text("mix_from_track"), systemImage: "dot.radiowaves.up.forward")
        }
        Button {
            Task { await environment.previewSnippet(track) }
        } label: {
            Label(L10n.text("snippet"), systemImage: "waveform")
        }
        if includeDislike {
            Button(role: .destructive) {
                environment.dislike(track, includeArtist: false)
            } label: {
                Label(L10n.text("dislike"), systemImage: "hand.thumbsdown")
            }
            Button(role: .destructive) {
                environment.dislike(track, includeArtist: true)
            } label: {
                Label(L10n.text("hide_artist_in_mixes"),
                    systemImage: "person.badge.minus"
                )
            }
        }
    }
}
