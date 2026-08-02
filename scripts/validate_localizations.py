#!/usr/bin/env python3
"""Validate that all shipped Localizable resources stay in sync."""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "PrivateMusic" / "Resources"
WATCH_RESOURCES = ROOT / "PrivateMusicWatch" / "Resources"
LOCALES = ("ru", "en")
ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[@d]")
REQUIRED_ACCESSIBILITY_KEYS = {
    "Очистить недавние запросы",
    "Удалить запрос «%@»",
    "Загрузка результатов поиска",
    "Открыть полноэкранный плеер",
    "Предыдущий трек",
    "Следующий трек",
    "Приостановить",
    "Продолжить воспроизведение",
    "Сейчас играет",
    "Воспроизвести трек",
    "Воспроизвести из очереди",
    "Перейти к этой строке",
    "Скопировать строку",
    "Строка скопирована",
    "Закрыть плеер",
    "Выбрать устройство воспроизведения",
    "Меню действий открыто",
    "Меню действий закрыто",
    "Перемешивание включено",
    "Перемешивание выключено",
    "Повтор выключен",
    "Повтор всей очереди",
    "Повтор одного трека",
    "Обложка: %@ — %@",
    "Трек добавлен в медиатеку",
    "Трек не добавлен в медиатеку",
    "Не удалось изменить медиатеку",
    "Поисковый запрос",
    "Введите не менее двух символов",
    "Очистить поиск",
    "Введите ещё один символ",
    "Для поиска нужно минимум два символа.",
    "Найдите музыку",
    "Введите название трека или исполнителя. Результаты появятся автоматически.",
    "Повторить поиск «%@»",
    "Ищем в VK…",
    "Выполняется поиск",
    "Загружаем ещё…",
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

    for key in sorted(reference):
        expected = PLACEHOLDER.findall(key)
        for locale in LOCALES:
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

    plural_reference = set(dictionaries[LOCALES[0]])
    for locale in LOCALES[1:]:
        keys = set(dictionaries[locale])
        if keys != plural_reference:
            raise ValueError(
                f"{locale}: plural keys differ from {LOCALES[0]}"
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
