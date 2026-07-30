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

all_source = "\n".join(path.read_text(encoding="utf-8") for path in swift_files)
audio_player_source = (
    SOURCE / "Player" / "AudioPlayer.swift"
).read_text(encoding="utf-8")
player_view_source = (
    SOURCE / "Features" / "Player" / "PlayerView.swift"
).read_text(encoding="utf-8")
root_view_source = (
    SOURCE / "Features" / "Root" / "RootView.swift"
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
for required_player_symbol in (
    ".background(playerBackground.ignoresSafeArea())",
    ".buttonStyle(.glassProminent)",
    "AdaptiveGlassContainer(spacing: 8)",
):
    if required_player_symbol not in player_view_source:
        fail(f"player is missing full-bleed/glass symbol: {required_player_symbol}")
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
    "case vkLink",
    "linkPayload(",
):
    if forbidden_share_symbol in all_source:
        fail(f"share must never fall back to a link: {forbidden_share_symbol}")
for required_share_symbol in (
    "requiresMP3: false",
    "AVAssetExportPresetAppleM4A",
    "AudioFileActivityItemSource",
):
    if required_share_symbol not in all_source:
        fail(f"audio file sharing is missing: {required_share_symbol}")
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
    "PRODUCT_BUNDLE_IDENTIFIER: com.dec.privatemusic2",
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
