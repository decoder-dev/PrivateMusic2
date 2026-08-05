#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <path-to-app> <output-ipa>" >&2
  exit 2
fi

app_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir -p "$(dirname "$2")"
output_path="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"

if [[ ! -d "$app_path" || "$app_path" != *.app ]]; then
  echo "invalid .app path: $app_path" >&2
  exit 3
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$work_dir/Payload"
# Avoid AppleDouble / resource-fork sidecars that break third-party unzippers.
export COPYFILE_DISABLE=1
if command -v ditto >/dev/null 2>&1; then
  ditto "$app_path" "$work_dir/Payload/$(basename "$app_path")"
else
  cp -a "$app_path" "$work_dir/Payload/$(basename "$app_path")"
fi

find "$work_dir/Payload" -name '.DS_Store' -delete 2>/dev/null || true
find "$work_dir/Payload" -name '._*' -delete 2>/dev/null || true

rm -f "$output_path"
python3 - "$work_dir/Payload" "$output_path" <<'PY'
import os
import stat
import sys
import time
import zipfile

payload_root = sys.argv[1]
output_path = sys.argv[2]
payload_parent = os.path.dirname(payload_root)

with zipfile.ZipFile(
    output_path,
    mode="w",
    compression=zipfile.ZIP_DEFLATED,
    compresslevel=6,
    allowZip64=False,
) as archive:
    for dirpath, dirnames, filenames in os.walk(payload_root):
        dirnames.sort()
        filenames.sort()
        # Files only — unzip creates parent dirs. Empty STORED directory
        # entries make some tools report/reject the IPA as store-only.
        for name in filenames:
            path = os.path.join(dirpath, name)
            if not os.path.isfile(path):
                continue
            arcname = os.path.relpath(path, payload_parent).replace(os.sep, "/")
            st = os.stat(path)
            mode = stat.S_IMODE(st.st_mode)
            # Mach-O binaries must remain executable inside the archive.
            base = os.path.basename(path)
            if base in {"PrivateMusic", "PrivateMusicWatch"} or (
                mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            ):
                mode |= 0o755
            zi = zipfile.ZipInfo(arcname, time.localtime(st.st_mtime)[:6])
            zi.create_system = 3
            zi.external_attr = (mode & 0xFFFF) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            with open(path, "rb") as src:
                archive.writestr(zi, src.read(), compress_type=zipfile.ZIP_DEFLATED)
PY

/usr/bin/unzip -t "$output_path"
python3 - "$output_path" <<'PY'
import sys
import zipfile

path = sys.argv[1]
with zipfile.ZipFile(path) as archive:
    if archive.testzip() is not None:
        raise SystemExit("IPA contains a corrupted ZIP entry")
    names = archive.namelist()
    if not names or not all(name.startswith("Payload/") for name in names):
        raise SystemExit("IPA contains files outside Payload")
    junk = [
        name
        for name in names
        if name.startswith("__MACOSX")
        or "/__MACOSX/" in name
        or name.rsplit("/", 1)[-1].startswith("._")
    ]
    if junk:
        raise SystemExit(
            "IPA contains AppleDouble/junk entries: " + ", ".join(junk[:5])
        )
    if not any(name.endswith(".app/Info.plist") for name in names):
        raise SystemExit("IPA is missing application Info.plist")
    if any("/Watch/" in name for name in names):
        raise SystemExit(
            "IPA contains legacy Watch/ content; watchOS requires PlugIns/"
        )
    watch_prefixes = {
        name.removesuffix("Info.plist")
        for name in names
        if name.endswith(
            "/PlugIns/PrivateMusicWatch.app/Info.plist"
        )
    }
    if len(watch_prefixes) != 1:
        raise SystemExit(
            "IPA is missing exactly one embedded PrivateMusicWatch app"
        )
    watch_prefix = next(iter(watch_prefixes))
    if not any(
        name.startswith(watch_prefix)
        and name != watch_prefix + "Info.plist"
        and not name.endswith("/")
        for name in names
    ):
        raise SystemExit("embedded Watch app has no payload files")

    file_entries = [
        info
        for info in archive.infolist()
        if not info.filename.endswith("/") and info.file_size > 0
    ]
    if not file_entries:
        raise SystemExit("IPA Payload is empty")
    non_deflated = [
        info.filename
        for info in file_entries
        if info.compress_type != zipfile.ZIP_DEFLATED
    ]
    if non_deflated:
        raise SystemExit(
            "IPA must DEFLATE all files (sideload tools reject store-only): "
            + ", ".join(non_deflated[:5])
        )
PY
echo "Created $output_path"
