import json
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from package_debug_symbols import package


class SymbolPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "App.xcarchive"
        for relative, name in [("Phone.app", "Phone"), ("Phone.app/Watch/Watch.app", "Watch")]:
            app = self.archive / "Products/Applications" / relative
            app.mkdir(parents=True)
            (app / name).write_bytes(b"binary")
            with (app / "Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleExecutable": name, "CFBundleVersion": "162"}, stream)
            dwarf = self.archive / f"dSYMs/{name}.app.dSYM/Contents/Resources/DWARF/{name}"
            dwarf.parent.mkdir(parents=True)
            dwarf.write_bytes(b"symbols")
        self.output = self.root / "symbols.zip"

    def test_packages_phone_and_watch_with_identity_manifest(self):
        with patch("package_debug_symbols.uuids", side_effect=lambda path: {(path.name, "arm64")}):
            package(self.archive, self.output, "commit123")
        with zipfile.ZipFile(self.output) as archive:
            manifest = json.loads(archive.read("build-manifest.json"))
            self.assertEqual(manifest["commit"], "commit123")
            self.assertEqual(len(manifest["applications"]), 2)
            self.assertEqual(len([name for name in archive.namelist() if "/DWARF/" in name]), 2)

    def test_rejects_symbols_from_a_different_build(self):
        def identifiers(path):
            return {("wrong" if "dSYMs" in path.parts else path.name, "arm64")}
        with patch("package_debug_symbols.uuids", side_effect=identifiers):
            with self.assertRaisesRegex(ValueError, "Missing matching dSYM"):
                package(self.archive, self.output, "commit123")
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
