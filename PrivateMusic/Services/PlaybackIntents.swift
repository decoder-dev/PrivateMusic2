import AppIntents

/// Siri, Shortcuts and Spotlight actions. `AudioPlaybackIntent` runs inside
/// the app process, so the music keeps playing without opening the UI.
private enum PlaybackIntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case signedOut

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: "intent.app_not_ready"
        case .signedOut: "intent.sign_in_required"
        }
    }
}

@MainActor
private func playbackEnvironment(requiresSession: Bool = false) async throws -> AppEnvironment {
    // The intent can arrive before the app has built its environment.
    for _ in 0..<40 {
        if let environment = AppEnvironment.current {
            if requiresSession, environment.sessionStore.accessToken == nil {
                throw PlaybackIntentFailure.signedOut
            }
            return environment
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
    throw PlaybackIntentFailure.appNotReady
}

struct PlayMyMixIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "intent.play_my_mix"
    static let description = IntentDescription("intent.play_my_mix.description")

    @MainActor
    func perform() async throws -> some IntentResult {
        let environment = try await playbackEnvironment(requiresSession: true)
        await environment.startPersonalStation(
            in: environment.homeCatalogStore.mixes
        )
        return .result()
    }
}

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "intent.toggle_playback"
    static let description = IntentDescription("intent.toggle_playback.description")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await playbackEnvironment().player.playPause()
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "intent.next_track"
    static let description = IntentDescription("intent.next_track.description")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await playbackEnvironment().player.next()
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "intent.previous_track"
    static let description = IntentDescription("intent.previous_track.description")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await playbackEnvironment().player.previous()
        return .result()
    }
}

struct PrivateMusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMyMixIntent(),
            phrases: [
                "Play my mix in \(.applicationName)",
                "Play \(.applicationName)"
            ],
            shortTitle: "intent.play_my_mix",
            systemImageName: "play.circle.fill"
        )
        AppShortcut(
            intent: TogglePlaybackIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Resume \(.applicationName)"
            ],
            shortTitle: "intent.toggle_playback",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: ["Next track in \(.applicationName)"],
            shortTitle: "intent.next_track",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: PreviousTrackIntent(),
            phrases: ["Previous track in \(.applicationName)"],
            shortTitle: "intent.previous_track",
            systemImageName: "backward.fill"
        )
    }
}
