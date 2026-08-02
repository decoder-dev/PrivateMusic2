#!/usr/bin/env python3
"""Validate the embedded Apple Watch companion before IPA packaging."""

from __future__ import annotations

import plistlib
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


if len(sys.argv) != 2:
    fail("usage: validate_watch_bundle.py /path/to/PrivateMusic.app")

app = Path(sys.argv[1])
if not app.is_dir():
    fail(f"missing iOS app: {app}")
if (app / "Watch").exists():
    fail("legacy Watch/ embedding is not installable with Xcode 26+")

watch = app / "PlugIns" / "PrivateMusicWatch.app"
if not watch.is_dir():
    fail("missing PlugIns/PrivateMusicWatch.app")
if not (watch / "Assets.car").is_file():
    fail("Watch app has no compiled app icon asset catalog")
if not (watch / "PrivacyInfo.xcprivacy").is_file():
    fail("Watch app has no privacy manifest")

with (app / "Info.plist").open("rb") as stream:
    phone_info = plistlib.load(stream)
with (watch / "Info.plist").open("rb") as stream:
    watch_info = plistlib.load(stream)

if phone_info.get("CFBundleIdentifier") != "com.dec.privatemusic2":
    fail("unexpected iOS bundle identifier")
if watch_info.get("CFBundleIdentifier") != "com.dec.privatemusic2.watchkitapp":
    fail("unexpected Watch bundle identifier")
if watch_info.get("WKCompanionAppBundleIdentifier") != "com.dec.privatemusic2":
    fail("Watch companion bundle identifier does not match iOS app")
if watch_info.get("WKApplication") is not True:
    fail("Watch bundle is not marked as a Watch application")

for key in ("CFBundleShortVersionString", "CFBundleVersion"):
    if phone_info.get(key) != watch_info.get(key):
        fail(f"iOS and Watch {key} values differ")

print("OK: embedded Watch app, icon, identifiers and versions")
