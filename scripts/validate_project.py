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
}
for relative in required:
    if not (ROOT / relative).is_file():
        fail(f"missing {relative}")

all_source = "\n".join(path.read_text(encoding="utf-8") for path in swift_files)
audio_player_source = (
    SOURCE / "Player" / "AudioPlayer.swift"
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
