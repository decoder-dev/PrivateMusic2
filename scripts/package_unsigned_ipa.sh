#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <path-to-app> <output-ipa>" >&2
  exit 2
fi

app_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
output_path="$2"

if [[ ! -d "$app_path" || "$app_path" != *.app ]]; then
  echo "invalid .app path: $app_path" >&2
  exit 3
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$work_dir/Payload" "$(dirname "$output_path")"
ditto "$app_path" "$work_dir/Payload/$(basename "$app_path")"

(
  cd "$work_dir"
  # Store entries without compression. The IPA is larger, but this avoids
  # extraction failures in older mobile signing tools while remaining a
  # standards-compliant ZIP archive accepted by Apple's tooling.
  /usr/bin/zip -0 -qry "$output_path" Payload
)

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
    unsupported = [
        info.filename
        for info in archive.infolist()
        if info.compress_type != zipfile.ZIP_STORED
    ]
    if unsupported:
        raise SystemExit(
            "IPA compatibility mode contains compressed entries: "
            + ", ".join(unsupported)
        )
PY
echo "Created $output_path"
