#!/usr/bin/env bash
# Package an unsigned .app into a sideload-compatible .ipa
#
# Uses Info-ZIP with Apple's unsigned IPA recipe:
#   zip -0 -y -r App.ipa Payload
# This keeps explicit Payload/ directory entries and Unix file-type bits
# that Python zipfile omits and that many on-device signers require.
#
# Usage:
#   package_unsigned_ipa.sh [--strip-watch] <path-to-app> <output-ipa>
set -euo pipefail

strip_watch=0
if [[ "${1:-}" == "--strip-watch" ]]; then
  strip_watch=1
  shift
fi

if [[ $# -ne 2 ]]; then
  echo "usage: $0 [--strip-watch] <path-to-app> <output-ipa>" >&2
  exit 2
fi

app_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir -p "$(dirname "$2")"
output_path="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"

if [[ ! -d "$app_path" || "$app_path" != *.app ]]; then
  echo "invalid .app path: $app_path" >&2
  exit 3
fi

if ! command -v zip >/dev/null 2>&1; then
  echo "zip (Info-ZIP) is required to package IPA" >&2
  exit 4
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

if [[ "$strip_watch" -eq 1 ]]; then
  rm -rf "$work_dir/Payload/"*.app/PlugIns
  rm -rf "$work_dir/Payload/"*.app/Watch
fi

find "$work_dir/Payload" -name '.DS_Store' -delete 2>/dev/null || true
find "$work_dir/Payload" -name '._*' -delete 2>/dev/null || true

rm -f "$output_path"
(
  cd "$work_dir"
  # Apple unsigned IPA recipe (see .ipa on Wikipedia):
  # store compression, preserve symlinks, recurse Payload/.
  # Info-ZIP writes Payload/ directory entries + S_IFREG/S_IFDIR attrs.
  zip -0 -y -q -r "$output_path" Payload
)

unzip -t "$output_path" >/dev/null

python3 - "$output_path" "$strip_watch" <<'PY'
import sys
import zipfile

path = sys.argv[1]
strip_watch = sys.argv[2] == "1"

with zipfile.ZipFile(path) as archive:
    if archive.testzip() is not None:
        raise SystemExit("IPA contains a corrupted ZIP entry")
    names = archive.namelist()
    if not names:
        raise SystemExit("IPA is empty")
    if "Payload/" not in names:
        raise SystemExit(
            "IPA is missing explicit Payload/ directory entry "
            "(required by many sideload unzippers)"
        )
    if not all(name.startswith("Payload/") for name in names):
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
    app_dirs = [
        name
        for name in names
        if name.startswith("Payload/")
        and name.endswith(".app/")
        and name.count(".app/") == 1
        and name.count("/") == 2
    ]
    if len(app_dirs) != 1:
        raise SystemExit(
            "IPA must contain exactly one Payload/*.app/ directory entry, "
            f"found {app_dirs!r}"
        )
    if not any(name.endswith(".app/Info.plist") for name in names):
        raise SystemExit("IPA is missing application Info.plist")
    if any("/Watch/" in name for name in names):
        raise SystemExit(
            "IPA contains legacy Watch/ content; watchOS requires PlugIns/"
        )

    has_watch_plugin = any(
        name.endswith("/PlugIns/PrivateMusicWatch.app/Info.plist")
        for name in names
    )
    if strip_watch:
        if has_watch_plugin or any("/PlugIns/" in name for name in names):
            raise SystemExit("strip-watch IPA still contains PlugIns/")
    else:
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

    # Info-ZIP sets S_IFREG (0o100000) on files; reject broken attrs.
    bad_attrs = []
    for info in archive.infolist():
        if info.filename.endswith("/"):
            continue
        mode = (info.external_attr >> 16) & 0xFFFF
        if mode and (mode & 0o170000) == 0:
            bad_attrs.append(info.filename)
    if bad_attrs:
        raise SystemExit(
            "IPA file entries missing Unix file-type bits: "
            + ", ".join(bad_attrs[:5])
        )
PY

echo "Created $output_path"
