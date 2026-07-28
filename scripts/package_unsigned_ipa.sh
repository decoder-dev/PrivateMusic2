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
  /usr/bin/zip -qry "$output_path" Payload
)

/usr/bin/unzip -t "$output_path"
echo "Created $output_path"

