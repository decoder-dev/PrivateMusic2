"""Validate archive application UUIDs and package matching dSYMs for crash reports."""
import argparse
import json
import plistlib
import re
import subprocess
import zipfile
from pathlib import Path


def uuids(path):
    result = subprocess.run(
        ["xcrun", "dwarfdump", "--uuid", str(path)],
        check=True, capture_output=True, text=True,
    )
    values = set(re.findall(r"UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)", result.stdout))
    if not values:
        raise ValueError(f"No Mach-O UUIDs found: {path}")
    return {(uuid.upper(), arch) for uuid, arch in values}


def package(archive, output, commit):
    symbols = archive / "dSYMs"
    dwarf_files = sorted(symbols.glob("*.dSYM/Contents/Resources/DWARF/*"))
    if not dwarf_files:
        raise ValueError("Archive contains no dSYMs")
    symbol_uuids = {path: uuids(path) for path in dwarf_files if path.is_file()}
    products = archive / "Products" / "Applications"
    apps = sorted(products.rglob("*.app")) + sorted(products.rglob("*.appex"))
    if not apps:
        raise ValueError("Archive contains no application bundles")
    manifest = {"commit": commit, "applications": []}
    for app in apps:
        with (app / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        executable = app / info["CFBundleExecutable"]
        expected = uuids(executable)
        matches = [path for path, values in symbol_uuids.items() if expected <= values]
        if not matches:
            raise ValueError(f"Missing matching dSYM for {app.name}: {sorted(expected)}")
        manifest["applications"].append({
            "bundle": str(app.relative_to(products)),
            "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"),
            "uuids": sorted(expected),
            "symbols": [path.relative_to(symbols).as_posix() for path in matches],
        })
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as zipped:
        for path in sorted(symbols.rglob("*")):
            if path.is_file():
                zipped.write(path, "dSYMs/" + path.relative_to(symbols).as_posix())
        zipped.writestr("build-manifest.json", json.dumps(manifest, indent=2) + "\n")
    print(f"Validated {len(apps)} bundles; packaged symbols: {output.name}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    package(args.archive, args.output, args.commit)
