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
            Label("Микс по треку", systemImage: "dot.radiowaves.up.forward")
        }
        Button {
            Task { await environment.previewSnippet(track) }
        } label: {
            Label("Сниппет", systemImage: "waveform")
        }
        if includeDislike {
            Button(role: .destructive) {
                environment.dislike(track, includeArtist: false)
            } label: {
                Label("Не нравится", systemImage: "hand.thumbsdown")
            }
            Button(role: .destructive) {
                environment.dislike(track, includeArtist: true)
            } label: {
                Label(
                    "Скрыть исполнителя в миксах",
                    systemImage: "person.badge.minus"
                )
            }
        }
    }
}
