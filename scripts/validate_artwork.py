"""Validate release artwork using only Python's standard library."""
import hashlib
import json
import pathlib
import struct
import sys
import zlib
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent


def validate_png(path, expected_size):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: invalid PNG signature")
    cursor = 8
    dimensions = None
    ended = False
    while cursor < len(data):
        length = struct.unpack(">I", data[cursor:cursor + 4])[0]
        kind = data[cursor + 4:cursor + 8]
        payload = data[cursor + 8:cursor + 8 + length]
        crc = struct.unpack(">I", data[cursor + 8 + length:cursor + 12 + length])[0]
        if zlib.crc32(kind + payload) != crc:
            raise ValueError(f"{path}: corrupt {kind!r} chunk")
        if kind == b"IHDR":
            width, height, depth, color, _, _, _ = struct.unpack(">IIBBBBB", payload)
            dimensions = (width, height)
            if depth != 8 or color != 2:
                raise ValueError(f"{path}: expected opaque 8-bit RGB artwork")
        cursor += length + 12
        if kind == b"IEND":
            ended = True
            break
    if not ended or cursor != len(data) or dimensions != (expected_size, expected_size):
        raise ValueError(f"{path}: incomplete PNG or wrong size {dimensions}")
    return hashlib.sha256(data).hexdigest()


def validate():
    ios = ROOT / "PrivateMusic/Resources/Assets.xcassets"
    watch = ROOT / "PrivateMusicWatch/Resources/Assets.xcassets"
    checked = 0
    for assets in (ios, watch):
        catalog = assets / "AppIcon.appiconset"
        entries = json.loads((catalog / "Contents.json").read_text(encoding="utf-8"))["images"]
        for entry in entries:
            validate_png(catalog / entry["filename"], 1024)
            checked += 1
    master = validate_png(ROOT / "artwork/AppIconBlackMaster.png", 1024)
    for assets in (ios, watch):
        if validate_png(assets / "AppIcon.appiconset/AppIcon.png", 1024) != master:
            raise ValueError("iPhone, Watch and master artwork must match")
    preview = ios / "AppIconPreview.imageset"
    entries = json.loads((preview / "Contents.json").read_text(encoding="utf-8"))["images"]
    for entry in entries:
        validate_png(preview / entry["filename"], 256 * int(entry["scale"][0]))
        checked += 1
    launch = ET.parse(ios / "LaunchMark.imageset/LaunchMark.svg").getroot()
    if launch.attrib.get("viewBox") != "0 0 96 96":
        raise ValueError("Launch mark must retain its square 96pt viewBox")
    print(f"Artwork validation passed: {checked} catalog images; opaque RGB, sizes, CRCs and brand consistency.")


if __name__ == "__main__":
    try:
        validate()
    except (ValueError, OSError, KeyError, struct.error, ET.ParseError) as error:
        sys.exit(str(error))
