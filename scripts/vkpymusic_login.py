#!/usr/bin/env python3
"""Local VKpyMusic session helper for a user-owned VK account."""

from __future__ import annotations

import getpass
import logging
import sys


def main() -> int:
    try:
        from vkpymusic import TokenReceiver
    except ImportError:
        print(
            "VKpyMusic is not installed.\n"
            "Run: py -m pip install vkpymusic==4.0.2",
            file=sys.stderr,
        )
        return 2

    print(
        "Private Music — локальное получение сессии VKpyMusic\n"
        "Данные отправляются библиотекой напрямую в VK. "
        "Скрипт не сохраняет пароль."
    )
    login = input("Номер телефона или логин VK: ").strip()
    password = getpass.getpass("Пароль VK: ")
    if not login or not password:
        print("Логин и пароль не могут быть пустыми.", file=sys.stderr)
        return 2

    logger = logging.getLogger("privatemusic.vkpymusic")
    logger.handlers = [logging.NullHandler()]
    logger.propagate = False
    receiver = TokenReceiver(
        login=login,
        password=password,
        logger=logger,
    )
    try:
        authorized = receiver.auth()
    finally:
        password = ""

    if not authorized:
        print("VK не выдал музыкальную сессию.", file=sys.stderr)
        return 1

    token = receiver.get_token()
    if not token:
        print("VKpyMusic не вернул token_for_audio.", file=sys.stderr)
        return 1

    print("\nСкопируйте значения в экран подключения Private Music:")
    print(f"token_for_audio={token}")
    print(f"user_agent={receiver.client.user_agent}")
    print(
        "\nНе отправляйте token_for_audio другим людям: "
        "он предоставляет доступ к вашему аккаунту."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
