#!/usr/bin/env python3
"""Patch XcodeGen's legacy Watch/ copy phase for Xcode 16+."""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "PrivateMusic.xcodeproj" / "project.pbxproj"

source = PROJECT.read_text(encoding="utf-8")
pattern = re.compile(
    r"(?P<block>\n\s*[A-F0-9]+ /\* Embed Watch Content \*/ = \{.*?\n\s*\};)",
    re.DOTALL,
)
match = pattern.search(source)
if match is None:
    raise SystemExit("ERROR: missing Embed Watch Content build phase")

block = match.group("block")
patched = block.replace(
    'dstPath = "$(CONTENTS_FOLDER_PATH)/Watch";',
    'dstPath = "";',
)
patched = patched.replace("dstSubfolderSpec = 16;", "dstSubfolderSpec = 13;")

if 'dstPath = "";' not in patched or "dstSubfolderSpec = 13;" not in patched:
    raise SystemExit("ERROR: could not patch Watch app destination to PlugIns")

PROJECT.write_text(
    source[: match.start("block")]
    + patched
    + source[match.end("block") :],
    encoding="utf-8",
)
print("OK: Watch app embeds in PlugIns for Xcode 16+")
