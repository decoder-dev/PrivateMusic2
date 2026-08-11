#!/usr/bin/env python3
from __future__ import annotations

import json
import plistlib
import re
import struct
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "PrivateMusic"


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


swift_files = sorted(SOURCE.rglob("*.swift"))
if len(swift_files) < 20:
    fail(f"expected at least 20 Swift files, found {len(swift_files)}")

required = {
    "PrivateMusic/App/PrivateMusicApp.swift",
    "PrivateMusic/Player/AudioPlayer.swift",
    "PrivateMusic/Player/NowPlayingController.swift",
    "PrivateMusic/Core/Security/KeychainStore.swift",
    "PrivateMusic/Core/Networking/APIClient.swift",
    "PrivateMusic/Services/VKWebAuthService.swift",
    "PrivateMusic/Services/VKAudioURLResolver.swift",
    "PrivateMusic/Services/LRCLyricsService.swift",
    "PrivateMusic/Features/Auth/VKWebLoginView.swift",
    "PrivateMusic/Features/Shared/PremiumDesign.swift",
    "PrivateMusic/Features/Root/RootView.swift",
    "PrivateMusic/Models/OfflineTrackStore.swift",
    "PrivateMusic/Features/Library/OfflineDownloadsView.swift",
    "PrivateMusic/Services/HLSOfflineDownloadService.swift",
}
for relative in required:
    if not (ROOT / relative).is_file():
        fail(f"missing {relative}")

for relative in (
    "PrivateMusic/Services/WatchRemoteCoordinator.swift",
    "PrivateMusic/Shared/WatchRemoteProtocol.swift",
    "PrivateMusicWatch/PrivateMusicWatchApp.swift",
    "PrivateMusicWatch/RemotePlayerView.swift",
    "PrivateMusicWatch/WatchRemoteViewModel.swift",
    "PrivateMusicWatch/Resources/PrivacyInfo.xcprivacy",
    "scripts/fix_watch_embedding.py",
    "scripts/validate_watch_bundle.py",
):
    if not (ROOT / relative).is_file():
        fail(f"missing Watch release file: {relative}")

all_source = "\n".join(path.read_text(encoding="utf-8") for path in swift_files)
audio_player_source = (
    SOURCE / "Player" / "AudioPlayer.swift"
).read_text(encoding="utf-8")
equalizer_source = (
    SOURCE / "Player" / "EqualizerDSP.swift"
).read_text(encoding="utf-8")
spatial_audio_source = (
    SOURCE / "Player" / "SpatialAudioDSP.swift"
).read_text(encoding="utf-8")
player_view_source = (
    SOURCE / "Features" / "Player" / "PlayerView.swift"
).read_text(encoding="utf-8")
root_view_source = (
    SOURCE / "Features" / "Root" / "RootView.swift"
).read_text(encoding="utf-8")
mini_player_source = (
    SOURCE / "Features" / "Player" / "MiniPlayerView.swift"
).read_text(encoding="utf-8")
main_tab_source = (
    SOURCE / "Features" / "Root" / "MainTabView.swift"
).read_text(encoding="utf-8")
search_view_source = (
    SOURCE / "Features" / "Search" / "SearchView.swift"
).read_text(encoding="utf-8")
cached_image_source = (
    SOURCE / "Features" / "Shared" / "CachedRemoteImage.swift"
).read_text(encoding="utf-8")
library_view_source = (
    SOURCE / "Features" / "Library" / "LibraryView.swift"
).read_text(encoding="utf-8")
app_environment_source = (
    SOURCE / "App" / "AppEnvironment.swift"
).read_text(encoding="utf-8")
track_collection_source = (
    SOURCE / "Features" / "Library" / "TrackCollectionViewModel.swift"
).read_text(encoding="utf-8")
mixes_hub_source = (
    SOURCE / "Features" / "Mix" / "MixesHubView.swift"
).read_text(encoding="utf-8")
glass_source = (
    SOURCE / "Features" / "Shared" / "AdaptiveGlass.swift"
).read_text(encoding="utf-8")
for forbidden in (
    "client_secret",
    "hHbZxrka2uZ6jB1inYsH",
    "x-vk-android-client",
    "VKAndroidApp/",
    "window.webkit.messageHandlers",
    "XMLHttpRequest.prototype.send",
):
    if forbidden in all_source:
        fail(f"forbidden sensitive pattern: {forbidden}")

for required_symbol in (
    "MPNowPlayingInfoCenter",
    "MPRemoteCommandCenter",
    "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly",
    "URLSessionConfiguration.ephemeral",
    "MTAudioProcessingTapCreate",
    "glassEffect",
    "decoder-dev",
    "userAgent",
    "WKWebsiteDataStore",
    "https://login.vk.ru/?act=web_token",
    "https://lrclib.net/api/search",
    "accessibilityReduceMotion",
):
    if required_symbol not in all_source:
        fail(f"missing security/player symbol: {required_symbol}")

if "options: [.allowAirPlay, .allowBluetoothA2DP]" in audio_player_source:
    fail("playback audio session must not use incompatible route options")
for required_processing_route_symbol in (
    "enum AudioProcessingRoutePolicy",
    "player.allowsExternalPlayback = AudioProcessingRoutePolicy",
    "shouldResumeAfterMinimumVolumePause",
    "pausedForMinimumVolume = true",
    "minimumVolumeResumeSuppressed",
    "isAudioInterrupted: isAudioInterrupted",
):
    if required_processing_route_symbol not in audio_player_source:
        fail(
            "audio processing must remain active on external output routes: "
            f"{required_processing_route_symbol}"
        )
if "player.allowsExternalPlayback = true" in audio_player_source:
    fail("external AVPlayer handoff must not bypass active audio processing")
if ".preroll(" in audio_player_source:
    fail("track preloading must not use exception-prone AVPlayer preroll")
for forbidden_legacy_all_tabs_symbol in (
    "ForEach(MainTab.allCases",
):
    if forbidden_legacy_all_tabs_symbol in main_tab_source:
        fail("pre-iOS 26 dock must keep search as a separate circular control")
for required_system_tab_symbol in (
    "SystemLiquidGlassTabView",
    "tabViewBottomAccessory",
    "MainTab.search.title",
    "value: MainTab.search",
    "SystemPlaybackAccessory",
):
    if required_system_tab_symbol not in main_tab_source:
        fail(
            "iOS 26+ must use system Liquid Glass TabView like Apple Music: "
            f"{required_system_tab_symbol}"
        )
for forbidden_system_tab_search_chrome in (
    "role: .search",
    "tabViewSearchActivation",
):
    if forbidden_system_tab_search_chrome in main_tab_source:
        fail(
            "iOS 26+ Search must be a regular fifth labeled tab, "
            "not detached search chrome: "
            f"{forbidden_system_tab_search_chrome}"
        )
if ".searchable(" not in search_view_source:
    fail("SearchView must bind system .searchable for the Search tab")
if "SystemSearchTabModifier" not in search_view_source:
    fail("SearchView must apply SystemSearchTabModifier outside ScrollViewReader")
if "isSystemSearchPresented = true" not in search_view_source:
    fail("Search tab activation must present the system search field")
if "func presentQueue()" not in audio_player_source:
    fail("AudioPlayer must expose presentQueue for Mix hub queue button")
if "cancelMixRadioRefill()" not in audio_player_source:
    fail("AudioPlayer must cancel stale mix-radio refill on queue changes")
if "shouldApplyRefill(" not in audio_player_source:
    fail("mix-radio refill must guard against stale async apply")
if "MixRadioUpcomingMergePolicy.merge(" not in audio_player_source:
    fail("replaceUpcoming must preserve Play Next pins during radio refill")
mix_stream_source_path = SOURCE / "Models" / "MixContinuationStream.swift"
if not mix_stream_source_path.is_file():
    fail("mixes and Selena must use stateful continuation cursors")
mix_stream_source = mix_stream_source_path.read_text(encoding="utf-8")
for required_mix_stream_symbol in (
    "actor MixTrackContinuationCursor",
    "nextOffset += MixTrackRequestPolicy.continuationPages",
    "actor SelenaRecommendationCursor",
    "musicService.recommendations(\n                    seededBy: seed",
    "knownIDs.insert($0.id).inserted",
    "commonMixOffset += MixTrackRequestPolicy.pageSize",
):
    if required_mix_stream_symbol not in mix_stream_source:
        fail(
            "infinite mix/Selena continuation invariant is missing: "
            f"{required_mix_stream_symbol}"
        )
for required_mix_hub_stream_symbol in (
    "mixContinuationProvider(",
    "SelenaRecommendationCursor(",
    "MixTrackContinuationCursor(mix: mix)",
):
    if required_mix_hub_stream_symbol not in mixes_hub_source:
        fail(
            "MixesHub must attach infinite continuation providers: "
            f"{required_mix_hub_stream_symbol}"
        )
if "SelenaRecommendationCursor(" not in library_view_source:
    fail("pinned Selena resume must keep the recommendation cursor")
for required_audio_stream_symbol in (
    "ContinuationPrefetchPolicy.shouldPrefetch",
    "guard should else { return }",
    # The near-end refill still sizes itself from the upcoming window (the
    # played history must not eat the budget); the ceiling it subtracts from
    # now depends on the queue source — see LibraryQueuePolicy.
    "upcomingCount: upcomingCount",
):
    if required_audio_stream_symbol not in audio_player_source:
        fail(
            "AudioPlayer must keep continuous near-end refill behavior: "
            f"{required_audio_stream_symbol}"
        )
ru_strings = (
    SOURCE / "Resources" / "ru.lproj" / "Localizable.strings"
).read_text(encoding="utf-8")
en_strings = (
    SOURCE / "Resources" / "en.lproj" / "Localizable.strings"
).read_text(encoding="utf-8")
if "нейросеть Decoder Dev" not in ru_strings:
    fail("Selena Russian copy must brand it as Decoder Dev's neural network")
if "Decoder Dev's neural network" not in en_strings:
    fail("Selena English copy must brand it as Decoder Dev's neural network")
native_dsp_header = SOURCE / "Native" / "PrivateMusicDSP.h"
native_dsp_source = SOURCE / "Native" / "PrivateMusicDSP.c"
native_core_header = SOURCE / "Native" / "PrivateMusicCore.h"
native_core_source = SOURCE / "Native" / "PrivateMusicCore.c"
bridging_header = SOURCE / "Native" / "PrivateMusic-Bridging-Header.h"
if not native_dsp_header.is_file() or not native_dsp_source.is_file():
    fail("PrivateMusicDSP C module (header + source) must exist under Native/")
if not native_core_header.is_file() or not native_core_source.is_file():
    fail("PrivateMusicCore C module (header + source) must exist under Native/")
if not bridging_header.is_file():
    fail("PrivateMusic Native bridging header must exist")
native_dsp_header_text = native_dsp_header.read_text(encoding="utf-8")
for symbol in (
    "pm_eq_process_channel",
    "pm_spatial_widen",
    # Per-buffer entry points: the tap must not walk samples from Swift.
    "pm_biquad_process_channel",
    "pm_spatial_process_planar",
    "pm_spatial_process_interleaved",
):
    if symbol not in native_dsp_header_text:
        fail(f"PrivateMusicDSP.h must expose {symbol}")
native_core_header_text = native_core_header.read_text(encoding="utf-8")
for symbol in (
    "pm_hash_fnv1a64_bytes",
    "pm_hash_fnv1a64_value",
    "pm_text_identity_hash",
    "pm_text_fold_utf8",
    "pm_text_find",
    "pm_mix_select_best",
    "pm_mix_score_candidate",
):
    if symbol not in native_core_header_text:
        fail(f"PrivateMusicCore.h must expose {symbol}")
bridging_header_text = bridging_header.read_text(encoding="utf-8")
for header in ("PrivateMusicDSP.h", "PrivateMusicCore.h"):
    if header not in bridging_header_text:
        fail(f"bridging header must import {header}")
equalizer_source = (SOURCE / "Player" / "EqualizerDSP.swift").read_text(
    encoding="utf-8"
)
if "pm_eq_process_channel(" not in equalizer_source:
    fail("EqualizerDSP must call pm_eq_process_channel for the tap hot path")
if "pm_biquad_process_channel(" not in equalizer_source:
    fail("EqualizerDSP boom cut must run the C per-channel biquad loop")
for symbol in ("pm_spatial_process_planar(", "pm_spatial_process_interleaved("):
    if symbol not in equalizer_source:
        fail(f"EqualizerDSP spatial pass must call {symbol[:-1]}")
if "for frame in 0..<frameCount" in equalizer_source:
    fail(
        "EqualizerDSP must not walk audio frames from Swift: the realtime tap "
        "hot paths live in PrivateMusicDSP.c"
    )
spatial_source = (SOURCE / "Player" / "SpatialAudioDSP.swift").read_text(
    encoding="utf-8"
)
if "pm_spatial_widen(" not in spatial_source:
    fail("SpatialAudioDSP must call pm_spatial_widen")
mix_ranker_source = (SOURCE / "Player" / "MixQueueRanker.swift").read_text(
    encoding="utf-8"
)
if "pm_mix_select_best(" not in mix_ranker_source:
    fail("MixQueueRanker must pick candidates through pm_mix_select_best")
for symbol in ("pm_hash_fnv1a64_bytes(", "pm_text_identity_hash("):
    if symbol not in mix_ranker_source:
        fail(f"MixQueueRanker must hash through {symbol[:-1]}")
native_text_source_path = SOURCE / "Core" / "Text" / "NativeTextSearch.swift"
if not native_text_source_path.is_file():
    fail("NativeTextSearch must live under Core/Text/")
native_text_source = native_text_source_path.read_text(encoding="utf-8")
for symbol in ("pm_text_fold_utf8(", "pm_text_find("):
    if symbol not in native_text_source:
        fail(f"NativeTextSearch must call {symbol[:-1]}")
if "FoldedSearchQuery" not in native_text_source:
    fail("NativeTextSearch must expose FoldedSearchQuery for reused needles")
if "FoldedSearchQuery(" not in search_view_source:
    fail("SearchView playlist filtering must fold the needle once via C")
project_yml = (ROOT / "project.yml").read_text(encoding="utf-8")
if "SWIFT_OBJC_BRIDGING_HEADER: PrivateMusic/Native/PrivateMusic-Bridging-Header.h" not in project_yml:
    fail("project.yml must set SWIFT_OBJC_BRIDGING_HEADER for the C DSP module")
queue_view_source = (SOURCE / "Features/Player/QueueView.swift").read_text(
    encoding="utf-8"
)
if "id: \\.offset" in queue_view_source:
    fail("QueueView must use stable track identity, not list offset")
if "id: \\.element.id" not in queue_view_source:
    fail("QueueView must identify rows by track id")
if "PlaybackAccessoryModifier" not in main_tab_source:
    fail(
        "iOS 26.0 must attach bottom accessory via PlaybackAccessoryModifier "
        "(isEnabled overload is 26.1-only)"
    )
if "if #available(iOS 26.0, *)" not in main_tab_source:
    fail("system Liquid Glass TabView must activate on iOS 26.0, not only 26.1")
if "navigationBarDrawer(displayMode: .always)" not in library_view_source:
    fail(
        "Library searchable must stay in the navigation drawer, "
        "not compete with bottom tab chrome"
    )
shelf_metrics_source = (
    SOURCE / "Features/Library/LibraryShelfMetrics.swift"
).read_text(encoding="utf-8")
for required_shelf_symbol in (
    "enum LibraryShelfMetrics",
    "static let artworkSize",
    "static var shelfHeight",
    "func librarySectionSpacing()",
):
    if required_shelf_symbol not in shelf_metrics_source:
        fail(
            "library shelf geometry must stay resolved up front: "
            f"{required_shelf_symbol}"
        )
for required_shelf_card_symbol in (
    "func playlistCard(",
    "func albumCard(",
    "PlaylistArtworkView(",
    "size: LibraryShelfMetrics.artworkSize",
    ".frame(height: LibraryShelfMetrics.shelfHeight)",
):
    if required_shelf_card_symbol not in library_view_source:
        fail(
            "library shelves must render pinned artwork cards, not text "
            f"chips: {required_shelf_card_symbol}"
        )
if "id: \\.element.libraryIdentity" not in library_view_source:
    fail(
        "playlist shelf must identify cards by owner+id: VK playlist ids "
        "repeat across owners and duplicate ForEach ids break the shelf"
    )
if "LazyVStack(alignment: .leading, spacing: 24)" in library_view_source:
    fail(
        "library track rows share the section LazyVStack, so section "
        "spacing must be per-section padding, not stack spacing"
    )
playlist_model_source = (SOURCE / "Models/Playlist.swift").read_text(
    encoding="utf-8"
)
for required_playlist_identity_symbol in (
    "let playlistID: Int",
    "var id: String { libraryIdentity }",
    'case thumbs',
):
    if required_playlist_identity_symbol not in playlist_model_source:
        fail(
            "Playlist must expose an owner-scoped identity and mosaic "
            f"covers: {required_playlist_identity_symbol}"
        )
playlist_library_source = (
    SOURCE / "Features/Library/PlaylistLibraryViewModel.swift"
).read_text(encoding="utf-8")
if "LibraryPlaylistShelfPolicy.normalized(" not in playlist_library_source:
    fail(
        "playlist loads must collapse duplicated system playlists "
        "(owned + followed «Мне нравится»)"
    )
if "didFinishPrefetch" not in playlist_library_source:
    fail(
        "a cancelled playlist prefetch must not count as loaded: the shelf "
        "would stay stuck on whichever page landed first"
    )
shelf_policy_source = (
    SOURCE / "Models/LibraryPlaylistShelfPolicy.swift"
).read_text(encoding="utf-8")
# «ОНИ НЕ ВСЕ»: the shelf loaded all eight playlists and the Albums shelf
# then subtracted most of them again. Whatever that shelf mistakes for a
# release — or whatever VK returns when it ignores `filters=albums` — must
# not be able to take a playlist off Медиатека.
for source_name, source_text in (
    ("PlaylistLibraryViewModel", playlist_library_source),
    ("LibraryPlaylistShelfPolicy", shelf_policy_source),
    ("LibraryView", library_view_source),
):
    for forbidden_subtraction_symbol in (
        "followedAlbumIdentities",
        "excludeFollowedAlbums",
    ):
        if forbidden_subtraction_symbol in source_text:
            fail(
                "the playlist shelf must not subtract the ids the Albums "
                "shelf reports: one wrong entry there emptied Медиатека "
                "down to a single card. Followed releases are kept off the "
                "shelf entry by entry, by "
                "LibraryPlaylistEntryPolicy.looksLikeFollowedAlbum "
                f"({source_name}: {forbidden_subtraction_symbol})"
            )
for forbidden_liked_title in (
    '"любимое"',
    '"любимые"',
    '"любимые треки"',
    '"избранное"',
    '"favorites"',
    '"favourites"',
):
    if forbidden_liked_title in shelf_policy_source:
        fail(
            "only the VK system liked playlist may collapse by title: "
            f"{forbidden_liked_title} is a user playlist name and "
            "collapsing it hides real playlists"
        )
if '"мне нравится"' not in shelf_policy_source:
    fail(
        "the owned and followed copies of the VK system liked playlist "
        "must still collapse into one card"
    )
# «Мне нравится (2)» is a separate saved playlist with its own id and its
# own tracks, and the shelf must show it next to «Мне нравится».
for forbidden_clone_marker_pattern in (
    '\\\\s*\\\\(\\\\d+\\\\)$',
    '\\\\s*#\\\\d+$',
):
    if forbidden_clone_marker_pattern in shelf_policy_source:
        fail(
            "a trailing clone marker is part of the name VK gave the "
            "playlist: stripping it merged «Мне нравится (2)» into «Мне "
            "нравится» and took a real playlist off the shelf"
        )
playlist_paging_source_path = SOURCE / "Models/LibraryPlaylistPagePolicy.swift"
if not playlist_paging_source_path.is_file():
    fail("LibraryPlaylistPagePolicy must define the playlist paging contract")
if "libraryPlaylistItems" not in all_source:
    fail(
        "audio.getPlaylists must decode item by item: a strict page decode "
        "hides every playlist behind one bad entry"
    )
json_value_source = (SOURCE / "Core/Networking/JSONValue.swift").read_text(
    encoding="utf-8"
)
if "LibraryPlaylistEntryPolicy.looksLikeFollowedAlbum(" not in json_value_source:
    fail(
        "audio.getPlaylists entries must be classified by "
        "LibraryPlaylistEntryPolicy, not by an ad-hoc marker count"
    )
for required_followed_album_symbol in (
    "var libraryFollowedAlbumItems: [Album]",
    "LibraryPlaylistEntryPolicy.belongsOnAlbumsShelf(",
):
    if required_followed_album_symbol not in json_value_source:
        fail(
            "the Albums shelf list is classified entry by entry, because the "
            "playlist shelf subtracts every id it reports: "
            f"{required_followed_album_symbol}"
        )
albums_request_source = (SOURCE / "Services/VKMusicService.swift").read_text(
    encoding="utf-8"
)
if '"filters": "followed,albums"' in all_source:
    fail(
        "audio.getPlaylists `filters` unions the categories it names, so "
        "`followed,albums` asks for every playlist saved from another person "
        "on top of the releases — and the playlist shelf subtracts every id "
        "the Albums shelf reports, which took those playlists off Медиатека"
    )
if 'static let albumShelfFilters = "albums"' not in playlist_paging_source_path.read_text(
    encoding="utf-8"
):
    fail("the Albums shelf must request the releases alone (filters=albums)")
if "LibraryPlaylistPagePolicy.albumShelfFilters" not in albums_request_source:
    fail(
        "the Albums shelf request must take its `filters` from "
        "LibraryPlaylistPagePolicy.albumShelfFilters"
    )
if "ownerID: sessionStore.resolvedOfflineAccountID" not in library_view_source:
    fail(
        "the playlist shelf must know whose playlists these are through the "
        "resolved account id: a session restored before the profile lands "
        "carries no user id, and the shelf cannot then tell the copy of "
        "«Мне нравится» you own from the one you follow"
    )
entry_policy_path = SOURCE / "Models/LibraryPlaylistEntryPolicy.swift"
if not entry_policy_path.is_file():
    fail("LibraryPlaylistEntryPolicy must define the playlist/release test")
entry_policy_source = entry_policy_path.read_text(encoding="utf-8")
for required_entry_policy_symbol in (
    "static func hasPlaylistMarker(",
    "static func hasReleaseAlbumType(",
    "static func belongsOnAlbumsShelf(",
    "guard !hasPlaylistMarker(entry), hasReleaseAlbumType(entry) else {",
    # A release names its artists. `type: 1` and a year are worn by saved
    # playlists too, so the release type plus one of them dropped real
    # playlists off Медиатека.
    "guard entry.hasMainArtists else { return false }",
    "return corroboratingReleaseMarkers(entry) >= 2",
):
    if required_entry_policy_symbol not in entry_policy_source:
        fail(
            "inferred VK markers must never drop a playlist on their own: "
            f"{required_entry_policy_symbol}"
        )
# An empty top-level `items` says the requested window held nothing, not
# that the playlists in the block beside it are not playlists. Ending the
# page there is what left the reporter with a single card.
if "if window.isEmpty {" in json_value_source:
    fail(
        "an empty `items` must not end the page before its sibling blocks "
        "are merged: the playlists arrive under `playlists` / `blocks` / "
        "`sections` often enough that reading the empty window as the "
        "whole answer emptied Медиатека"
    )
for required_prefetch_resume_symbol in (
    "prefetchOffset",
    "LibraryPlaylistPagePolicy.retryDelay",
):
    if required_prefetch_resume_symbol not in playlist_library_source:
        fail(
            "an interrupted playlist walk must resume from where it "
            "stopped, retrying a failed page once — restarting from zero "
            "republished a one-page shelf on every tab switch: "
            f"{required_prefetch_resume_symbol}"
        )
if "VKItems<Playlist>" in all_source:
    fail("playlist pages must not use the strict all-or-nothing decode")
if '"filters": "owned,followed"' in all_source:
    fail(
        "audio.getPlaylists must not narrow the filter: followed albums are "
        "excluded per item instead, so no playlist is left out"
    )
for required_playlist_paging_symbol in (
    "LibraryPlaylistPagePolicy.pageSize",
    "LibraryPlaylistPagePolicy.prefetchPages",
):
    if required_playlist_paging_symbol not in all_source:
        fail(
            "playlist shelf must prefetch several pages: "
            f"{required_playlist_paging_symbol}"
        )
playlist_shelf_body = library_view_source.split(
    "private var playlistShelf: some View {", 1
)
if len(playlist_shelf_body) < 2:
    fail("LibraryView must keep the playlist shelf")
elif "LazyHStack" in playlist_shelf_body[1].split("\n    private func", 1)[0]:
    fail(
        "the playlist shelf must use a non-lazy HStack: nested in the "
        "library LazyVStack a lazy row leaves off-screen cards "
        "unmaterialized and never paginates"
    )
shuffle_order_path = SOURCE / "Player" / "PlaybackShuffleOrder.swift"
if not shuffle_order_path.is_file():
    fail("PlaybackShuffleOrder must define the reversible shuffle contract")
for required_shuffle_symbol in (
    "sourceOrderedQueue = prepared",
    "PlaybackShuffleOrder.restored(",
    "shuffleEnabled = intent == .shuffleCollection || shufflePreference",
):
    if required_shuffle_symbol not in audio_player_source:
        fail(
            "turning shuffle off must restore the source order of the "
            f"queue: {required_shuffle_symbol}"
        )
shuffle_preference_path = SOURCE / "Player" / "PlaybackShufflePreference.swift"
if not shuffle_preference_path.is_file():
    fail(
        "the persisted shuffle preference must be separate from the shuffle "
        "mode of the playing queue"
    )
shuffle_preference_source = shuffle_preference_path.read_text(encoding="utf-8")
for required_shuffle_preference_symbol in (
    "case followPreference",
    "case shuffleCollection",
    "collectionLatchClearedKey",
):
    if required_shuffle_preference_symbol not in shuffle_preference_source:
        fail(
            "installs upgraded from the latched «Перемешать» must start in "
            f"list order: {required_shuffle_preference_symbol}"
        )
play_shuffled_body = audio_player_source.split("func playShuffled(", 1)
if len(play_shuffled_body) < 2:
    fail("AudioPlayer must expose playShuffled")
else:
    play_shuffled_body = play_shuffled_body[1].split("\n    func ", 1)[0]
    if 'forKey: "player.shuffle"' in play_shuffled_body:
        fail(
            "per-collection «Перемешать» must not persist global shuffle: it "
            "latched every later queue, including Медиатека, into shuffle"
        )
    if "shuffleEnabled = true" in play_shuffled_body:
        fail(
            "per-collection «Перемешать» must not latch the player-wide "
            "shuffle for the session either: the next Медиатека tap built a "
            "shuffled queue from it"
        )
library_play_body = library_view_source.split(
    "private func playLibraryTrack(", 1
)
if len(library_play_body) < 2:
    fail(
        "Медиатека must play a track through one ordered entry point so the "
        "queue is the visible list"
    )
elif "playShuffled(" in library_play_body[1].split("\n    private func", 1)[0]:
    fail("library playback must never start through playShuffled")
if "LibraryTrackContinuationCursor(" not in library_view_source:
    fail(
        "a queue started from Медиатека must continue with the next library "
        "page, in VK order, before it reaches recommendations"
    )
library_store_source = (SOURCE / "Models/MusicLibraryStore.swift").read_text(
    encoding="utf-8"
)
for required_library_index_symbol in (
    "func include(",
    "removedSignatures",
):
    if required_library_index_symbol not in library_store_source:
        fail(
            "Медиатека shows the opening pages of the same audio.get walk, "
            "so it must fold them into the liked index instead of replacing "
            f"it: {required_library_index_symbol}"
        )
if "libraryStore.replace(" in library_view_source:
    fail(
        "LibraryView must not replace the liked index from a partial page: "
        "a 1000-track index shrank to 100 and blanked the heart below it"
    )
if "@EnvironmentObject private var libraryStore" in library_view_source:
    fail(
        "LibraryView must not observe MusicLibraryStore: folding in each "
        "page rebuilt the whole track list (the per-row LikedTrackBadge "
        "observes it already)"
    )
for required_shared_refresh_symbol in (
    "func refreshLibraryIndex() async",
    "func refreshLikedAlbums() async",
):
    if required_shared_refresh_symbol not in app_environment_source:
        fail(
            "the library walks must live on AppEnvironment so the tab shell "
            "and Медиатека share one request: "
            f"{required_shared_refresh_symbol}"
        )
if "musicService.likedAlbums(" in library_view_source:
    fail(
        "LibraryView must reach the Albums shelf through "
        "AppEnvironment.refreshLikedAlbums(): opening Медиатека otherwise "
        "repeated the ten-page walk the tab shell had just finished"
    )
load_more_body = track_collection_source.split("func loadMore(", 1)
if len(load_more_body) < 2:
    fail("TrackCollectionViewModel must expose loadMore")
elif "guard generation == loadGeneration" not in load_more_body[1].split(
    "appendUnique(", 1
)[0]:
    fail(
        "a page that lands after a reload or a like/unlike describes a "
        "window whose offsets have shifted: appending it interleaves the "
        "list, which reads as a scrambled Медиатека"
    )
for required_coalescing_symbol in (
    "paginationTask",
    "playlistPaginationTask",
    "addedTrackReloadTask",
):
    if required_coalescing_symbol not in library_view_source:
        fail(
            "library onAppear and notification bursts must be coalesced "
            f"into one in-flight task: {required_coalescing_symbol}"
        )
append_fn = audio_player_source.split("func appendToQueue(", 1)
if len(append_fn) < 2:
    fail("AudioPlayer must expose appendToQueue")
else:
    append_body = append_fn[1].split("\n    func ", 1)[0]
    if "rerankUpcomingMix(" in append_body:
        fail(
            "appendToQueue must not reshuffle the upcoming mix queue "
            "(causes mid-listen jumps)"
        )
    if "LibraryQueuePolicy.appendableCount(" not in append_body:
        fail(
            "appendToQueue must size the queue through LibraryQueuePolicy: "
            "a Медиатека of 833 tracks played as «Трек 1 из 100» while the "
            "append shared the mix ceiling"
        )
    if "MixTrackRequestPolicy.queueLimit" in append_body:
        fail(
            "appendToQueue must not cap every queue at the mix limit — the "
            "mix ceiling belongs to LibraryQueuePolicy.upcomingLimit(for:), "
            "which keeps it for mix / Selena and lifts it for Медиатека"
        )
library_queue_policy_path = SOURCE / "Player/LibraryQueuePolicy.swift"
if not library_queue_policy_path.is_file():
    fail(
        "a queue started from Медиатека needs its own capacity policy: "
        "PrivateMusic/Player/LibraryQueuePolicy.swift"
    )
library_queue_policy_source = library_queue_policy_path.read_text(
    encoding="utf-8"
)
for required_library_queue_symbol in (
    "enum LibraryQueuePolicy",
    "static let queueLimit = 2_000",
    "func upcomingLimit(for source: QueueSource?)",
    "func appendableCount(",
    "upcomingLimit(for: source) - max(upcomingCount, 0)",
    "MixTrackRequestPolicy.queueLimit",
):
    if required_library_queue_symbol not in library_queue_policy_source:
        fail(
            "the library queue ceiling must stay separate from the mix one "
            f"and above it: {required_library_queue_symbol}"
        )
for required_dock_glass_symbol in (
    "tint: settings.theme.accent.opacity(0.06)",
    "searchTabButton",
    "Capsule(style: .continuous)",
    ".safeAreaInset(edge: .bottom, spacing: 0)",
    "legacyTabStack",
    "Do NOT wrap mini-player",
):
    if required_dock_glass_symbol not in main_tab_source:
        fail(
            "pre-iOS 26 fallback dock must retain Liquid Glass + safe inset: "
            f"{required_dock_glass_symbol}"
        )
if "AdaptiveGlassContainer(spacing: 10)" in main_tab_source:
    fail(
        "PlaybackTabDock must not wrap chrome in GlassEffectContainer "
        "(morphs into floating orbs)"
    )
if "showsOwnGlassChrome: false" not in main_tab_source:
    fail(
        "system tab accessory mini player must disable stacked glass chrome"
    )
if "LikedTrackBadge(track: track)" in mini_player_source:
    fail("mini-player must not overlay a liked-track badge on artwork")
if ".buttonStyle(.glassProminent)" in mini_player_source:
    fail("mini-player must use plain transport controls like Apple Music")
if "backward.fill" not in mini_player_source:
    fail("mini-player must expose previous next to play/pause")
if "previousControl" not in mini_player_source:
    fail("mini-player must keep a dedicated previousControl")
for required_mini_player_symbol in (
    "MiniPlayerProgressPolicy",
    "MiniPlayerGesturePolicy",
    "MiniPlayerLayoutMetrics",
    "MiniPlayerArtworkView",
    "openPlayerArea",
    "predictedEndTranslation",
    "isBuffering",
):
    if required_mini_player_symbol not in mini_player_source:
        fail(
            f"mini-player is missing Apple Music symbol: "
            f"{required_mini_player_symbol}"
        )
if "enum MiniPlayerProgressPolicy" not in all_source:
    fail("MiniPlayerProgressPolicy must exist for unit-tested progress math")
if "enum MiniPlayerGesturePolicy" not in all_source:
    fail("MiniPlayerGesturePolicy must exist for unit-tested swipe recognition")
if "buttonStyle(.borderless)" not in (
    SOURCE / "Features" / "Album" / "AlbumDetailView.swift"
).read_text(encoding="utf-8"):
    fail("album follow control must remain tappable inside List rows")
for required_library_resilience_symbol in (
    "Не удалось загрузить треки",
    "libraryStore.beginRefresh()",
    "libraryAudioItems",
):
    if required_library_resilience_symbol not in all_source:
        fail(
            "library tracks resilience is missing: "
            f"{required_library_resilience_symbol}"
        )
if "enum AudioInterruptionPolicy" not in audio_player_source:
    fail("audio interruption policy must remain unit-testable")
if "MediaServicesResetPolicy.shouldAutoplayAfterReset" not in audio_player_source:
    fail("media services reset must keep CarKit/BT autoplay intent")
if "MediaServicesResetPolicy.shouldSuppressAdvance" not in audio_player_source:
    fail("media services reset must suppress skip-on-error briefly")
if "StreamFailureRetryPolicy.shouldRetrySameTrack" not in audio_player_source:
    fail("flaky networks must retry the current track before auto-skip")
if "StreamFailureRetryPolicy.preferredForwardBufferDuration" not in audio_player_source:
    fail("playback must request a longer forward buffer on weak networks")
if "PlaybackPreloadPolicy.preferredForwardBufferDuration" not in audio_player_source:
    fail("next-track preload must request a short forward buffer")
if "PlaybackPreloadPolicy.forwardBufferDuration" not in audio_player_source:
    fail("preload must promote its buffer once it becomes active playback")
if "AudioProcessingAttachPolicy.supportsAudioTap" not in audio_player_source:
    fail("HLS sources must not attach unsupported audio taps")
if "AVMutableAudioMixInputParameters(track:" not in audio_player_source:
    fail("audio tap must bind to an AVAssetTrack after readyToPlay")
if "shouldTreatEndAsRouteDisconnect" not in audio_player_source:
    fail("interruption end must detect headphone-disconnect races")
if "player.volume = 1" not in audio_player_source:
    fail("playback level must follow system volume (AVPlayer at unity gain)")
if "PlaybackProgressModel" not in all_source:
    fail("playback progress must be isolated from AudioPlayer EnvironmentObject fan-out")
if "RemoteCommandCoalescing" not in all_source:
    fail("remote headphone commands must be coalesced")
if "SystemVolumeSlider" not in all_source:
    fail("player actions must expose a system volume slider")
if "MPVolumeView" not in all_source:
    fail("system volume control must use MPVolumeView")
if "hasActiveEqualizerProcessing" not in equalizer_source:
    fail("flat equalizer must skip the realtime audio tap")
watch_protocol = (
    SOURCE / "Shared" / "WatchRemoteProtocol.swift"
).read_text(encoding="utf-8")
if "lhs.snapshotDate" in watch_protocol or "rhs.snapshotDate" in watch_protocol:
    fail("WatchRemoteState equality must ignore snapshotDate")
if "static func ==" not in watch_protocol:
    fail("WatchRemoteState must customize Equatable to ignore snapshotDate")
if "kAudioFormatFlagIsNonInterleaved" not in equalizer_source:
    fail("audio processing must use the declared PCM interleaving format")
if "let nonInterleaved = buffers.count > 1" in equalizer_source:
    fail("audio buffer count must not be used to infer PCM interleaving")
if "if peak > 1" in spatial_audio_source:
    fail("spatial audio must not use a sample-by-sample peak limiter")
if "sideHighPassFrequency" not in spatial_audio_source:
    fail("spatial audio must keep bass mono via side high-pass")
if "PlaybackOutputToneProfile" not in all_source:
    fail("route-aware anti-boom tone profile must exist")
if "setOutputProfile" not in equalizer_source:
    fail("equalizer must adapt clarity processing to the output route")
configure_audio_session = audio_player_source.split(
    "private func configureAudioSession()", 1
)[1].split("private func activateAudioSession()", 1)[0]
if "setActive(true)" in configure_audio_session:
    fail("audio session must be activated only when playback starts")

for required_fullscreen_symbol in (
    ".fullScreenCover(isPresented: $player.isPlayerPresented)",
    ".playerPresentationBackground()",
):
    if required_fullscreen_symbol not in root_view_source:
        fail(
            "player presentation is not full-screen: "
            f"{required_fullscreen_symbol}"
        )
if re.search(
    r"\.onDisappear\s*\{\s*player\.dismissPlayer\(\)",
    root_view_source,
):
    fail("player presentation must not be dismissed from content onDisappear")
if ".simultaneousGesture(miniPlayerGesture)" not in mini_player_source:
    fail("mini-player swipe gesture must not intercept its open button")
if "SystemPlaybackAccessory" in main_tab_source and (
    "MiniPlayerView(playerNamespace: playerNamespace)"
    not in main_tab_source
):
    fail("system accessory must reuse MiniPlayerView when expanded")
if "SystemPlaybackAccessory" in main_tab_source:
    for required_accessory_symbol in (
        "tabViewBottomAccessoryPlacement",
        "InlineMiniPlayerView(playerNamespace: playerNamespace)",
        "MiniPlayerAccessoryMode",
        "@unknown default",
    ):
        if required_accessory_symbol not in main_tab_source:
            fail(
                "system accessory is missing inline/expanded support: "
                f"{required_accessory_symbol}"
            )
inline_mini_player_source = (
    SOURCE / "Features" / "Player" / "InlineMiniPlayerView.swift"
).read_text(encoding="utf-8")
for required_inline_symbol in (
    "MiniPlayerArtworkView",
    "showsBufferingIndicator",
    "tapTarget",
    "Открыть полноэкранный плеер",
):
    if required_inline_symbol not in inline_mini_player_source:
        fail(
            f"inline mini-player is missing symbol: {required_inline_symbol}"
        )
if "struct MiniPlayerArtworkView" not in all_source:
    fail("MiniPlayerArtworkView must provide real artwork crossfade")
if "axisDominanceRatio" not in all_source:
    fail("mini-player gestures must require axis dominance")
if "enum MiniPlayerAccessoryPolicy" not in all_source:
    fail("MiniPlayerAccessoryPolicy must exist for unit-tested accessory layout")
if "reduceMotionCrossfadeDuration" not in all_source:
    fail("artwork crossfade must honor Reduce Motion duration")
if "loadedIdentity == loadIdentity ? image : nil" not in cached_image_source:
    fail("cached artwork must never display a stale request identity")
if "Text(track.duration.formattedDuration)" not in library_view_source:
    fail("library track rows must display track duration")
if ".buttonStyle(.glassProminent)" not in player_view_source:
    fail(f"player is missing full-bleed/glass symbol: .buttonStyle(.glassProminent)")
for required_player_symbol in (
    ".background(playerBackground.ignoresSafeArea())",
    ".buttonStyle(.glass)",
    "AdaptiveGlassContainer(spacing: 8)",
    "AdaptiveGlassContainer(spacing: 18)",
    ".simultaneousGesture(fullScreenDismissGesture)",
    "PlayerDismissGesturePolicy.shouldDismiss",
    "PlayerArtworkCarouselPolicy.neighborIndices",
):
    if required_player_symbol not in player_view_source:
        fail(f"player is missing full-bleed/glass symbol: {required_player_symbol}")
# Mini-player uses plain controls; full-screen player keeps glassProminent.
for required_preload_symbol in (
    "PlaybackPreloadPolicy.nextIndex",
    "PlaybackPreloadPolicy.forwardBufferDuration",
    "asset.load(.isPlayable)",
    "takePreloadedPlayback",
    "invalidatePreloadedPlayback",
    "ArtworkImageCache.shared.prefetch",
):
    if required_preload_symbol not in all_source:
        fail(f"next-track preload is missing: {required_preload_symbol}")
for required_catalog_symbol in (
    "PlaybackIndicatorView",
    "ListeningProgressPolicy.shouldMarkListened",
    "HomeCatalogStore",
    "audio.searchAlbums",
    "audio.followPlaylist",
    "audio.searchArtists",
    "audio.getAudiosByArtist",
    "catalog.getAudioArtist",
    "AlbumFollowPolicy.methodPath",
    "catalogSnapshot",
    "AlbumDetailView",
    "AlbumShareLinkBuilder",
    "likedAlbumsStore",
    "albumReference",
    "openAlbum(for: track)",
):
    if required_catalog_symbol not in all_source:
        fail(f"catalog/album support is missing: {required_catalog_symbol}")
if '/method/audio.unfollowPlaylist' in all_source:
    fail("album unfollow must use audio.deletePlaylist, not unfollowPlaylist")
vk_music_source = (SOURCE / "Services" / "VKMusicService.swift").read_text(
    encoding="utf-8"
)
if '"audio_stream_mixes"' in vk_music_source or '"audio_new_releases"' in vk_music_source:
    fail("catalog sections must use real ids from catalog.getAudio")
liked_albums_body = vk_music_source.split("func likedAlbums(", 1)
if len(liked_albums_body) < 2:
    fail("VKMusicService must load the Albums shelf through likedAlbums")
else:
    liked_albums_body = liked_albums_body[1].split("\n    func ", 1)[0]
    if "followedAlbumPage(" not in liked_albums_body:
        fail(
            "the Albums shelf page must be classified item by item: a "
            "strict VKItems<Album> decode took every playlist saved from "
            "another owner for a release, and the playlist shelf subtracts "
            "exactly those ids, so Медиатека lost them"
        )
for required_queue_symbol in (
    "func removeFromQueue(at index: Int)",
    ".swipeActions(",
    "Удалить из очереди",
):
    if required_queue_symbol not in all_source:
        fail(f"queue swipe removal is missing: {required_queue_symbol}")
for required_offline_symbol in (
    "configureOfflinePlayback",
    "offlineURLProvider",
    "loadedOfflineTrackID",
):
    if required_offline_symbol not in audio_player_source:
        fail(f"offline playback is missing: {required_offline_symbol}")
for required_hls_symbol in (
    "AVAssetDownloadURLSession",
    "hlsPackage",
    "handleEventsForBackgroundURLSession",
):
    if required_hls_symbol not in all_source:
        fail(f"HLS offline support is missing: {required_hls_symbol}")
for forbidden_share_symbol in (
    "TrackShareSheet(",
    "AudioFileActivityItemSource",
):
    if forbidden_share_symbol in all_source:
        fail(f"share must not use audio file sharing: {forbidden_share_symbol}")
for required_share_symbol in (
    "vk.com/audio",
    "UIPasteboard.general.string",
):
    if required_share_symbol not in all_source:
        fail(f"link share is missing: {required_share_symbol}")
for required_playlist_symbol in (
    "OfflinePlaylistStore",
    "maximumConcurrentDownloads",
    "downloadArtwork",
):
    if required_playlist_symbol not in all_source:
        fail(f"offline playlists are missing: {required_playlist_symbol}")
for required_cache_symbol in (
    "automaticOfflineCacheEnabled",
    "OfflineTrackRetention",
    "configureStorage",
):
    if required_cache_symbol not in all_source:
        fail(f"automatic offline cache is missing: {required_cache_symbol}")
for required_share_session_symbol in (
    "beginShareSession",
    "endShareSession",
    "isShareSessionActive",
):
    if required_share_session_symbol not in all_source:
        fail(
            "share session bandwidth guard is missing: "
            f"{required_share_session_symbol}"
        )
feature_source = (
    SOURCE / "App" / "OfflineDownloadsFeature.swift"
).read_text(encoding="utf-8")
if "enum OfflineDownloadsFeature" not in feature_source:
    fail("offline downloads feature flag is missing")
if "productionEnabled = false" not in feature_source:
    fail(
        "offline downloads must stay disabled for the stable build "
        "(OfflineDownloadsFeature.productionEnabled = false)"
    )
if "MPEGTSAudioExtractor" not in all_source:
    fail("MPEG-TS demux for HLS share export is missing")
if "pauseForShareExport" not in all_source:
    fail("share export must pause playback before HLS transcode")
for required_route_symbol in (
    "shouldPauseAfterRouteLoss",
    "setPrefersInterruptionOnRouteDisconnect",
    "oldDeviceUnavailable",
    "responding-to-audio-route-changes",
    # Ear detection ends its interruption asking for a resume while the
    # AirPods are still the route: honouring that played the track on with
    # the buds in the case.
    "shouldTreatEndAsDeliberatePause(",
    # Nothing the app starts by itself may reach the speaker while the
    # headphones that were playing are gone.
    "AudioAutoplayGatePolicy.allowsAutomaticPlayback(",
    # `.oldDeviceUnavailable` can arrive while the route still names the
    # device that went away, or with no previous route at all.
    "looksLikeStaleRouteLoss(",
    "isUnattributedRouteLoss(",
    # An unplug does not always announce itself as `.oldDeviceUnavailable`.
    "mayCarryAnUnannouncedDisconnect(",
    # Ear detection is told from a call by what else held the output, not
    # by how long the interruption lasted.
    "otherAudioWasPlaying:",
    "isOtherAudioPlaying",
    # AirPods flicker between A2DP and HFP without leaving the ear.
    "namesTheSameWornRoute(",
    # Media services restarting does not put the headphones back on.
    "retainsDisconnectPendingAfterReset(",
):
    if required_route_symbol not in all_source:
        fail(f"headphone route pause is missing: {required_route_symbol}")
audio_player_source = (SOURCE / "Player/AudioPlayer.swift").read_text(
    encoding="utf-8"
)
for required_autoplay_gate_symbol in (
    "automatic: true",
    "guard allowsAutomaticPlayback else {",
):
    if required_autoplay_gate_symbol not in audio_player_source:
        fail(
            "automatic playback — stream retry, stall recovery, the next "
            "track, the reload after a media services reset — must pass "
            "through the route gate: "
            f"{required_autoplay_gate_symbol}"
        )
if ".clipped()" in player_view_source:
    fail("full-screen player must not clip its safe-area background")
if ".clear.interactive" in glass_source:
    fail("Liquid Glass variants must not be mixed in navigation controls")
if ".adaptiveGlass(\n            in: RoundedRectangle" in player_view_source:
    fail("player quick actions must not use a heavy enclosing glass panel")
for source_path in swift_files:
    if source_path == SOURCE / "Player" / "AudioPlayer.swift":
        continue
    source_text = source_path.read_text(encoding="utf-8")
    if re.search(r"isPlayerPresented\s*=", source_text):
        fail(
            "player presentation state must change only through AudioPlayer: "
            f"{source_path.relative_to(ROOT)}"
        )

helper_path = ROOT / "scripts" / "vkpymusic_login.py"
helper_source = helper_path.read_text(encoding="utf-8")
for required_helper_text in (
    "getpass.getpass",
    "logging.NullHandler",
    "TokenReceiver",
    "token_for_audio",
    "receiver.client.user_agent",
):
    if required_helper_text not in helper_source:
        fail(f"VKpyMusic helper is missing: {required_helper_text}")
if "save_to_config" in helper_source:
    fail("VKpyMusic helper must not persist credentials or session files")

for contents in (SOURCE / "Resources" / "Assets.xcassets").rglob("Contents.json"):
    try:
        json.loads(contents.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        fail(f"invalid JSON in {contents}: {error}")

plist_path = SOURCE / "Resources" / "Info.plist"
with plist_path.open("rb") as stream:
    plist = plistlib.load(stream)
if plist.get("UIBackgroundModes") != ["audio"]:
    fail("Info.plist must contain only the audio background mode")
scene_manifest = plist.get("UIApplicationSceneManifest")
if not isinstance(scene_manifest, dict):
    fail(
        "Info.plist must declare UIApplicationSceneManifest "
        "(required to launch when built with the iOS 27 SDK, TN3187)"
    )
if "UIApplicationSupportsMultipleScenes" not in scene_manifest:
    fail(
        "UIApplicationSceneManifest must declare "
        "UIApplicationSupportsMultipleScenes"
    )
app_delegate = (SOURCE / "App" / "AppDelegate.swift").read_text(
    encoding="utf-8"
)
if "configurationForConnecting" not in app_delegate:
    fail(
        "AppDelegate must implement configurationForConnecting "
        "for iOS 27 scene lifecycle adoption"
    )
for key in (
    "VK_API_BASE_URL",
    "TELEGRAM_GROUP_URL",
    "TELEGRAM_VPN_URL",
):
    if not str(plist.get(key, "")).startswith("https://"):
        fail(f"{key} must use HTTPS")

privacy_path = SOURCE / "Resources" / "PrivacyInfo.xcprivacy"
with privacy_path.open("rb") as stream:
    privacy = plistlib.load(stream)
if privacy.get("NSPrivacyTracking") is not False:
    fail("privacy manifest must disable tracking")
if privacy.get("NSPrivacyTrackingDomains") != []:
    fail("privacy manifest must not declare tracking domains")
if privacy.get("NSPrivacyCollectedDataTypes") != []:
    fail("privacy manifest must not declare collected analytics data")
accessed_api_types = privacy.get("NSPrivacyAccessedAPITypes")
if not isinstance(accessed_api_types, list):
    fail("privacy manifest must declare NSPrivacyAccessedAPITypes")
accessed_by_category = {
    entry.get("NSPrivacyAccessedAPIType"): set(
        entry.get("NSPrivacyAccessedAPITypeReasons") or []
    )
    for entry in accessed_api_types
    if isinstance(entry, dict)
}
required_privacy_reasons = {
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"DDA9.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"E174.1"},
}
for category, reasons in required_privacy_reasons.items():
    declared = accessed_by_category.get(category, set())
    if not reasons <= declared:
        fail(
            "privacy manifest must declare "
            f"{category} reason(s) {sorted(reasons)}"
        )

watch_privacy_path = (
    ROOT / "PrivateMusicWatch" / "Resources" / "PrivacyInfo.xcprivacy"
)
with watch_privacy_path.open("rb") as stream:
    watch_privacy = plistlib.load(stream)
if watch_privacy.get("NSPrivacyTracking") is not False:
    fail("Watch privacy manifest must disable tracking")
if watch_privacy.get("NSPrivacyCollectedDataTypes") != []:
    fail("Watch privacy manifest must not declare collected data")

for path, expected_size in (
    (
        SOURCE
        / "Resources"
        / "Assets.xcassets"
        / "AppIcon.appiconset"
        / "AppIcon.png",
        1024,
    ),
    (
        SOURCE
        / "Resources"
        / "Assets.xcassets"
        / "AppIconPreview.imageset"
        / "AppIconPreview.png",
        512,
    ),
    (
        SOURCE
        / "Resources"
        / "Assets.xcassets"
        / "AppIconPreview.imageset"
        / "AppIconPreview1x.png",
        256,
    ),
    (
        SOURCE
        / "Resources"
        / "Assets.xcassets"
        / "AppIconPreview.imageset"
        / "AppIconPreview3x.png",
        768,
    ),
    (
        ROOT
        / "PrivateMusicWatch"
        / "Resources"
        / "Assets.xcassets"
        / "AppIcon.appiconset"
        / "AppIcon.png",
        1024,
    ),
):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        fail(f"{path} is not PNG")
    width, height = struct.unpack(">II", data[16:24])
    if (width, height) != (expected_size, expected_size):
        fail(f"unexpected dimensions for {path}: {width}x{height}")

for forbidden_demo in (
    SOURCE / "Services" / "DemoMusicService.swift",
    SOURCE / "Resources" / "DemoTone.wav",
):
    if forbidden_demo.exists():
        fail(f"release must not contain demo asset: {forbidden_demo}")

project_yml = (ROOT / "project.yml").read_text(encoding="utf-8")
for required_setting in (
    'iOS: "16.0"',
    'watchOS: "10.0"',
    "PRODUCT_BUNDLE_IDENTIFIER: com.dec.privatemusic2",
    "PRODUCT_BUNDLE_IDENTIFIER: com.dec.privatemusic2.watchkitapp",
    "INFOPLIST_KEY_WKCompanionAppBundleIdentifier: com.dec.privatemusic2",
    "INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp: NO",
    "TARGETED_DEVICE_FAMILY: 4",
    "postGenCommand: python3 scripts/fix_watch_embedding.py",
    "GENERATE_INFOPLIST_FILE: NO",
    "INFOPLIST_FILE: PrivateMusic/Resources/Info.plist",
):
    if required_setting not in project_yml:
        fail(f"missing project setting: {required_setting}")

open_braces = len(re.findall(r"\{", all_source))
close_braces = len(re.findall(r"\}", all_source))
if open_braces != close_braces:
    fail(f"unbalanced braces: {open_braces} != {close_braces}")

print(f"OK: {len(swift_files)} Swift files")
print("OK: no embedded client secret or CAPTCHA interception")
print("OK: Keychain, ephemeral URLSession and Now Playing are present")
print("OK: non-persistent VK web login and direct token exchange")
print("OK: Info.plist, HTTPS endpoints and release icons")
print("OK: valid no-tracking privacy manifest")
print("OK: edge-to-edge player and consistent Liquid Glass controls")
print("OK: deterministic player presentation and lightweight action dock")
