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
cached_image_source = (
    SOURCE / "Features" / "Shared" / "CachedRemoteImage.swift"
).read_text(encoding="utf-8")
library_view_source = (
    SOURCE / "Features" / "Library" / "LibraryView.swift"
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
        fail("tab dock must keep search as a separate circular control")
for required_system_tab_symbol in (
    "SystemLiquidGlassTabView",
    "tabViewBottomAccessory",
    "role: .search",
    "SystemPlaybackAccessory",
):
    if required_system_tab_symbol not in main_tab_source:
        fail(
            "iOS 26+ must use system Liquid Glass TabView like Apple Music: "
            f"{required_system_tab_symbol}"
        )
for required_dock_glass_symbol in (
    "AdaptiveGlassContainer(spacing: 10)",
    "tint: settings.theme.accent.opacity(0.06)",
    "searchTabButton",
    "Capsule(style: .continuous)",
    ".safeAreaInset(edge: .bottom, spacing: 0)",
    "legacyTabStack",
):
    if required_dock_glass_symbol not in main_tab_source:
        fail(
            "pre-iOS 26 fallback dock must retain Liquid Glass + safe inset: "
            f"{required_dock_glass_symbol}"
        )
if "LikedTrackBadge(track: track)" in mini_player_source:
    fail("mini-player must not overlay a liked-track badge on artwork")
if ".buttonStyle(.glassProminent)" in mini_player_source:
    fail("mini-player must use plain transport controls like Apple Music")
if "backward.fill" in mini_player_source:
    fail("mini-player must hide previous in the primary chrome (swipe / a11y only)")
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
if "shouldTreatEndAsRouteDisconnect" not in audio_player_source:
    fail("interruption end must detect headphone-disconnect races")
if "player.volume = 1" not in audio_player_source:
    fail("playback level must follow system volume (AVPlayer at unity gain)")
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
    "AlbumDetailView",
    "AlbumShareLinkBuilder",
    "likedAlbumsStore",
    "albumReference",
    "openAlbum(for: track)",
):
    if required_catalog_symbol not in all_source:
        fail(f"catalog/album support is missing: {required_catalog_symbol}")
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
):
    if required_route_symbol not in all_source:
        fail(f"headphone route pause is missing: {required_route_symbol}")
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
if privacy.get("NSPrivacyAccessedAPITypes") != [
    {
        "NSPrivacyAccessedAPIType":
            "NSPrivacyAccessedAPICategoryUserDefaults",
        "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
    }
]:
    fail("privacy manifest must declare UserDefaults reason CA92.1")

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
