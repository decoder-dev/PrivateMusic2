import SwiftUI
import UIKit
import WidgetKit
import XCTest
@testable import PrivateMusic

/// Render the real SwiftUI components on the CI simulator. Attachments are
/// review evidence, not an assertion that visual quality can be automated.
@MainActor
final class DesignSnapshotTests: XCTestCase {
    private var snapshotPlayer: AudioPlayer?
    func testCaptureAppearanceAndCoreComposition() async throws {
        let suite = "DesignSnapshotTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let environment = AppEnvironment(keychain: KeychainStore(service: suite))
        let player = AudioPlayer(settings: settings, historyStore: ListeningHistoryStore(defaults: defaults),
                                 defaults: defaults)
        snapshotPlayer = player
        let track = Track(trackID: 1, ownerID: 1, title: "Тихий вечер", artist: "Private Music",
                          duration: 222, streamURL: nil, artworkURL: nil)
        let record = OfflineTrackRecord(track: track, relativePath: "preview.m4a", storage: .directFile,
                                        retention: .manual, byteCount: 8_000_000,
                                        downloadedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                        lastPlayedAt: Date(timeIntervalSince1970: 1_790_000_000), playCount: 1)
        player.play(track, in: [track], source: .library, allowsContinuation: false)
        player.pause()
        defer { player.stop(); snapshotPlayer = nil }
        let searchModel = SearchViewModel(defaults: defaults, debounceDuration: .zero)
        searchModel.query = "Вечер"
        searchModel.submit { _, _, _ in MusicPage(items: [track], totalCount: 1, nextOffset: nil) }
        for _ in 0..<200 where searchModel.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(searchModel.state, .results)
        let lyricSearchModel = SearchViewModel(defaults: defaults, debounceDuration: .zero)
        lyricSearchModel.query = "окне"
        lyricSearchModel.submit { _, _, _ in MusicPage(items: [], totalCount: 0, nextOffset: nil) }
        for _ in 0..<200 where lyricSearchModel.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(lyricSearchModel.state, .empty)
        let failedSearchModel = SearchViewModel(defaults: defaults, debounceDuration: .zero)
        failedSearchModel.query = "Вечер"
        failedSearchModel.submit { _, _, _ in throw APIError.timedOut }
        for _ in 0..<200 where failedSearchModel.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(failedSearchModel.failureOffersVPNHelp)
        let album = Album(id: 1, ownerID: 1, title: "Тихий вечер", count: 1, artists: ["Private Music"])
        let playlist = Playlist(id: 1, ownerID: 1, title: "Вечерняя музыка", count: 1)
        let playlistModel = PlaylistLibraryViewModel()
        let libraryPlaylists = [playlist,
            Playlist(id: 2, ownerID: 1, title: "Музыка для долгих вечерних прогулок", count: 42),
            Playlist(id: 1, ownerID: 2, title: "Любимые открытия", count: 18)]
        await playlistModel.load { _ in MusicPage(items: libraryPlaylists, totalCount: 3, nextOffset: nil) }
        for theme in AppTheme.allCases {
            settings.theme = theme
            settings.appearance = theme == .dark ? .dark : .light
            capture(ConnectView(), name: "connect-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { AppearanceSettingsView() },
                    name: "appearance-\(theme.rawValue)", environment: environment, settings: settings)
            capture(homeComposition(width: 390), name: "home-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(discoveryPreview(track), name: "discovery-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(discoveryPreview(track), name: "discovery-full-\(theme.rawValue)",
                    width: 390, height: 1500, environment: environment, settings: settings)
            capture(widgetPreview(), name: "recent-widget-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(SavedLyricsResults(records: [SavedLyricsRecord(track: track,
                    lyrics: Lyrics(text: "Свет в окне", source: "LRCLIB"))], resolve: { $0 }),
                    name: "lyrics-search-\(theme.rawValue)", environment: environment, settings: settings)
            capture(PlayerView(), name: "player-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(LyricsView(track: track, initialLyrics: Lyrics(
                text: "Тихий вечер\nСвет в окне\nМузыка остаётся со мной", source: "Genius",
                sourceURL: URL(string: "https://genius.com/Private-music-evening-lyrics")
            )), name: "lyrics-\(theme.rawValue)", environment: environment, settings: settings)
            capture(QueueView(), name: "queue-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(actionsPreview(track), name: "track-actions-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(loadingComposition(width: 390).environment(\.scenePhase, .inactive),
                    name: "loading-\(theme.rawValue)", environment: environment, settings: settings)
            capture(NavigationStack { SettingsView() }, name: "settings-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { EqualizerSettingsView() }, name: "equalizer-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { VKIntegrationSettingsView() }, name: "vk-settings-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(PlaylistEditorView(playlist: nil, onSaved: {}), name: "playlist-editor-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(AudioUploadView(onUploaded: {}), name: "audio-upload-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(MixConfigureSheet(), name: "mix-configure-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { ListeningHistoryView() }, name: "history-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { SearchView(isActive: false, model: searchModel) }, name: "search-results-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { SearchView(isActive: false) }, name: "search-landing-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { LibraryView() }, name: "library-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { HomeQuickAccessView().padding(16) }, name: "quick-access-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { HomeQuickAccessView().padding(16).environment(\.dynamicTypeSize, .accessibility3) },
                    name: "quick-access-AX-\(theme.rawValue)", width: 320, environment: environment, settings: settings)
            capture(NavigationStack { LibraryView(section: .albums) }, name: "library-albums-\(theme.rawValue)",
                    environment: environment, settings: settings)
            defaults.set(true, forKey: "library.collectionGrid")
            capture(NavigationStack { LibraryView(section: .playlists, playlistModel: playlistModel) }.defaultAppStorage(defaults),
                    name: "library-grid-\(theme.rawValue)", width: 320, environment: environment, settings: settings)
            defaults.set(false, forKey: "library.collectionGrid")
            capture(NavigationStack { LibraryView(section: .playlists, playlistModel: playlistModel) }.defaultAppStorage(defaults),
                    name: "library-list-\(theme.rawValue)", environment: environment, settings: settings)
            defaults.set(true, forKey: "library.collectionGrid")
            capture(NavigationStack { LibraryView(section: .playlists, playlistModel: playlistModel) }
                    .defaultAppStorage(defaults).environment(\.dynamicTypeSize, .accessibility3),
                    name: "library-collections-AX-\(theme.rawValue)", width: 320, environment: environment, settings: settings)
            capture(NavigationStack { AlbumDetailView(album: album, loadedTracks: [track]) }, name: "album-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { ArtistView(artist: "Private Music") }, name: "artist-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { PlaylistDetailView(playlist: playlist, loadedTracks: [track]) }, name: "playlist-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { ProfileView() }, name: "profile-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { FriendsMusicView() }, name: "friends-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { OfflineDownloadsView() }, name: "downloads-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { NewReleasesView(albums: [album]) }, name: "new-releases-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(AddToPlaylistView(track: track), name: "add-to-playlist-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { PlayerAudioSettingsView() }, name: "audio-settings-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { OfflineStorageSettingsView() }, name: "storage-settings-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { SleepTimerSettingsView() }, name: "sleep-timer-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { ConnectionSettingsView() }, name: "connection-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { MixFiltersSettingsView() }, name: "mix-filters-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { MixFeedbackManagerView() }, name: "mix-feedback-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { DeveloperSettingsView() }, name: "developer-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(MixTuningSheet(mix: MusicMix(id: "common", title: "Selena", subtitle: "", artworkURL: nil), onPlay: { _ in }), name: "mix-tuning-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(VPNWarningCard(retry: {}), name: "vpn-warning-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(VPNInstructionsView(), name: "vpn-instructions-\(theme.rawValue)",
                    environment: environment, settings: settings)
            capture(NavigationStack { SearchView(isActive: false, model: failedSearchModel) },
                    name: "search-connection-failure-\(theme.rawValue)", environment: environment, settings: settings)
            capture(ConnectionBanner(icon: "exclamationmark.circle.fill",
                    message: "vk_rejected_the_saved_sign_in_connect_your_account_again",
                    tint: BubbleGamut.warning.color, retry: {}, actionTitle: "connect_vk"),
                    name: "session-warning-\(theme.rawValue)", environment: environment, settings: settings)
            environment.savedLyricsStore.configure(accountID: 1)
            environment.savedLyricsStore.save(Lyrics(text: "Свет в окне", source: "LRCLIB"), for: track)
            capture(NavigationStack { SearchView(isActive: false, model: lyricSearchModel) },
                    name: "search-lyrics-only-\(theme.rawValue)", environment: environment, settings: settings)
            environment.savedLyricsStore.configure(accountID: nil)
            capture(DownloadedTrackDetailsView(record: record, localURL: nil,
                                               onPlay: {}, onShare: {}, onDelete: {}),
                    name: "download-details-\(theme.rawValue)", environment: environment, settings: settings)
        }
        settings.classicChrome = true
        capture(NavigationStack { AlbumDetailView(album: album, loadedTracks: [track]) }, name: "album-classic",
                width: 320, height: 700, environment: environment, settings: settings)
        capture(NavigationStack { PlaylistDetailView(playlist: playlist, loadedTracks: [track]) }, name: "playlist-classic",
                width: 320, height: 700, environment: environment, settings: settings)
        settings.classicChrome = false
        capture(NavigationStack { AlbumDetailView(album: album, loadedTracks: [track]) }.dynamicTypeSize(.accessibility3),
                name: "album-accessibility", width: 320, height: 1000, environment: environment, settings: settings)
        capture(NavigationStack { PlaylistDetailView(playlist: playlist, loadedTracks: [track]) }.dynamicTypeSize(.accessibility3),
                name: "playlist-accessibility", width: 320, height: 1000, environment: environment, settings: settings)
        capture(discoveryPreview(track, width: 320), name: "discovery-compact", width: 320, height: 900,
                environment: environment, settings: settings)
        capture(discoveryPreview(track, width: 320).dynamicTypeSize(.accessibility3),
                name: "discovery-accessibility", width: 320, height: 1500,
                environment: environment, settings: settings)
        capture(PlaylistEditorView(playlist: nil, onSaved: {}), name: "playlist-editor-ipad",
                width: 768, height: 1024, environment: environment, settings: settings)
        capture(AudioUploadView(onUploaded: {}), name: "audio-upload-ipad",
                width: 768, height: 1024, environment: environment, settings: settings)
        capture(NavigationStack { PlayerAudioSettingsView() }, name: "audio-settings-ipad",
                width: 768, height: 1024, environment: environment, settings: settings)
        capture(NavigationStack { OfflineStorageSettingsView() }, name: "storage-settings-ipad",
                width: 768, height: 1024, environment: environment, settings: settings)
        capture(NavigationStack { SearchView(isActive: false, model: searchModel) }.dynamicTypeSize(.accessibility3),
                name: "search-results-accessibility", width: 320, height: 600,
                environment: environment, settings: settings)
        capture(VPNWarningCard(retry: {}).dynamicTypeSize(.accessibility3), name: "vpn-warning-accessibility",
                width: 320, height: 700, environment: environment, settings: settings)
        capture(VPNInstructionsView().dynamicTypeSize(.accessibility3), name: "vpn-instructions-accessibility",
                width: 320, height: 1000, environment: environment, settings: settings)
        capture(NavigationStack { ProfileView() }, name: "profile-compact",
                width: 320, height: 900, environment: environment, settings: settings)
        capture(NavigationStack { ProfileView() }.dynamicTypeSize(.accessibility3), name: "profile-accessibility",
                width: 320, height: 1600, environment: environment, settings: settings)
        capture(ConnectionBanner(icon: "exclamationmark.circle.fill",
                message: "vk_rejected_the_saved_sign_in_connect_your_account_again",
                tint: BubbleGamut.warning.color, retry: {}, actionTitle: "connect_vk").dynamicTypeSize(.accessibility3),
                name: "session-warning-accessibility", width: 320, height: 700,
                environment: environment, settings: settings)
        capture(NavigationStack { SearchView(isActive: false, model: searchModel) },
                name: "search-results-compact", width: 320, height: 560,
                environment: environment, settings: settings)
        capture(PlayerView(), name: "player-compact", width: 320, height: 700,
                environment: environment, settings: settings)
        capture(actionsPreview(track).dynamicTypeSize(.accessibility3), name: "track-actions-accessibility",
                width: 320, height: 1000, environment: environment, settings: settings)
        capture(loadingComposition(width: 320).dynamicTypeSize(.accessibility3)
                    .environment(\.scenePhase, .inactive), name: "loading-accessibility",
                width: 320, height: 1000, environment: environment, settings: settings)
        settings.theme = .light
        settings.palette = .banana
        settings.accentChoice = .banana
        capture(AudioUploadView(onUploaded: {}), name: "audio-upload-cream",
                environment: environment, settings: settings)
        capture(PlaylistEditorView(playlist: nil, onSaved: {}), name: "playlist-editor-cream",
                environment: environment, settings: settings)
        capture(NavigationStack { PlayerAudioSettingsView() }, name: "audio-settings-cream",
                environment: environment, settings: settings)
        capture(homeComposition(width: 320), name: "home-compact-cream",
                width: 320, height: 700, environment: environment, settings: settings)
        capture(NavigationStack { AppearanceSettingsView() }.dynamicTypeSize(.accessibility3),
                name: "appearance-accessibility", environment: environment, settings: settings)
        capture(PlayerView().dynamicTypeSize(.accessibility3), name: "player-accessibility",
                width: 320, height: 700, environment: environment, settings: settings)
        // A tall capture exposes the complete scrolling composition,
        // including the two-column actions below the first viewport.
        capture(PlayerView().dynamicTypeSize(.accessibility3), name: "player-accessibility-full",
                width: 320, height: 1250, environment: environment, settings: settings)
        capture(AudioUploadView(onUploaded: {}).dynamicTypeSize(.accessibility3),
                name: "audio-upload-accessibility", width: 320, height: 700,
                environment: environment, settings: settings)
        capture(MixConfigureSheet().dynamicTypeSize(.accessibility3), name: "mix-configure-accessibility",
                width: 320, height: 700, environment: environment, settings: settings)
        capture(LyricsView(track: track, initialLyrics: Lyrics(text: "Тихий вечер\nСвет в окне", source: "LRCLIB",
                    lines: [LyricLine(time: 5, text: "Тихий вечер"), LyricLine(time: 15, text: "Свет в окне")]
                )), name: "lyrics-synced", environment: environment, settings: settings)
    }

    private func widgetPreview() -> some View {
        VStack {
            RecentMusicWidgetView(entry: RecentMusicEntry(date: Date(), snapshot: RecentWidgetSnapshot(
                accountID: 1, tracks: [
                    RecentWidgetTrack(id: "1_1", title: "Тихий вечер", artist: "Private Music", artwork: nil),
                    RecentWidgetTrack(id: "1_2", title: "Навстречу солнцу", artist: "Private Music", artwork: nil),
                    RecentWidgetTrack(id: "1_3", title: "Океан", artist: "Private Music", artwork: nil)
                ])), previewFamily: .systemMedium)
                .padding(16)
                .frame(width: 350, height: 180)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            Spacer()
        }.padding(.top, 24).background(ThemeBackground())
    }

    private func discoveryPreview(_ track: Track, width: CGFloat = 390) -> some View {
        NavigationStack {
            MixesHubView(previewMixes: [
                MusicMix(id: "common", title: "Selena", subtitle: "Музыка, которая подходит вам",
                         artworkURL: nil),
                MusicMix(id: "preview-evening", title: "Тихий вечер",
                         subtitle: "Спокойные мелодии", artworkURL: nil)
            ], previewTracks: [track], previewWidth: width)
        }
    }

    private func actionsPreview(_ track: Track) -> some View {
        PlayerActionsSheet(track: track, isInLibrary: false, offlineState: .remote,
                           availability: PlayerActionAvailability(hasSession: true, isUpdatingLibrary: false),
                           equalizerEnabled: .constant(false), spatialAudioEnabled: .constant(false),
                           preferHighQuality: .constant(true), onDismiss: {}, onLibrary: {}, onQueue: {},
                           onArtist: {}, onPlaylist: {}, onShare: {}, onCopyLink: {}, onOffline: {},
                           onSettings: {}, onProcessingRouteHint: {}, onDislikeTrack: {}, onDislikeArtist: {},
                           onMixFromTrack: {}, onSnippet: {}, showsMixFeedback: true, qualityCaption: "HQ")
    }

    private func loadingComposition(width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BubbleSpacing.section) {
                PremiumSectionHeader("library.playlists")
                LoadingShelf(width: width)
                PremiumSectionHeader("library.tracks")
                AppGroupedSurface { LoadingTrackList() }
                HStack(spacing: 20) {
                    PlaybackIndicatorView(isPlaying: true)
                    PlaybackIndicatorView(isPlaying: false)
                }
            }
            .padding(PremiumLayout.screenPadding)
        }
        .background(ThemeBackground())
    }

    private func homeComposition(width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BubbleSpacing.section) {
                HomeQuickAccessView()
                HomeStageView(width: width, horizontalPadding: 16, foregroundTopOrigin: 16)
                PremiumSectionHeader("recently_played")
                AppGroupedSurface {
                    TrackRowContent(artworkURL: nil, title: "Тихий вечер", artist: "Private Music",
                                    showsLikedBadge: false, durationText: "3:42")
                    TrackRowContent(artworkURL: nil, title: "Навстречу солнцу", artist: "Private Music",
                                    showsLikedBadge: false, durationText: "4:16")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(ThemeBackground())
    }

    private func capture<V: View>(
        _ view: V, name: String, width: CGFloat = 390, height: CGFloat = 844,
        environment: AppEnvironment, settings: AppSettings
    ) {
        let player = snapshotPlayer ?? environment.player
        let content = view
            .environment(environment)
            .environment(settings)
            .environment(environment.sessionStore)
            .environment(player)
            .environment(player.highlight)
            .environment(player.progress)
            .environment(environment.libraryStore)
            .environment(environment.likedAlbumsStore)
            .environment(environment.offlineStore)
            .environment(environment.historyStore)
            .environment(environment.homeCatalogStore)
            .environment(environment.networkMonitor)
            .environment(environment.pinnedMixStore)
            .environment(environment.mixFeedbackStore)
            .environment(MainTabScrollCoordinator())
            .environment(\.colorScheme, settings.theme.colorScheme)
            .environment(\.prefersClassicChrome, settings.classicChrome)
            .tint(settings.accent)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            XCTFail("Snapshot requires the test host's window scene")
            return
        }
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        // Let the hosting controller propose its safe-area content size.
        // A fixed full-window SwiftUI frame shifts its bottom controls
        // underneath the home indicator and produces misleading captures.
        let controller = UIHostingController(rootView: content)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = settings.theme == .dark ? .dark : .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 2
        rendererFormat.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: rendererFormat).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        assertVisibleContent(image, name: name)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
        previousWindow?.makeKey()
    }

    private func assertVisibleContent(_ image: UIImage, name: String) {
        guard let cgImage = image.cgImage, cgImage.bitsPerPixel == 32,
              let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            XCTFail("Unreadable snapshot: \(name)")
            return
        }
        var darkest = 765
        var brightest = 0
        for offset in stride(from: 0, to: CFDataGetLength(data) - 3, by: 16) {
            let brightness = Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
            darkest = min(darkest, brightness)
            brightest = max(brightest, brightness)
        }
        XCTAssertGreaterThan(brightest - darkest, 90, "Blank screenshot is not visual evidence: \(name)")
    }
}
