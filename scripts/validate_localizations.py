#!/usr/bin/env python3
"""Validate that shipped Localizable resources stay in sync and use stable keys."""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "PrivateMusic" / "Resources"
WATCH_RESOURCES = ROOT / "PrivateMusicWatch" / "Resources"
SOURCE = ROOT / "PrivateMusic"
TESTS = ROOT / "PrivateMusicTests"
LOCALES = ("ru", "en")
ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[@d]")
STABLE_KEY = re.compile(r"^[a-z][a-z0-9._]*$")
CYRILLIC = re.compile(r"[А-Яа-яЁё]")
L10N_KEY = re.compile(r'L10n\.(?:text|format)\(\s*"([^"]+)"')
UI_HARDCODE = re.compile(
    r'\b(?:Text|Button|Label|Section|Toggle|ProgressView|Picker|Menu|'
    r'DisclosureGroup|navigationTitle|alert|LabeledContent)\(\s*"([^"]*[А-Яа-яЁё][^"]*)"'
)
REQUIRED_ACCESSIBILITY_KEYS = {
    "clear_recent_searches",
    "remove_search_0",
    "loading_search_results",
    "open_full_screen_player",
    "previous_track",
    "next_track",
    "pause",
    "resume_playback",
    "current_track",
    "play_track",
    "play_from_queue",
    "seek_to_this_line",
    "copy_line",
    "line_copied",
    "close_player",
    "choose_playback_device",
    "actions_menu_expanded",
    "actions_menu_collapsed",
    "shuffle_on",
    "shuffle_off",
    "repeat_off",
    "repeat_queue",
    "repeat_one",
    "artwork_0_1",
    "track_is_in_your_library",
    "track_is_not_in_your_library",
    "could_not_update_library",
    "search_query",
    "enter_at_least_two_characters",
    "clear_search",
    "enter_one_more_character",
    "search_requires_at_least_two_characters",
    "find_music",
    "enter_a_track_title_or_artist_results_appear_automatically",
    "search_again_for_0",
    "search.searching",
    "searching",
    "loading_more",
    "tab.switch_hint",
}


def read_strings(
    locale: str,
    resources: Path = RESOURCES,
) -> dict[str, str]:
    path = resources / f"{locale}.lproj" / "Localizable.strings"
    result: dict[str, str] = {}
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("/*") or line.startswith("//"):
            continue
        match = ENTRY.match(line)
        if not match:
            raise ValueError(f"{path}:{number}: malformed .strings entry")
        key, value = match.groups()
        if key in result:
            raise ValueError(f"{path}:{number}: duplicate key {key!r}")
        result[key] = value
    return result


def read_stringsdict(locale: str) -> dict[str, object]:
    path = RESOURCES / f"{locale}.lproj" / "Localizable.stringsdict"
    with path.open("rb") as stream:
        result = plistlib.load(stream)
    if not isinstance(result, dict):
        raise ValueError(f"{path}: root must be a dictionary")
    return result


def collect_swift_files() -> list[Path]:
    return sorted(SOURCE.rglob("*.swift")) + sorted(TESTS.rglob("*.swift"))


def main() -> int:
    strings = {locale: read_strings(locale) for locale in LOCALES}
    dictionaries = {
        locale: read_stringsdict(locale)
        for locale in LOCALES
    }

    reference = set(strings[LOCALES[0]])
    for locale in LOCALES[1:]:
        keys = set(strings[locale])
        if keys != reference:
            missing = sorted(reference - keys)
            extra = sorted(keys - reference)
            raise ValueError(
                f"{locale}: missing={missing!r}, extra={extra!r}"
            )

    unstable = sorted(key for key in reference if not STABLE_KEY.match(key))
    if unstable:
        raise ValueError(
            "localization keys must be stable identifiers "
            f"(a-z, digits, dot, underscore), got {unstable[:12]!r}"
        )

    for key in sorted(reference):
        expected = PLACEHOLDER.findall(strings[LOCALES[0]][key])
        for locale in LOCALES[1:]:
            actual = PLACEHOLDER.findall(strings[locale][key])
            if actual != expected:
                raise ValueError(
                    f"{locale}:{key!r}: placeholders {actual!r}, "
                    f"expected {expected!r}"
                )

    missing_accessibility = REQUIRED_ACCESSIBILITY_KEYS - reference
    if missing_accessibility:
        raise ValueError(
            "missing required accessibility keys: "
            f"{sorted(missing_accessibility)!r}"
        )

    watch_strings = {
        locale: read_strings(locale, WATCH_RESOURCES)
        for locale in LOCALES
    }
    watch_reference = set(watch_strings[LOCALES[0]])
    for locale in LOCALES[1:]:
        keys = set(watch_strings[locale])
        if keys != watch_reference:
            raise ValueError(
                f"watch {locale}: keys differ from {LOCALES[0]}"
            )
    watch_unstable = sorted(
        key for key in watch_reference if not STABLE_KEY.match(key)
    )
    if watch_unstable:
        raise ValueError(
            "Watch localization keys must be stable identifiers, "
            f"got {watch_unstable!r}"
        )

    plural_reference = set(dictionaries[LOCALES[0]])
    for locale in LOCALES[1:]:
        keys = set(dictionaries[locale])
        if keys != plural_reference:
            raise ValueError(
                f"{locale}: plural keys differ from {LOCALES[0]}"
            )

    known = reference | plural_reference
    missing_calls: list[str] = []
    hardcoded: list[str] = []
    for path in collect_swift_files():
        relative = str(path.relative_to(ROOT))
        text = path.read_text(encoding="utf-8")
        for match in L10N_KEY.finditer(text):
            key = match.group(1)
            if key not in known:
                line = text[: match.start()].count("\n") + 1
                missing_calls.append(f"{relative}:{line}: {key}")
        if "/Features/" in relative or relative.endswith("ConnectView.swift"):
            for match in UI_HARDCODE.finditer(text):
                line = text[: match.start()].count("\n") + 1
                hardcoded.append(f"{relative}:{line}: {match.group(1)}")

    if missing_calls:
        raise ValueError(
            "L10n keys missing from Localizable.strings: "
            + "; ".join(missing_calls[:20])
        )
    if hardcoded:
        raise ValueError(
            "hardcoded Cyrillic UI strings must go through L10n: "
            + "; ".join(hardcoded[:20])
        )

    print(
        "Localization validation passed: "
        f"{len(reference)} strings, "
        f"{len(plural_reference)} plural keys, "
        f"{len(LOCALES)} locales; "
        f"{len(watch_reference)} Watch strings."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"Localization validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
